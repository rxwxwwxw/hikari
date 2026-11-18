module platform.darwin_native;

// Minimal public CoreFoundation/IOKit bindings. Ownership follows Copy/Create/Get
// rules; only allowlisted properties are decoded, never serials, MACs or UUIDs.
version (OSX):

import core.model;
import platform.darwin : DarwinPowerSource, decodeDarwinPowerSource;
import core.serializer : sanitizeOsString;
import std.conv : to;
import std.string : fromStringz, toStringz, toLower, strip;
import std.algorithm : canFind;
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
    CF CFStringCreateWithCString(CF allocator, const(char)* text, uint encoding);
    bool CFStringGetCString(CF value, char* buffer, long size, uint encoding);
    bool CFNumberGetValue(CF value, int kind, void* result);
    bool CFBooleanGetValue(CF value);
    long CFDataGetLength(CF value);
    const(ubyte)* CFDataGetBytePtr(CF value);
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
    bool IOObjectConformsTo(uint object, const(char)* className);
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
    return r;
}

void enrichNativeHardware(ref HardwareInventory hw) {
    eachService("IOPlatformExpertDevice", (uint object) {
        auto firmware = propertyText(object, "version");
        // This is a firmware version only when the registry actually exposes it.
        if (firmware.length) {
            hw.firmware.vendor = "Apple Inc.";
            hw.firmware.version_str = firmware;
        }
    });
    bool storageOk = eachService("IOMedia", (uint object) {
        auto whole = property(object, "Whole");
        if (whole is null) return;
        scope (exit) CFRelease(whole);
        auto isWhole = boolean(whole);
        if (isWhole.isNull || !isWhole.get) return;
        auto capacity = propertyNumber(object, "Size");
        if (capacity.isNull || capacity.get <= 0) return;
        // Walk only a bounded ancestry; APFS virtual media must not be physical disks.
        uint current = object;
        uint owned;
        scope (exit) if (owned) IOObjectRelease(owned);
        foreach (_; 0 .. 16) {
            // A whole APFS container is still logical media over a physical disk.
            if (current != object && IOObjectConformsTo(current, "IOMedia")) return;
            if (IOObjectConformsTo(current, "IOBlockStorageDevice")) {
                StorageDeviceHardware disk;
                disk.id = "disk:" ~ to!string(hw.storage_devices.length);
                disk.display_name = dictionaryPropertyText(current, "Device Characteristics", "Product Name");
                disk.bus = dictionaryPropertyText(current, "Protocol Characteristics", "Physical Interconnect").toLower();
                auto medium = dictionaryPropertyText(current, "Device Characteristics", "Medium Type");
                if (medium == "Solid State") disk.media_type = "ssd";
                else if (medium == "Rotational") disk.media_type = "hdd";
                disk.capacity_bytes = cast(ulong) capacity.get;
                hw.storage_devices ~= disk;
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

    bool graphicsOk = eachService("IOAccelerator", (uint object) {
        auto model = propertyText(object, "model");
        if (model.length == 0) {
            uint parent;
            if (IORegistryEntryGetParentEntry(object, "IOService", &parent) == 0) {
                scope (exit) IOObjectRelease(parent);
                model = propertyText(parent, "model");
            }
        }
        if (model.length == 0) return;
        foreach (g; hw.graphics_adapters) if (g.display_name == model) return;
        GraphicsAdapterHardware gpu;
        gpu.id = "gpu:" ~ to!string(hw.graphics_adapters.length);
        gpu.display_name = model;
        // Unified system memory is not dedicated VRAM.
        auto bytes = propertyNumber(object, "VRAM,totalMB");
        if (!bytes.isNull && bytes.get > 0 && bytes.get <= ulong.max / 1048576)
            gpu.memory_total_bytes = cast(ulong) bytes.get * 1048576;
        hw.graphics_adapters ~= gpu;
    });
    hw.capabilities["graphics_adapters"] = graphicsOk && hw.graphics_adapters.length
        ? CapabilityState.ok : CapabilityState.unavailable;

    eachService("IONetworkInterface", (uint object) {
        auto name = propertyText(object, "BSD Name");
        foreach (ref adapter; hw.network_adapters) {
            if (adapter.interface_name != name) continue;
            uint parent;
            if (IORegistryEntryGetParentEntry(object, "IOService", &parent) != 0) continue;
            scope (exit) IOObjectRelease(parent);
            auto model = propertyText(parent, "model");
            if (model.length) adapter.display_name = model;
            if (IOObjectConformsTo(object, "IO80211Interface")) adapter.kind = "wifi";
            else if (IOObjectConformsTo(object, "IOEthernetInterface")) adapter.kind = "ethernet";
        }
    });
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
                if (adapter.interface_name != name) continue;
                if (adapter.display_name == name && label.length) adapter.display_name = label;
                if (kind == "IEEE80211") adapter.kind = "wifi";
                else if (kind == "Ethernet") adapter.kind = "ethernet";
            }
        }
    }
    if (hw.system.form_factor.length == 0 && nativePowerSources().batteries.length)
        hw.system.form_factor = "laptop";
}
