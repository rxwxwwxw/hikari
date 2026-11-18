module core.serializer;

import core.model;
import std.array : appender;
import std.json : JSONOptions, JSONType, JSONValue, parseJSON;
import std.math : isNaN, isInfinity;
import std.string : strip;
import std.typecons : Nullable;

JSONValue jsonNull() pure nothrow @safe {
    return JSONValue(null);
}

string sanitizeOsString(string raw, size_t maxLen = 256) pure @safe {
    if (raw.length == 0) return "";
    auto app = appender!string();
    bool prevSpace = false;
    foreach (char c; raw) {
        ubyte b = cast(ubyte) c;
        if (b == '\r' || b == '\n' || b == '\t') {
            if (!prevSpace && app.data.length > 0) {
                app.put(' ');
                prevSpace = true;
            }
            continue;
        }
        if (b < 0x20 || b == 0x7F) {
            continue;
        }
        app.put(c);
        prevSpace = (c == ' ');
        if (app.data.length >= maxLen) break;
    }
    return app.data.strip();
}

JSONValue jsonStringOrNull(string s, size_t maxLen = 256) pure @safe {
    auto clean = sanitizeOsString(s, maxLen);
    if (clean.length == 0) return jsonNull();
    return JSONValue(clean);
}

JSONValue jsonNullableLong(Nullable!long v) pure nothrow @safe {
    return v.isNull ? jsonNull() : JSONValue(v.get);
}

JSONValue jsonNullableUlong(Nullable!ulong v) pure nothrow @safe {
    return v.isNull ? jsonNull() : JSONValue(v.get);
}

JSONValue jsonNullableUint(Nullable!uint v) pure nothrow @safe {
    return v.isNull ? jsonNull() : JSONValue(v.get);
}

JSONValue jsonNullableBool(Nullable!bool v) pure nothrow @safe {
    return v.isNull ? jsonNull() : JSONValue(v.get);
}

JSONValue jsonNullableDouble(Nullable!double v) pure nothrow @safe {
    if (v.isNull || isNaN(v.get) || isInfinity(v.get)) return jsonNull();
    return JSONValue(v.get);
}

JSONValue serializeHardwareSummary(const ref HardwareSummary hs) pure @safe {
    JSONValue j = JSONValue.emptyObject;
    j["cpu"] = jsonStringOrNull(hs.cpu);
    j["ram_bytes"] = jsonNullableUlong(hs.ram_bytes);
    j["system_model"] = jsonStringOrNull(hs.system_model);
    return j;
}

HardwareSummary parseHardwareSummary(const ref JSONValue j) {
    HardwareSummary hs;
    if (j.type != JSONType.object) return hs;
    if (auto p = "cpu" in j.object) if (p.type == JSONType.string) hs.cpu = sanitizeOsString(p.str);
    if (auto p = "ram_bytes" in j.object) {
        if (p.type == JSONType.integer && p.integer >= 0) hs.ram_bytes = cast(ulong) p.integer;
        else if (p.type == JSONType.uinteger) hs.ram_bytes = p.uinteger;
    }
    if (auto p = "system_model" in j.object) if (p.type == JSONType.string) hs.system_model = sanitizeOsString(p.str);
    return hs;
}

JSONValue serializeGroupMeta(const ref GroupMeta gm) pure @safe {
    JSONValue j = JSONValue.emptyObject;
    j["status"] = cast(string) gm.status;
    j["sampled_at"] = jsonNullableLong(gm.sampled_at);
    j["age_s"] = jsonNullableLong(gm.age_s);
    j["refreshing"] = gm.refreshing;
    if (!gm.last_success_at.isNull) {
        j["last_success_at"] = gm.last_success_at.get;
    }
    if (gm.error.length > 0) {
        j["error"] = sanitizeOsString(gm.error, 160);
    }
    return j;
}

JSONValue serializeStatusResponse(const ref StatusResponse resp) pure @safe {
    JSONValue j = JSONValue.emptyObject;
    j["app"] = resp.app;
    j["schema_version"] = resp.schema_version;
    j["agent_version"] = resp.agent_version;
    j["node_id"] = resp.node_id;
    j["host"] = sanitizeOsString(resp.host, 128);
    j["fqdn"] = jsonStringOrNull(resp.fqdn, 253);
    j["os"] = resp.os;
    j["arch"] = resp.arch;
    j["server_ts"] = resp.server_ts;
    j["boot_id"] = jsonStringOrNull(resp.boot_id, 128);
    j["uptime_s"] = jsonNullableLong(resp.uptime_s);
    if (resp.hardware_summary.isNull) {
        j["hardware_summary"] = jsonNull();
    } else {
        auto hs = resp.hardware_summary.get;
        j["hardware_summary"] = serializeHardwareSummary(hs);
    }

    JSONValue groups = JSONValue.emptyObject;
    foreach (k, gm; resp.groups) {
        groups[k] = serializeGroupMeta(gm);
    }
    j["groups"] = groups;

    JSONValue cpu = JSONValue.emptyObject;
    cpu["pct"] = jsonNullableDouble(resp.cpu.pct);
    cpu["load_1m"] = jsonNullableDouble(resp.cpu.load_1m);
    cpu["temp_c"] = jsonNullableDouble(resp.cpu.temp_c);
    j["cpu"] = cpu;

    JSONValue mem = JSONValue.emptyObject;
    mem["used_bytes"] = jsonNullableUlong(resp.memory.used_bytes);
    mem["total_bytes"] = jsonNullableUlong(resp.memory.total_bytes);
    mem["pct"] = jsonNullableDouble(resp.memory.pct);
    j["memory"] = mem;

    if (resp.swap.isNull) {
        j["swap"] = jsonNull();
    } else {
        JSONValue sw = JSONValue.emptyObject;
        sw["used_bytes"] = jsonNullableUlong(resp.swap.get.used_bytes);
        sw["total_bytes"] = jsonNullableUlong(resp.swap.get.total_bytes);
        sw["pct"] = jsonNullableDouble(resp.swap.get.pct);
        j["swap"] = sw;
    }

    if (!resp.commit.isNull) {
        JSONValue cm = JSONValue.emptyObject;
        cm["used_bytes"] = jsonNullableUlong(resp.commit.get.used_bytes);
        cm["limit_bytes"] = jsonNullableUlong(resp.commit.get.limit_bytes);
        cm["pct"] = jsonNullableDouble(resp.commit.get.pct);
        j["commit"] = cm;
    }

    JSONValue[] nets;
    foreach (n; resp.network) {
        JSONValue nj = JSONValue.emptyObject;
        nj["id"] = sanitizeOsString(n.id, 64);
        nj["name"] = sanitizeOsString(n.name, 64);
        nj["kind"] = n.kind;
        nj["rx_bytes"] = jsonNullableUlong(n.rx_bytes);
        nj["tx_bytes"] = jsonNullableUlong(n.tx_bytes);
        nj["rx_bytes_per_s"] = jsonNullableDouble(n.rx_bytes_per_s);
        nj["tx_bytes_per_s"] = jsonNullableDouble(n.tx_bytes_per_s);
        if (!n.link_up.isNull) nj["link_up"] = n.link_up.get;
        if (!n.link_speed_bps.isNull) nj["link_speed_bps"] = n.link_speed_bps.get;
        nets ~= nj;
    }
    j["network"] = JSONValue(nets);

    JSONValue[] mounts;
    foreach (m; resp.mounts) {
        JSONValue mj = JSONValue.emptyObject;
        mj["mount"] = sanitizeOsString(m.mount, 512);
        mj["source"] = sanitizeOsString(m.source, 256);
        mj["fs"] = sanitizeOsString(m.fs, 64);
        mj["used_bytes"] = jsonNullableUlong(m.used_bytes);
        mj["total_bytes"] = jsonNullableUlong(m.total_bytes);
        mj["pct"] = jsonNullableDouble(m.pct);
        mounts ~= mj;
    }
    j["mounts"] = JSONValue(mounts);

    JSONValue[] gpus;
    foreach (g; resp.gpus) {
        JSONValue gj = JSONValue.emptyObject;
        gj["id"] = sanitizeOsString(g.id, 64);
        gj["display_name"] = sanitizeOsString(g.display_name, 128);
        gj["vendor"] = jsonStringOrNull(g.vendor, 64);
        gj["utilization_pct"] = jsonNullableDouble(g.utilization_pct);
        gj["temp_c"] = jsonNullableDouble(g.temp_c);
        gj["vram_used_bytes"] = jsonNullableUlong(g.vram_used_bytes);
        gj["vram_total_bytes"] = jsonNullableUlong(g.vram_total_bytes);
        gj["power_watts"] = jsonNullableDouble(g.power_watts);
        gj["capability"] = cast(string) g.capability;
        if (g.error.length > 0) gj["error"] = sanitizeOsString(g.error, 128);
        gpus ~= gj;
    }
    j["gpus"] = JSONValue(gpus);

    JSONValue[] bats;
    foreach (b; resp.batteries) {
        JSONValue bj = JSONValue.emptyObject;
        bj["id"] = sanitizeOsString(b.id, 64);
        bj["name"] = sanitizeOsString(b.name, 64);
        bj["status"] = b.status;
        bj["pct"] = jsonNullableDouble(b.pct);
        bj["power_watts"] = jsonNullableDouble(b.power_watts);
        bj["time_remaining_s"] = jsonNullableLong(b.time_remaining_s);
        bj["health_pct"] = jsonNullableDouble(b.health_pct);
        bats ~= bj;
    }
    j["batteries"] = JSONValue(bats);

    JSONValue serializeProcList(const ProcessStatus[] procs) {
        JSONValue[] arr;
        foreach (p; procs) {
            JSONValue pj = JSONValue.emptyObject;
            pj["pid"] = p.pid;
            pj["start_id"] = sanitizeOsString(p.start_id, 64);
            pj["name"] = sanitizeOsString(p.name, 128);
            pj["cpu_pct"] = jsonNullableDouble(p.cpu_pct);
            pj["rss_bytes"] = jsonNullableUlong(p.rss_bytes);
            pj["memory_kind"] = p.memory_kind;
            arr ~= pj;
        }
        return JSONValue(arr);
    }

    j["top_cpu"] = serializeProcList(resp.top_cpu);
    j["top_mem"] = serializeProcList(resp.top_mem);

    JSONValue drift = JSONValue.emptyObject;
    drift["running_kernel"] = jsonStringOrNull(resp.drift.running_kernel, 128);
    drift["installed_kernel"] = jsonStringOrNull(resp.drift.installed_kernel, 128);
    drift["reboot_required"] = jsonNullableBool(resp.drift.reboot_required);
    drift["pending_updates"] = jsonNullableUint(resp.drift.pending_updates);
    drift["package_cache_age_s"] = jsonNullableLong(resp.drift.package_cache_age_s);
    j["drift"] = drift;

    return j;
}

JSONValue serializeHardwareInventory(const ref HardwareInventory hw) pure @safe {
    JSONValue j = JSONValue.emptyObject;
    j["app"] = hw.app;
    j["schema_version"] = hw.schema_version;
    j["node_id"] = hw.node_id;
    j["collected_at"] = jsonNullableLong(hw.collected_at);

    JSONValue col = JSONValue.emptyObject;
    col["status"] = cast(string) hw.collection.status;
    col["partial"] = hw.collection.partial;
    col["age_s"] = jsonNullableLong(hw.collection.age_s);
    col["refreshing"] = hw.collection.refreshing;
    if (hw.collection.error.length > 0) col["error"] = sanitizeOsString(hw.collection.error, 160);
    j["collection"] = col;

    JSONValue sys = JSONValue.emptyObject;
    sys["manufacturer"] = jsonStringOrNull(hw.system.manufacturer, 128);
    sys["model"] = jsonStringOrNull(hw.system.model, 128);
    sys["product_family"] = jsonStringOrNull(hw.system.product_family, 128);
    sys["form_factor"] = jsonStringOrNull(hw.system.form_factor, 64);
    sys["virtualization"] = jsonStringOrNull(hw.system.virtualization, 64);
    j["system"] = sys;

    JSONValue brd = JSONValue.emptyObject;
    brd["manufacturer"] = jsonStringOrNull(hw.board.manufacturer, 128);
    brd["model"] = jsonStringOrNull(hw.board.model, 128);
    brd["revision"] = jsonStringOrNull(hw.board.revision, 64);
    j["board"] = brd;

    JSONValue fw = JSONValue.emptyObject;
    fw["type"] = jsonStringOrNull(hw.firmware.type, 32);
    fw["vendor"] = jsonStringOrNull(hw.firmware.vendor, 128);
    fw["version"] = jsonStringOrNull(hw.firmware.version_str, 128);
    fw["release_date"] = jsonStringOrNull(hw.firmware.release_date, 64);
    j["firmware"] = fw;

    JSONValue cpu = JSONValue.emptyObject;
    cpu["display_name"] = jsonStringOrNull(hw.cpu.display_name, 160);
    cpu["vendor"] = jsonStringOrNull(hw.cpu.vendor, 64);
    cpu["architecture"] = jsonStringOrNull(hw.cpu.architecture, 32);
    cpu["microarchitecture"] = jsonStringOrNull(hw.cpu.microarchitecture, 64);
    cpu["sockets"] = jsonNullableUint(hw.cpu.sockets);
    cpu["physical_cores"] = jsonNullableUint(hw.cpu.physical_cores);
    cpu["logical_cores"] = jsonNullableUint(hw.cpu.logical_cores);
    cpu["performance_cores"] = jsonNullableUint(hw.cpu.performance_cores);
    cpu["efficiency_cores"] = jsonNullableUint(hw.cpu.efficiency_cores);

    JSONValue cache = JSONValue.emptyObject;
    cache["l1d"] = jsonNullableUlong(hw.cpu.cache_bytes.l1d);
    cache["l1i"] = jsonNullableUlong(hw.cpu.cache_bytes.l1i);
    cache["l2"] = jsonNullableUlong(hw.cpu.cache_bytes.l2);
    cache["l3"] = jsonNullableUlong(hw.cpu.cache_bytes.l3);
    cpu["cache_bytes"] = cache;

    JSONValue isa = JSONValue.emptyObject;
    JSONValue[] hwIsa;
    foreach (f; hw.cpu.isa.hardware) hwIsa ~= JSONValue(f);
    JSONValue[] usIsa;
    foreach (f; hw.cpu.isa.usable) usIsa ~= JSONValue(f);
    isa["hardware"] = JSONValue(hwIsa);
    isa["usable"] = JSONValue(usIsa);
    isa["detection"] = hw.cpu.isa.detection;
    cpu["isa"] = isa;
    j["cpu"] = cpu;

    JSONValue mem = JSONValue.emptyObject;
    mem["total_bytes"] = jsonNullableUlong(hw.memory.total_bytes);
    mem["technology"] = jsonStringOrNull(hw.memory.technology, 32);
    mem["speed_mt_s"] = jsonNullableUint(hw.memory.speed_mt_s);
    JSONValue[] mods;
    foreach (m; hw.memory.modules) {
        JSONValue mj = JSONValue.emptyObject;
        mj["slot"] = jsonStringOrNull(m.slot, 64);
        mj["size_bytes"] = jsonNullableUlong(m.size_bytes);
        mj["technology"] = jsonStringOrNull(m.technology, 32);
        mj["speed_mt_s"] = jsonNullableUint(m.speed_mt_s);
        mj["manufacturer"] = jsonStringOrNull(m.manufacturer, 64);
        mj["part_number"] = jsonStringOrNull(m.part_number, 64);
        mods ~= mj;
    }
    mem["modules"] = JSONValue(mods);
    mem["module_enumeration"] = cast(string) hw.memory.module_enumeration;
    j["memory"] = mem;

    JSONValue[] nics;
    foreach (na; hw.network_adapters) {
        JSONValue nj = JSONValue.emptyObject;
        nj["id"] = sanitizeOsString(na.id, 64);
        nj["display_name"] = sanitizeOsString(na.display_name, 160);
        nj["interface"] = sanitizeOsString(na.interface_name, 64);
        nj["kind"] = na.kind;
        nj["bus"] = jsonStringOrNull(na.bus, 32);
        nj["driver"] = jsonStringOrNull(na.driver, 64);
        nj["vendor_id"] = jsonStringOrNull(na.vendor_id, 16);
        nj["device_id"] = jsonStringOrNull(na.device_id, 16);
        nj["link_speed_bps"] = jsonNullableUlong(na.link_speed_bps);
        if (na.mac_address.length > 0) {
            nj["mac_address"] = sanitizeOsString(na.mac_address, 32);
        }
        nics ~= nj;
    }
    j["network_adapters"] = JSONValue(nics);

    JSONValue[] stors;
    foreach (sd; hw.storage_devices) {
        JSONValue sj = JSONValue.emptyObject;
        sj["id"] = sanitizeOsString(sd.id, 64);
        sj["display_name"] = sanitizeOsString(sd.display_name, 160);
        sj["bus"] = jsonStringOrNull(sd.bus, 32);
        sj["media_type"] = sd.media_type;
        sj["capacity_bytes"] = jsonNullableUlong(sd.capacity_bytes);
        JSONValue[] mnts;
        foreach (m; sd.mounts) mnts ~= JSONValue(sanitizeOsString(m, 256));
        sj["mounts"] = JSONValue(mnts);
        stors ~= sj;
    }
    j["storage_devices"] = JSONValue(stors);

    JSONValue[] gpus;
    foreach (ga; hw.graphics_adapters) {
        JSONValue gj = JSONValue.emptyObject;
        gj["id"] = jsonStringOrNull(ga.id, 64);
        gj["display_name"] = sanitizeOsString(ga.display_name, 160);
        gj["vendor"] = jsonStringOrNull(ga.vendor, 64);
        gj["driver"] = jsonStringOrNull(ga.driver, 64);
        gj["vendor_id"] = jsonStringOrNull(ga.vendor_id, 16);
        gj["device_id"] = jsonStringOrNull(ga.device_id, 16);
        gj["memory_total_bytes"] = jsonNullableUlong(ga.memory_total_bytes);
        gpus ~= gj;
    }
    j["graphics_adapters"] = JSONValue(gpus);

    JSONValue caps = JSONValue.emptyObject;
    foreach (k, v; hw.capabilities) {
        caps[k] = cast(string) v;
    }
    j["capabilities"] = caps;

    return j;
}

private string readOptStr(const ref JSONValue obj, string key) {
    if (auto p = key in obj.object) if (p.type == JSONType.string) return p.str;
    return "";
}

private Nullable!long readOptLong(const ref JSONValue obj, string key) {
    Nullable!long res;
    if (auto p = key in obj.object) {
        if (p.type == JSONType.integer) res = p.integer;
        else if (p.type == JSONType.uinteger) res = cast(long) p.uinteger;
    }
    return res;
}

private Nullable!ulong readOptUlong(const ref JSONValue obj, string key) {
    Nullable!ulong res;
    if (auto p = key in obj.object) {
        if (p.type == JSONType.integer && p.integer >= 0) res = cast(ulong) p.integer;
        else if (p.type == JSONType.uinteger) res = p.uinteger;
    }
    return res;
}

private Nullable!uint readOptUint(const ref JSONValue obj, string key) {
    Nullable!uint res;
    if (auto p = key in obj.object) {
        if (p.type == JSONType.integer && p.integer >= 0) res = cast(uint) p.integer;
        else if (p.type == JSONType.uinteger) res = cast(uint) p.uinteger;
    }
    return res;
}

private CapabilityState parseCapState(string s) pure nothrow @safe {
    switch (s) {
        case "ok": return CapabilityState.ok;
        case "unsupported": return CapabilityState.unsupported;
        case "permission_denied": return CapabilityState.permission_denied;
        case "error": return CapabilityState.error;
        default: return CapabilityState.unavailable;
    }
}

HardwareInventory parseHardwareInventoryJson(string jsonStr) {
    HardwareInventory hw;
    auto j = parseJSON(jsonStr);
    if (j.type != JSONType.object) throw new Exception("Hardware cache must be JSON object");

    hw.app = readOptStr(j, "app");
    if (auto p = "schema_version" in j.object) {
        if (p.type == JSONType.integer) hw.schema_version = cast(int) p.integer;
    }
    hw.node_id = readOptStr(j, "node_id");
    hw.collected_at = readOptLong(j, "collected_at");

    if (auto pCol = "collection" in j.object) {
        if (pCol.type == JSONType.object) {
            auto st = readOptStr(*pCol, "status");
            if (st == "fresh") hw.collection.status = GroupStatus.fresh;
            else if (st == "stale") hw.collection.status = GroupStatus.stale;
            else if (st == "error") hw.collection.status = GroupStatus.error;
            if (auto pp = "partial" in pCol.object) {
                hw.collection.partial = (pp.type == JSONType.true_);
            }
            hw.collection.error = readOptStr(*pCol, "error");
        }
    }

    if (auto pSys = "system" in j.object) if (pSys.type == JSONType.object) {
        hw.system.manufacturer = readOptStr(*pSys, "manufacturer");
        hw.system.model = readOptStr(*pSys, "model");
        hw.system.product_family = readOptStr(*pSys, "product_family");
        hw.system.form_factor = readOptStr(*pSys, "form_factor");
        hw.system.virtualization = readOptStr(*pSys, "virtualization");
    }

    if (auto pBrd = "board" in j.object) if (pBrd.type == JSONType.object) {
        hw.board.manufacturer = readOptStr(*pBrd, "manufacturer");
        hw.board.model = readOptStr(*pBrd, "model");
        hw.board.revision = readOptStr(*pBrd, "revision");
    }

    if (auto pFw = "firmware" in j.object) if (pFw.type == JSONType.object) {
        hw.firmware.type = readOptStr(*pFw, "type");
        hw.firmware.vendor = readOptStr(*pFw, "vendor");
        hw.firmware.version_str = readOptStr(*pFw, "version");
        hw.firmware.release_date = readOptStr(*pFw, "release_date");
    }

    if (auto pCpu = "cpu" in j.object) if (pCpu.type == JSONType.object) {
        hw.cpu.display_name = readOptStr(*pCpu, "display_name");
        hw.cpu.vendor = readOptStr(*pCpu, "vendor");
        hw.cpu.architecture = readOptStr(*pCpu, "architecture");
        hw.cpu.microarchitecture = readOptStr(*pCpu, "microarchitecture");
        hw.cpu.sockets = readOptUint(*pCpu, "sockets");
        hw.cpu.physical_cores = readOptUint(*pCpu, "physical_cores");
        hw.cpu.logical_cores = readOptUint(*pCpu, "logical_cores");
        hw.cpu.performance_cores = readOptUint(*pCpu, "performance_cores");
        hw.cpu.efficiency_cores = readOptUint(*pCpu, "efficiency_cores");
        if (auto pCache = "cache_bytes" in pCpu.object) if (pCache.type == JSONType.object) {
            hw.cpu.cache_bytes.l1d = readOptUlong(*pCache, "l1d");
            hw.cpu.cache_bytes.l1i = readOptUlong(*pCache, "l1i");
            hw.cpu.cache_bytes.l2 = readOptUlong(*pCache, "l2");
            hw.cpu.cache_bytes.l3 = readOptUlong(*pCache, "l3");
        }
        if (auto pIsa = "isa" in pCpu.object) if (pIsa.type == JSONType.object) {
            if (auto ph = "hardware" in pIsa.object) if (ph.type == JSONType.array) {
                foreach (e; ph.array) if (e.type == JSONType.string) hw.cpu.isa.hardware ~= e.str;
            }
            if (auto pu = "usable" in pIsa.object) if (pu.type == JSONType.array) {
                foreach (e; pu.array) if (e.type == JSONType.string) hw.cpu.isa.usable ~= e.str;
            }
            hw.cpu.isa.detection = readOptStr(*pIsa, "detection");
        }
    }

    if (auto pMem = "memory" in j.object) if (pMem.type == JSONType.object) {
        hw.memory.total_bytes = readOptUlong(*pMem, "total_bytes");
        hw.memory.technology = readOptStr(*pMem, "technology");
        hw.memory.speed_mt_s = readOptUint(*pMem, "speed_mt_s");
        hw.memory.module_enumeration = parseCapState(readOptStr(*pMem, "module_enumeration"));
    }

    if (auto pNics = "network_adapters" in j.object) if (pNics.type == JSONType.array) {
        foreach (el; pNics.array) if (el.type == JSONType.object) {
            NetworkAdapterHardware na;
            na.id = readOptStr(el, "id");
            na.display_name = readOptStr(el, "display_name");
            na.interface_name = readOptStr(el, "interface");
            na.kind = readOptStr(el, "kind");
            na.bus = readOptStr(el, "bus");
            na.driver = readOptStr(el, "driver");
            na.vendor_id = readOptStr(el, "vendor_id");
            na.device_id = readOptStr(el, "device_id");
            na.link_speed_bps = readOptUlong(el, "link_speed_bps");
            hw.network_adapters ~= na;
        }
    }

    if (auto pStor = "storage_devices" in j.object) if (pStor.type == JSONType.array) {
        foreach (el; pStor.array) if (el.type == JSONType.object) {
            StorageDeviceHardware sd;
            sd.id = readOptStr(el, "id");
            sd.display_name = readOptStr(el, "display_name");
            sd.bus = readOptStr(el, "bus");
            sd.media_type = readOptStr(el, "media_type");
            sd.capacity_bytes = readOptUlong(el, "capacity_bytes");
            if (auto pm = "mounts" in el.object) if (pm.type == JSONType.array) {
                foreach (m; pm.array) if (m.type == JSONType.string) sd.mounts ~= m.str;
            }
            hw.storage_devices ~= sd;
        }
    }

    if (auto pGpus = "graphics_adapters" in j.object) if (pGpus.type == JSONType.array) {
        foreach (el; pGpus.array) if (el.type == JSONType.object) {
            GraphicsAdapterHardware ga;
            ga.id = readOptStr(el, "id");
            ga.display_name = readOptStr(el, "display_name");
            ga.vendor = readOptStr(el, "vendor");
            ga.driver = readOptStr(el, "driver");
            ga.vendor_id = readOptStr(el, "vendor_id");
            ga.device_id = readOptStr(el, "device_id");
            ga.memory_total_bytes = readOptUlong(el, "memory_total_bytes");
            hw.graphics_adapters ~= ga;
        }
    }

    if (auto pCaps = "capabilities" in j.object) if (pCaps.type == JSONType.object) {
        foreach (k, v; pCaps.object) {
            if (v.type == JSONType.string) hw.capabilities[k] = parseCapState(v.str);
        }
    }

    return hw;
}

JSONValue serializeNodesResponse(const ref NodesResponse nr) pure @safe {
    JSONValue j = JSONValue.emptyObject;
    j["schema_version"] = nr.schema_version;
    j["generated_at"] = nr.generated_at;
    JSONValue[] arr;
    foreach (n; nr.nodes) {
        JSONValue nj = JSONValue.emptyObject;
        nj["node_id"] = n.node_id;
        nj["tailscale_node_id"] = jsonStringOrNull(n.tailscale_node_id, 64);
        nj["name"] = sanitizeOsString(n.name, 128);
        nj["alias"] = jsonStringOrNull(n.alias_name, 128);
        nj["fqdn"] = jsonStringOrNull(n.fqdn, 253);
        nj["status_url"] = jsonStringOrNull(n.status_url, 512);
        nj["hardware_url"] = jsonStringOrNull(n.hardware_url, 512);
        nj["info_url"] = jsonStringOrNull(n.info_url, 512);
        nj["tailnet_port"] = n.tailnet_port;
        nj["base_path"] = n.base_path.length ? n.base_path : "/";
        nj["os"] = jsonStringOrNull(n.os, 32);
        nj["arch"] = jsonStringOrNull(n.arch, 32);
        nj["is_self"] = n.is_self;
        nj["tailscale_online"] = jsonNullableBool(n.tailscale_online);
        nj["discovery_state"] = n.discovery_state;
        nj["last_seen_ts"] = jsonNullableLong(n.last_seen_ts);
        nj["last_success_ts"] = jsonNullableLong(n.last_success_ts);
        if (n.last_known_hardware_summary.isNull) {
            nj["last_known_hardware_summary"] = jsonNull();
        } else {
            auto hs = n.last_known_hardware_summary.get;
            nj["last_known_hardware_summary"] = serializeHardwareSummary(hs);
        }
        nj["hidden"] = n.hidden;
        arr ~= nj;
    }
    j["nodes"] = JSONValue(arr);
    if (!nr.discovery.isNull) {
        auto d = nr.discovery.get;
        JSONValue dj = JSONValue.emptyObject;
        dj["running"] = d.running;
        dj["last_started_at"] = jsonNullableLong(d.last_started_at);
        dj["last_finished_at"] = jsonNullableLong(d.last_finished_at);
        dj["tailscale_available"] = d.tailscale_available;
        j["discovery"] = dj;
    }
    return j;
}

JSONValue serializeInfoResponse(const ref InfoResponse ir) pure @safe {
    JSONValue j = JSONValue.emptyObject;
    j["app"] = ir.app;
    j["schema_version"] = ir.schema_version;
    j["agent_version"] = ir.agent_version;
    j["node_id"] = ir.node_id;
    j["host"] = sanitizeOsString(ir.host, 128);
    j["fqdn"] = jsonStringOrNull(ir.fqdn, 253);
    j["os"] = ir.os;
    j["arch"] = ir.arch;
    j["tailnet_port"] = ir.tailnet_port;
    j["base_path"] = ir.base_path.length ? ir.base_path : "/";
    j["server_ts"] = ir.server_ts;
    j["uptime_s"] = jsonNullableLong(ir.uptime_s);
    j["health"] = ir.health;
    if (ir.hardware_summary.isNull) {
        j["hardware_summary"] = jsonNull();
    } else {
        auto hs = ir.hardware_summary.get;
        j["hardware_summary"] = serializeHardwareSummary(hs);
    }
    return j;
}

JSONValue serializeHealthResponse(const ref HealthResponse hr) pure @safe {
    JSONValue j = JSONValue.emptyObject;
    j["app"] = hr.app;
    j["schema_version"] = hr.schema_version;
    j["agent_version"] = hr.agent_version;
    j["status"] = hr.status;
    j["node_id"] = hr.node_id;
    j["server_ts"] = hr.server_ts;
    return j;
}

JSONValue serializeCollectingResponse(const ref CollectingResponse cr) pure @safe {
    JSONValue j = JSONValue.emptyObject;
    j["app"] = cr.app;
    j["schema_version"] = cr.schema_version;
    j["status"] = cr.status;
    j["retry_after_s"] = cr.retry_after_s;
    return j;
}

JSONValue serializeErrorResponse(string errCode, string message, GroupMeta[string] groups = null) pure @safe {
    JSONValue j = JSONValue.emptyObject;
    j["app"] = "hikari";
    j["schema_version"] = SCHEMA_VERSION;
    j["status"] = "error";
    j["error"] = sanitizeOsString(errCode, 64);
    j["message"] = sanitizeOsString(message, 256);
    if (groups !is null) {
        JSONValue gs = JSONValue.emptyObject;
        foreach (k, gm; groups) gs[k] = serializeGroupMeta(gm);
        j["groups"] = gs;
    }
    return j;
}

JSONValue serializeDoctorReport(const ref DoctorReport dr) pure @safe {
    JSONValue j = JSONValue.emptyObject;
    j["app"] = dr.app;
    j["schema_version"] = dr.schema_version;
    j["agent_version"] = dr.agent_version;
    j["overall"] = dr.overall;
    JSONValue[] arr;
    foreach (c; dr.checks) {
        JSONValue cj = JSONValue.emptyObject;
        cj["name"] = c.name;
        cj["status"] = c.status;
        cj["summary"] = c.summary;
        if (c.remediation.length > 0) cj["remediation"] = c.remediation;
        arr ~= cj;
    }
    j["checks"] = JSONValue(arr);
    return j;
}

string toJsonText(JSONValue v, bool pretty = false) {
    if (pretty) return v.toPrettyString(JSONOptions.doNotEscapeSlashes) ~ "\n";
    return v.toString(JSONOptions.doNotEscapeSlashes);
}
