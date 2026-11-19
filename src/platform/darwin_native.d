module platform.darwin_native;

// Minimal public CoreFoundation/IOKit bindings. Ownership follows Copy/Create/Get
// rules; only allowlisted properties are decoded, never serials, MACs or UUIDs.
version (OSX):

import core.model;
import platform.darwin : DarwinPowerSource, decodeDarwinPowerSource;
import core.serializer : sanitizeOsString;
import std.algorithm : canFind, startsWith;
import std.conv : to;
import std.datetime.systime : Clock;
import std.file : exists, getSize, read, timeLastModified;
import std.format : format;
import std.math : abs;
import std.string : fromStringz, toStringz, toLower, strip;
import std.typecons : Nullable;

private alias CF = const(void)*;
private extern (C) nothrow @nogc {
    void CFRelease(CF value);
    ulong CFGetTypeID(CF value);
    ulong CFStringGetTypeID();
    ulong CFNumberGetTypeID();
    ulong CFBooleanGetTypeID();
    ulong CFDataGetTypeID();
    ulong CFDictionaryGetTypeID();
    ulong CFArrayGetTypeID();
    CF CFStringCreateWithCString(CF allocator, const(char)* text, uint encoding);
    bool CFStringGetCString(CF value, char* buffer, long size, uint encoding);
    bool CFNumberGetValue(CF value, int kind, void* result);
    bool CFBooleanGetValue(CF value);
    CF CFDataCreate(CF allocator, const(ubyte)* bytes, long length);
    long CFDataGetLength(CF value);
    const(ubyte)* CFDataGetBytePtr(CF value);
    CF CFPropertyListCreateWithData(CF allocator, CF data, ulong options, ulong* format, CF* error);
    CF CFDictionaryGetValue(CF dict, CF key);
    long CFArrayGetCount(CF array);
    CF CFArrayGetValueAtIndex(CF array, long index);
    CF IOPSCopyPowerSourcesInfo();
    CF IOPSCopyPowerSourcesList(CF blob);
    CF IOPSGetPowerSourceDescription(CF blob, CF source);
    CF SCNetworkInterfaceCopyAll();
    CF SCNetworkInterfaceGetBSDName(CF networkInterface);
    CF SCNetworkInterfaceGetInterfaceType(CF networkInterface);
    CF SCNetworkInterfaceGetLocalizedDisplayName(CF networkInterface);
    CF IOServiceMatching(const(char)* name);
    int IOServiceGetMatchingServices(uint port, CF matching, uint* iterator);
    uint IOIteratorNext(uint iterator);
    int IOObjectRelease(uint object);
    int IOObjectGetClass(uint object, char* className);
    bool IOObjectConformsTo(uint object, const(char)* className);
    uint IORegistryEntryFromPath(uint masterPort, const(char)* path);
    int IORegistryEntryGetName(uint entry, char* name);
    int IORegistryEntryGetParentEntry(uint object, const(char)* plane, uint* parent);
    CF IORegistryEntryCreateCFProperty(uint entry, CF key, CF allocator, uint options);
}
private enum uint utf8 = 0x08000100;

private CF dictionaryValue(CF dict, string key) {
    if (dict is null || CFGetTypeID(dict) != CFDictionaryGetTypeID()) return null;
    auto k = CFStringCreateWithCString(null, key.toStringz, utf8);
    if (k is null) return null;
    scope (exit) CFRelease(k);
    return CFDictionaryGetValue(dict, k);
}

private string text(CF value) {
    if (value is null) return "";
    if (CFGetTypeID(value) == CFStringGetTypeID()) {
        char[512] buf;
        if (CFStringGetCString(value, buf.ptr, buf.length, utf8))
            return sanitizeOsString(fromStringz(buf.ptr).idup, 160);
    } else if (CFGetTypeID(value) == CFDataGetTypeID()) {
        auto n = CFDataGetLength(value);
        if (n > 0 && n <= 512) {
            auto bytes = CFDataGetBytePtr(value)[0 .. n];
            size_t end = 0;
            while (end < bytes.length && bytes[end] != 0) end++;
            return sanitizeOsString(cast(string) bytes[0 .. end].idup, 160);
        }
    }
    return "";
}

private Nullable!long number(CF value) {
    Nullable!long result;
    long v;
    if (value !is null && CFGetTypeID(value) == CFNumberGetTypeID()
        && CFNumberGetValue(value, 4 /* kCFNumberSInt64Type */, &v)) result = v;
    return result;
}

private Nullable!bool boolean(CF value) {
    Nullable!bool result;
    if (value !is null && CFGetTypeID(value) == CFBooleanGetTypeID())
        result = CFBooleanGetValue(value);
    return result;
}

private CF property(uint object, string key) {
    auto k = CFStringCreateWithCString(null, key.toStringz, utf8);
    if (k is null) return null;
    scope (exit) CFRelease(k);
    return IORegistryEntryCreateCFProperty(object, k, null, 0);
}
private string propertyText(uint object, string key) {
    auto v = property(object, key);
    if (v is null) return "";
    scope (exit) CFRelease(v);
    return text(v);
}
private Nullable!long propertyNumber(uint object, string key) {
    auto v = property(object, key);
    if (v is null) return Nullable!long.init;
    scope (exit) CFRelease(v);
    return number(v);
}
private string propertyPciHexId(uint object, string key) {
    auto v = property(object, key);
    if (v is null) return "";
    scope (exit) CFRelease(v);
    return pciHexId(v);
}
private string pciHexId(CF value) {
    if (value is null) return "";
    auto tid = CFGetTypeID(value);
    if (tid == CFDataGetTypeID()) {
        auto n = CFDataGetLength(value);
        if (n >= 2 && n <= 4) {
            auto bytes = CFDataGetBytePtr(value)[0 .. n];
            uint v = 0;
            foreach (i; 0 .. n) v |= cast(uint) bytes[i] << (8 * i);
            if (v > 0 && v <= 0xFFFF) return format!"%04x"(v);
        }
    } else if (tid == CFStringGetTypeID()) {
        auto s = text(value).strip().toLower();
        if (s.startsWith("0x")) s = s[2 .. $];
        if (s.length >= 1 && s.length <= 4) {
            uint v = 0;
            bool ok = true;
            foreach (ch; s) {
                v <<= 4;
                if (ch >= '0' && ch <= '9') v |= cast(uint)(ch - '0');
                else if (ch >= 'a' && ch <= 'f') v |= cast(uint)(ch - 'a' + 10);
                else { ok = false; break; }
            }
            if (ok && v > 0) return format!"%04x"(v);
        }
    }
    return "";
}
private string ioClassName(uint object) {
    char[128] buf = 0;
    if (IOObjectGetClass(object, buf.ptr) != 0) return "";
    return sanitizeOsString(fromStringz(buf.ptr).idup, 128);
}
private CF loadPlistFile(string path) {
    if (!exists(path)) return null;
    try {
        if (getSize(path) > 256 * 1024) return null;
        auto raw = cast(const(ubyte)[]) read(path);
        if (raw.length == 0) return null;
        auto data = CFDataCreate(null, raw.ptr, cast(long) raw.length);
        if (data is null) return null;
        scope (exit) CFRelease(data);
        return CFPropertyListCreateWithData(null, data, 0, null, null);
    } catch (Exception) {
        return null;
    }
}
private string gpuVendorName(string vendorId, string model) {
    if (vendorId == "106b" || model.toLower().canFind("apple")) return "Apple Inc.";
    if (vendorId == "1002") return "AMD";
    if (vendorId == "8086") return "Intel";
    if (vendorId == "10de") return "NVIDIA";
    return "";
}
private string dictionaryPropertyText(uint object, string key, string field) {
    auto v = property(object, key);
    if (v is null) return "";
    scope (exit) CFRelease(v);
    return text(dictionaryValue(v, field));
}

// Iterators and every returned object are released even when decoding fails.
private bool eachService(string className, scope void delegate(uint) visit) {
    auto matching = IOServiceMatching(className.toStringz);
    if (matching is null) return false;
    uint iterator;
    if (IOServiceGetMatchingServices(0, matching, &iterator) != 0) return false;
    scope (exit) IOObjectRelease(iterator);
    uint object;
    uint count;
    while (count++ < 4096 && (object = IOIteratorNext(iterator)) != 0) {
        scope (exit) IOObjectRelease(object);
        visit(object);
    }
    return true;
}

RawBatteryResult nativePowerSources() {
    RawBatteryResult r;
    auto blob = IOPSCopyPowerSourcesInfo();
    if (blob is null) {
        r.state = CapabilityState.unavailable;
        r.error = "power_sources_unavailable";
        return r;
    }
    scope (exit) CFRelease(blob);
    auto list = IOPSCopyPowerSourcesList(blob);
    if (list is null) {
        r.state = CapabilityState.error;
        r.error = "power_sources_list_failed";
        return r;
    }
    scope (exit) CFRelease(list);
    auto count = CFArrayGetCount(list);
    foreach (long i; 0 .. count > 64 ? 64 : count) {
        auto d = IOPSGetPowerSourceDescription(blob, CFArrayGetValueAtIndex(list, i));
        if (d is null) continue;
        auto present = boolean(dictionaryValue(d, "Is Present"));
        if (!present.isNull && !present.get) continue;
        // UPS and external accessories are not internal laptop batteries.
        if (text(dictionaryValue(d, "Type")) != "InternalBattery") continue;
        DarwinPowerSource facts;
        facts.currentCapacity = number(dictionaryValue(d, "Current Capacity"));
        facts.maxCapacity = number(dictionaryValue(d, "Max Capacity"));
        facts.charging = boolean(dictionaryValue(d, "Is Charging"));
        facts.charged = boolean(dictionaryValue(d, "Is Charged"));
        facts.state = text(dictionaryValue(d, "Power Source State"));
        facts.minutesToEmpty = number(dictionaryValue(d, "Time to Empty"));
        auto b = decodeDarwinPowerSource(facts, "battery:" ~ to!string(i));
        r.batteries ~= b;
    }
    if (r.batteries.length > 0) {
        size_t batIdx = 0;
        eachService("AppleSmartBattery", (uint obj) {
            if (batIdx >= r.batteries.length) return;
            scope (exit) batIdx++;
            auto cyc = propertyNumber(obj, "CycleCount");
            if (!cyc.isNull && cyc.get > 0) {
                r.batteries[batIdx].cycle_count = cast(ulong) cyc.get;
            }
            auto designCap = propertyNumber(obj, "DesignCapacity");
            auto fullCap = propertyNumber(obj, "NominalChargeCapacity");
            if (fullCap.isNull || fullCap.get <= 0) {
                fullCap = propertyNumber(obj, "AppleRawMaxCapacity");
            }
            auto voltage = propertyNumber(obj, "Voltage");
            if (!designCap.isNull && designCap.get > 0 && !fullCap.isNull && fullCap.get > 0) {
                r.batteries[batIdx].health_pct = 100.0 * cast(double) fullCap.get / cast(double) designCap.get;
                if (!voltage.isNull && voltage.get > 0 && voltage.get < 100_000) {
                    r.batteries[batIdx].design_capacity_wh = (cast(double) designCap.get * cast(double) voltage.get) / 1_000_000.0;
                    r.batteries[batIdx].full_charge_capacity_wh = (cast(double) fullCap.get * cast(double) voltage.get) / 1_000_000.0;
                }
            }
            auto amp = propertyNumber(obj, "InstantAmperage");
            if (!amp.isNull && amp.get != long.min && abs(amp.get) < 1_000_000
                && !voltage.isNull && voltage.get > 0 && voltage.get < 100_000) {
                r.batteries[batIdx].power_watts = (cast(double) abs(amp.get) * cast(double) voltage.get) / 1_000_000.0;
            }
        });
    }
    return r;
}

RawGpuResult nativeSampleGpus() {
    RawGpuResult r;
    string[] seen;
    bool ok = eachService("IOAccelerator", (uint object) {
        auto model = propertyText(object, "model");
        auto vendorId = propertyPciHexId(object, "vendor-id");
        if (model.length == 0 || vendorId.length == 0) {
            uint parent;
            if (IORegistryEntryGetParentEntry(object, "IOService", &parent) == 0) {
                scope (exit) IOObjectRelease(parent);
                if (model.length == 0) model = propertyText(parent, "model");
                if (vendorId.length == 0) vendorId = propertyPciHexId(parent, "vendor-id");
            }
        }
        if (model.length == 0) return;
        auto cores = propertyNumber(object, "gpu-core-count");
        auto displayName = (!cores.isNull && cores.get > 0)
            ? (model ~ " (" ~ to!string(cores.get) ~ "-core GPU)") : model;
        if (seen.canFind(displayName)) return;

        auto perf = property(object, "PerformanceStatistics");
        if (perf is null || CFGetTypeID(perf) != CFDictionaryGetTypeID()) {
            if (perf !is null) CFRelease(perf);
            return;
        }
        scope (exit) CFRelease(perf);

        GpuDynamicStatus g;
        g.id = "gpu:" ~ to!string(r.gpus.length);
        g.display_name = displayName;
        g.vendor = gpuVendorName(vendorId, model);
        g.capability = CapabilityState.ok;

        auto devUtil = number(dictionaryValue(perf, "Device Utilization %"));
        if (devUtil.isNull) devUtil = number(dictionaryValue(perf, "GPU Activity(%)"));
        if (!devUtil.isNull && devUtil.get >= 0 && devUtil.get <= 100) {
            g.utilization_pct = cast(double) devUtil.get;
        }

        auto inUseMem = number(dictionaryValue(perf, "In use system memory"));
        if (inUseMem.isNull) inUseMem = number(dictionaryValue(perf, "vramUsedBytes"));
        if (!inUseMem.isNull && inUseMem.get >= 0) {
            g.vram_used_bytes = cast(ulong) inUseMem.get;
        }

        auto vramMB = propertyNumber(object, "VRAM,totalMB");
        if (!vramMB.isNull && vramMB.get > 0 && vramMB.get <= ulong.max / 1048576) {
            g.vram_total_bytes = cast(ulong) vramMB.get * 1048576;
        }

        if (g.utilization_pct.isNull && g.vram_used_bytes.isNull) return;
        seen ~= displayName;
        r.gpus ~= g;
    });
    r.state = ok && r.gpus.length > 0 ? CapabilityState.ok : CapabilityState.unsupported;
    return r;
}

void nativeSampleMaintenance(ref DriftStatus drift, string runningBuild) {
    auto sysPlist = loadPlistFile("/System/Library/CoreServices/SystemVersion.plist");
    if (sysPlist !is null) {
        scope (exit) CFRelease(sysPlist);
        auto instVer = text(dictionaryValue(sysPlist, "ProductUserVisibleVersion"));
        if (instVer.length == 0) instVer = text(dictionaryValue(sysPlist, "ProductVersion"));
        auto instBuild = text(dictionaryValue(sysPlist, "ProductBuildVersion"));
        if (instVer.length > 0) {
            drift.installed_kernel = instBuild.length > 0
                ? ("macOS " ~ instVer ~ " (" ~ instBuild ~ ")")
                : ("macOS " ~ instVer);
            if (runningBuild.length > 0 && instBuild.length > 0) {
                drift.reboot_required = (instBuild != runningBuild);
            }
        }
    }

    auto suPlist = loadPlistFile("/Library/Preferences/com.apple.SoftwareUpdate.plist");
    if (suPlist !is null) {
        scope (exit) CFRelease(suPlist);
        auto rec = dictionaryValue(suPlist, "RecommendedUpdates");
        if (rec !is null && CFGetTypeID(rec) == CFArrayGetTypeID()) {
            drift.pending_updates = cast(uint) CFArrayGetCount(rec);
        }
        auto postLogout = boolean(dictionaryValue(suPlist, "PostSuccessfulMinorUpdatePostLogOutNotification"));
        if (!postLogout.isNull && postLogout.get) {
            drift.reboot_required = true;
        }
    }

    static immutable string[] suPaths = [
        "/Library/Preferences/com.apple.SoftwareUpdate.plist",
        "/Library/Updates/ProductMetadata.plist",
    ];
    long nowWall = Clock.currTime.toUnixTime();
    foreach (p; suPaths) {
        if (!exists(p)) continue;
        try {
            long mtime = timeLastModified(p).toUnixTime();
            if (nowWall >= mtime) {
                drift.package_cache_age_s = nowWall - mtime;
                break;
            }
        } catch (Exception) {}
    }
}

string[string] nativeNetworkInterfaceKinds() {
    string[string] kinds;
    auto interfaces = SCNetworkInterfaceCopyAll();
    if (interfaces is null) return kinds;
    scope (exit) CFRelease(interfaces);
    auto count = CFArrayGetCount(interfaces);
    foreach (long i; 0 .. count > 4096 ? 4096 : count) {
        auto interfaceRef = CFArrayGetValueAtIndex(interfaces, i);
        auto name = text(SCNetworkInterfaceGetBSDName(interfaceRef));
        if (name.length == 0) continue;
        auto kind = text(SCNetworkInterfaceGetInterfaceType(interfaceRef));
        if (kind == "IEEE80211") kinds[name] = "wireless";
        else if (kind == "Ethernet") kinds[name] = "physical";
    }
    return kinds;
}

void enrichNativeHardware(ref HardwareInventory hw, const MountStatus[] mounts = null) {
    eachService("IOPlatformExpertDevice", (uint object) {
        auto firmware = propertyText(object, "version");
        // This is a firmware version only when the registry actually exposes it.
        if (firmware.length) {
            hw.firmware.type = "EFI";
            hw.firmware.vendor = "Apple Inc.";
            hw.firmware.version_str = firmware;
        }
        auto ts = propertyText(object, "time-stamp");
        if (ts.length) hw.firmware.release_date = ts;

        auto targetSub = propertyText(object, "target-sub-type");
        if (targetSub.length == 0) targetSub = propertyText(object, "target-type");
        auto platName = propertyText(object, "platform-name");
        if (targetSub.length && platName.length) {
            hw.board.revision = targetSub ~ " · " ~ platName;
        } else if (targetSub.length) {
            hw.board.revision = targetSub;
        } else if (platName.length) {
            hw.board.revision = platName;
        }
        if (platName.length) {
            if (hw.cpu.microarchitecture.length) {
                hw.cpu.microarchitecture ~= " · " ~ platName;
            } else {
                hw.cpu.microarchitecture = "Apple Silicon (" ~ platName ~ ")";
            }
        }
    });

    auto prodEntry = IORegistryEntryFromPath(0, "IODeviceTree:/product".ptr);
    if (prodEntry != 0) {
        scope (exit) IOObjectRelease(prodEntry);
        auto prodName = propertyText(prodEntry, "product-name");
        if (prodName.length == 0) prodName = propertyText(prodEntry, "product-description");
        if (prodName.length) hw.system.product_family = prodName;
    }

    auto chosenEntry = IORegistryEntryFromPath(0, "IODeviceTree:/chosen".ptr);
    if (chosenEntry != 0) {
        scope (exit) IOObjectRelease(chosenEntry);
        auto fwVer = propertyText(chosenEntry, "firmware-version");
        if (fwVer.length && hw.firmware.version_str.length == 0) {
            hw.firmware.type = "iBoot";
            hw.firmware.vendor = "Apple Inc.";
            hw.firmware.version_str = fwVer;
        }
        auto dramType = propertyText(chosenEntry, "dram-type");
        auto dramVendor = propertyText(chosenEntry, "dram-vendor");
        if (dramType.length) {
            hw.memory.technology = dramVendor.length ? (dramType ~ " (" ~ dramVendor ~ ")") : dramType;
        }
    }

    size_t[string] diskIdxByBsdName;
    bool storageOk = eachService("IOMedia", (uint object) {
        auto whole = property(object, "Whole");
        if (whole is null) return;
        scope (exit) CFRelease(whole);
        auto isWhole = boolean(whole);
        if (isWhole.isNull || !isWhole.get) return;
        auto capacity = propertyNumber(object, "Size");
        if (capacity.isNull || capacity.get <= 0) return;
        auto bsdName = propertyText(object, "BSD Name");
        // Walk only a bounded ancestry; APFS virtual media must not be physical disks.
        uint current = object;
        uint owned;
        scope (exit) if (owned) IOObjectRelease(owned);
        foreach (_; 0 .. 16) {
            // A whole APFS container is still logical media over a physical disk.
            if (current != object && IOObjectConformsTo(current, "IOMedia")) return;
            if (IOObjectConformsTo(current, "IOBlockStorageDevice")) {
                StorageDeviceHardware disk;
                size_t idx = hw.storage_devices.length;
                disk.id = "disk:" ~ to!string(idx);
                disk.display_name = dictionaryPropertyText(current, "Device Characteristics", "Product Name");
                disk.bus = dictionaryPropertyText(current, "Protocol Characteristics", "Physical Interconnect").toLower();
                auto medium = dictionaryPropertyText(current, "Device Characteristics", "Medium Type");
                if (medium == "Solid State") disk.media_type = "ssd";
                else if (medium == "Rotational") disk.media_type = "hdd";
                disk.capacity_bytes = cast(ulong) capacity.get;
                hw.storage_devices ~= disk;
                if (bsdName.length) diskIdxByBsdName[bsdName] = idx;
                return;
            }
            uint parent;
            if (IORegistryEntryGetParentEntry(current, "IOService", &parent) != 0) return;
            if (owned) IOObjectRelease(owned);
            owned = parent;
            current = parent;
        }
    });
    hw.capabilities["storage_devices"] = storageOk ? CapabilityState.ok : CapabilityState.unavailable;

    string[][string] mountsByDevBsd;
    foreach (const ref m; mounts) {
        if (m.source.startsWith("/dev/") && m.source.length > 5 && m.mount.length > 0) {
            mountsByDevBsd[m.source[5 .. $]] ~= m.mount;
        }
    }
    if (mountsByDevBsd.length > 0 && diskIdxByBsdName.length > 0) {
        eachService("IOMedia", (uint object) {
            auto bsd = propertyText(object, "BSD Name");
            if (bsd.length == 0) return;
            auto pMounts = bsd in mountsByDevBsd;
            if (pMounts is null) return;

            uint current = object;
            uint owned;
            scope (exit) if (owned) IOObjectRelease(owned);
            foreach (_; 0 .. 24) {
                if (IOObjectConformsTo(current, "IOMedia")) {
                    auto curBsd = propertyText(current, "BSD Name");
                    if (auto pIdx = curBsd in diskIdxByBsdName) {
                        foreach (mp; *pMounts) {
                            if (!hw.storage_devices[*pIdx].mounts.canFind(mp)) {
                                hw.storage_devices[*pIdx].mounts ~= mp;
                            }
                        }
                        return;
                    }
                }
                uint parent;
                if (IORegistryEntryGetParentEntry(current, "IOService", &parent) != 0) return;
                if (owned) IOObjectRelease(owned);
                owned = parent;
                current = parent;
            }
        });
    }

    bool graphicsOk = eachService("IOAccelerator", (uint object) {
        auto model = propertyText(object, "model");
        auto vendorId = propertyPciHexId(object, "vendor-id");
        auto deviceId = propertyPciHexId(object, "device-id");
        if (model.length == 0 || vendorId.length == 0 || deviceId.length == 0) {
            uint parent;
            if (IORegistryEntryGetParentEntry(object, "IOService", &parent) == 0) {
                scope (exit) IOObjectRelease(parent);
                if (model.length == 0) model = propertyText(parent, "model");
                if (vendorId.length == 0) vendorId = propertyPciHexId(parent, "vendor-id");
                if (deviceId.length == 0) deviceId = propertyPciHexId(parent, "device-id");
            }
        }
        if (model.length == 0) return;
        auto cores = propertyNumber(object, "gpu-core-count");
        auto displayName = (!cores.isNull && cores.get > 0)
            ? (model ~ " (" ~ to!string(cores.get) ~ "-core GPU)") : model;
        foreach (g; hw.graphics_adapters) if (g.display_name == displayName) return;

        GraphicsAdapterHardware gpu;
        gpu.id = "gpu:" ~ to!string(hw.graphics_adapters.length);
        gpu.display_name = displayName;
        gpu.vendor_id = vendorId;
        gpu.device_id = deviceId;
        gpu.vendor = gpuVendorName(vendorId, model);
        auto bundleId = propertyText(object, "CFBundleIdentifier");
        auto srcVer = propertyText(object, "IOSourceVersion");
        if (bundleId.length && srcVer.length) gpu.driver = bundleId ~ " (" ~ srcVer ~ ")";
        else if (bundleId.length) gpu.driver = bundleId;
        else if (srcVer.length) gpu.driver = srcVer;

        // Unified system memory is not dedicated VRAM.
        auto bytes = propertyNumber(object, "VRAM,totalMB");
        if (!bytes.isNull && bytes.get > 0 && bytes.get <= ulong.max / 1048576)
            gpu.memory_total_bytes = cast(ulong) bytes.get * 1048576;
        hw.graphics_adapters ~= gpu;
    });
    hw.capabilities["graphics_adapters"] = graphicsOk && hw.graphics_adapters.length
        ? CapabilityState.ok : CapabilityState.unavailable;

    auto interfaces = SCNetworkInterfaceCopyAll();
    if (interfaces !is null) {
        scope (exit) CFRelease(interfaces);
        auto count = CFArrayGetCount(interfaces);
        foreach (long i; 0 .. count > 4096 ? 4096 : count) {
            auto interfaceRef = CFArrayGetValueAtIndex(interfaces, i);
            auto name = text(SCNetworkInterfaceGetBSDName(interfaceRef));
            auto kind = text(SCNetworkInterfaceGetInterfaceType(interfaceRef));
            auto label = text(SCNetworkInterfaceGetLocalizedDisplayName(interfaceRef));
            foreach (ref adapter; hw.network_adapters) {
                if (adapter.interface_name != name || adapter.kind == "tailnet") continue;
                if (adapter.display_name == name && label.length) adapter.display_name = label;
                if (kind == "IEEE80211") adapter.kind = "wifi";
                else if (kind == "Ethernet") adapter.kind = "ethernet";
            }
        }
    }

    eachService("IONetworkInterface", (uint object) {
        auto name = propertyText(object, "BSD Name");
        foreach (ref adapter; hw.network_adapters) {
            if (adapter.interface_name != name || adapter.kind == "tailnet") continue;
            if (name.startsWith("anpi") || IOObjectConformsTo(object, "AppleUSBDeviceNCMPrivateEthernetInterface")) {
                adapter.kind = "virtual";
            } else if (IOObjectConformsTo(object, "IO80211Interface")) {
                adapter.kind = "wifi";
            } else if (IOObjectConformsTo(object, "IOEthernetInterface") && adapter.kind != "wifi") {
                adapter.kind = "ethernet";
            }

            string hwModel;
            string driver;
            string bus;
            string vendorId;
            string deviceId;

            uint current = object;
            uint owned;
            scope (exit) if (owned) IOObjectRelease(owned);
            foreach (_; 0 .. 8) {
                uint parent;
                if (IORegistryEntryGetParentEntry(current, "IOService", &parent) != 0) break;
                if (owned) IOObjectRelease(owned);
                owned = parent;
                current = parent;

                if (IOObjectConformsTo(current, "IOPlatformExpertDevice")) break;

                auto cls = ioClassName(current);
                auto bundleId = propertyText(current, "CFBundleIdentifier");
                if (driver.length == 0 && cls != "IOSkywalkLegacyEthernet") {
                    string baseDrv = (cls == "IOUserService" || cls.startsWith("IOUser")) && bundleId.length
                        ? bundleId : cls;
                    if (baseDrv.length) {
                        auto drvVer = propertyText(current, "Driver_Version");
                        driver = drvVer.length ? (baseDrv ~ " (" ~ drvVer ~ ")") : baseDrv;
                    }
                }

                if (bus.length == 0) {
                    if (IOObjectConformsTo(current, "IOPCIDevice")) bus = "pci";
                    else if (cls.canFind("Thunderbolt")) bus = "thunderbolt";
                    else if (IOObjectConformsTo(current, "IOUSBDeviceInterface")
                        || IOObjectConformsTo(current, "IOUSBHostInterface")) bus = "usb";
                    else if (IOObjectConformsTo(current, "AppleARMIODevice")) bus = "apple fabric";
                }

                if (vendorId.length == 0) vendorId = propertyPciHexId(current, "vendor-id");
                if (deviceId.length == 0) deviceId = propertyPciHexId(current, "device-id");

                if (hwModel.length == 0) {
                    auto m = propertyText(current, "model");
                    if (m.length) {
                        hwModel = m;
                    } else {
                        auto iov = propertyText(current, "IOVendor");
                        auto iom = propertyText(current, "IOModel");
                        if (iom.length) {
                            hwModel = iov.length ? (iov ~ " " ~ iom) : iom;
                        } else {
                            auto comp = propertyText(current, "compatible").toLower();
                            if (comp.canFind("bcm4378")) hwModel = "Broadcom BCM4378 Wi-Fi";
                            else if (comp.canFind("bcm4387")) hwModel = "Broadcom BCM4387 Wi-Fi";
                            else if (comp.canFind("bcm4388")) hwModel = "Broadcom BCM4388 Wi-Fi";
                        }
                    }
                }
            }

            if (driver.length) adapter.driver = driver;
            if (bus.length) adapter.bus = bus;
            if (vendorId.length) adapter.vendor_id = vendorId;
            if (deviceId.length) adapter.device_id = deviceId;
            if (hwModel.length) {
                if (adapter.display_name.length && adapter.display_name != adapter.interface_name
                    && !adapter.display_name.canFind(hwModel)) {
                    adapter.display_name = adapter.display_name ~ " (" ~ hwModel ~ ")";
                } else {
                    adapter.display_name = hwModel;
                }
            }
        }
    });

    if (hw.system.form_factor.length == 0 && nativePowerSources().batteries.length)
        hw.system.form_factor = "laptop";
}
