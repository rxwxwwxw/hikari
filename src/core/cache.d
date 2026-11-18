module core.cache;

import core.config;
import core.model;
import core.serializer;
import core.tracker;
import std.algorithm : sort;
import std.file : exists, mkdirRecurse, readText, rename, write;
import std.json : JSONOptions;
import std.typecons : Nullable;

struct GroupCacheEntry {
    bool hasSuccess = false;
    bool unsupported = false;
    bool inFlight = false;
    /// True while the worker can still be collecting. A probe
    /// that exceeded its deadline is no longer `inFlight`, but its thread may
    /// still be blocked inside the OS; no second worker starts until it exits.
    bool workerAlive = false;
    ulong workerGeneration = 0;
    long lastSuccessMonoNs = 0;
    long lastSuccessWallTs = 0;
    long lastAttemptMonoNs = 0;
    long inFlightStartedMonoNs = 0;
    long backoffUntilMonoNs = 0;
    uint consecutiveFailures = 0;
    string lastError;
    ulong generation = 0;
}

class TelemetryCacheStore {
    HikariConfig config;
    string nodeId;
    string fqdn;

    SystemRateState rateState;
    GroupCacheEntry[ProbeGroup] groups;

    // Cached group payloads
    PlatformIdentity cachedIdentity;
    CpuStatus cachedCpu;
    MemoryStatus cachedMemory;
    Nullable!SwapStatus cachedSwap;
    Nullable!CommitStatus cachedCommit;
    NetworkInterfaceStatus[] cachedNetwork;
    ProcessStatus[] cachedTopCpu;
    ProcessStatus[] cachedTopMem;
    MountStatus[] cachedMounts;
    GpuDynamicStatus[] cachedGpus;
    BatteryStatus[] cachedBatteries;
    DriftStatus cachedDrift;
    Nullable!HardwareInventory cachedHardware;
    Nullable!HardwareSummary cachedHardwareSummary;

    this(HikariConfig cfg, string nodeId) {
        this.config = cfg;
        this.nodeId = nodeId;
        this.rateState = new SystemRateState();
        foreach (g; [
            ProbeGroup.fast,
            ProbeGroup.processes,
            ProbeGroup.device_dynamic,
            ProbeGroup.filesystems,
            ProbeGroup.tailnet,
            ProbeGroup.maintenance,
            ProbeGroup.hardware,
        ]) {
            groups[g] = GroupCacheEntry.init;
        }
        loadPersistedHardware();
    }

    string hardwareCachePath() const pure @safe {
        return config.paths.state_dir ~ "/hardware_cache.json";
    }

    void loadPersistedHardware() {
        auto path = hardwareCachePath();
        if (!exists(path)) return;
        try {
            auto hw = parseHardwareInventoryJson(readText(path));
            if (hw.schema_version == SCHEMA_VERSION) {
                if (hw.node_id.length == 0) hw.node_id = nodeId;
                cachedHardware = hw;
                updateHardwareSummaryFromInventory(hw);
                if (!hw.collected_at.isNull) {
                    // Mark persisted hardware as usable/stale until TTL or max_stale evaluated
                    // Persisted across restarts: set monoNs baseline relative to now only if wall age known,
                    // or keep hasSuccess=true with lastSuccessWallTs so wall-age check knows its real age.
                    auto entry = groups[ProbeGroup.hardware];
                    entry.hasSuccess = true;
                    entry.lastSuccessWallTs = hw.collected_at.get;
                    // On restart, monotonic clock starts fresh; keep lastSuccessMonoNs = -1 sentinel
                    // so wall age determines freshness accurately without rescanning needlessly!
                    entry.lastSuccessMonoNs = -1;
                    groups[ProbeGroup.hardware] = entry;
                }
            }
        } catch (Exception) {
            // Corrupt cache file ignored safely; next hardware request will refresh
        }
    }

    void persistHardware(const ref HardwareInventory hw) {
        try {
            if (!exists(config.paths.state_dir)) {
                mkdirRecurse(config.paths.state_dir);
            }
            auto path = hardwareCachePath();
            auto tmp = path ~ ".tmp";
            auto text = serializeHardwareInventory(hw).toPrettyString(JSONOptions.doNotEscapeSlashes) ~ "\n";
            write(tmp, text);
            rename(tmp, path);
        } catch (Exception) {
            // Non-fatal if state dir is read-only (e.g. one-shot CLI test)
        }
    }

    void updateHardwareSummaryFromInventory(const ref HardwareInventory hw) @safe {
        HardwareSummary hs;
        hs.cpu = hw.cpu.display_name;
        hs.ram_bytes = hw.memory.total_bytes;
        if (hw.system.model.length > 0 && hw.system.manufacturer.length > 0) {
            hs.system_model = hw.system.manufacturer ~ " " ~ hw.system.model;
        } else if (hw.system.model.length > 0) {
            hs.system_model = hw.system.model;
        }
        cachedHardwareSummary = hs;
    }

    long computeGroupAgeS(ProbeGroup g, long nowMonoNs, long nowWallTs) const pure nothrow @safe {
        auto e = groups[g];
        if (!e.hasSuccess) return long.max;
        if (e.lastSuccessMonoNs >= 0) {
            long d = (nowMonoNs - e.lastSuccessMonoNs) / 1_000_000_000L;
            return d < 0 ? 0 : d;
        }
        // Restored persisted entry (hardware): use wall clock safely clamped
        long dw = nowWallTs - e.lastSuccessWallTs;
        return dw < 0 ? 0 : dw;
    }

    bool isFresh(ProbeGroup g, long nowMonoNs, long nowWallTs) const pure nothrow @safe {
        auto e = groups[g];
        long ttl = config.collection.ttl_seconds.get(g);
        if (e.unsupported && !e.hasSuccess) {
            long d = (e.lastAttemptMonoNs >= 0 && nowMonoNs >= e.lastAttemptMonoNs)
                ? (nowMonoNs - e.lastAttemptMonoNs) / 1_000_000_000L
                : long.max;
            return d < ttl;
        }
        if (!e.hasSuccess) return false;
        return computeGroupAgeS(g, nowMonoNs, nowWallTs) < ttl;
    }

    bool isUsableStale(ProbeGroup g, long nowMonoNs, long nowWallTs) const pure nothrow @safe {
        auto e = groups[g];
        if (!e.hasSuccess) return false;
        long ageS = computeGroupAgeS(g, nowMonoNs, nowWallTs);
        return ageS <= config.collection.max_stale_seconds.get(g);
    }

    GroupMeta buildGroupMeta(ProbeGroup g, long nowMonoNs, long nowWallTs) const pure @safe {
        auto e = groups[g];
        GroupMeta gm;
        gm.refreshing = e.inFlight;
        // A completed probe publishes its sample before its thread exits. Only
        // a worker reaped for timeout is hung during that short cleanup window.
        bool hung = e.workerAlive && !e.inFlight && e.lastError == "probe_timeout";
        if (e.hasSuccess) {
            long age = computeGroupAgeS(g, nowMonoNs, nowWallTs);
            gm.sampled_at = e.lastSuccessWallTs;
            gm.age_s = age;
            gm.last_success_at = e.lastSuccessWallTs;
            if (e.consecutiveFailures > 0 || hung) {
                gm.status = isUsableStale(g, nowMonoNs, nowWallTs) ? GroupStatus.stale : GroupStatus.error;
                gm.error = hung ? "probe_hung" : e.lastError;
            } else if (age < config.collection.ttl_seconds.get(g)) {
                gm.status = GroupStatus.fresh;
            } else if (age <= config.collection.max_stale_seconds.get(g)) {
                gm.status = GroupStatus.stale;
            } else {
                gm.status = GroupStatus.error;
                gm.error = "stale_ceiling_exceeded";
            }
        } else if (e.unsupported) {
            gm.status = GroupStatus.unsupported;
        } else if (e.consecutiveFailures > 0 || hung) {
            gm.status = GroupStatus.error;
            gm.error = hung ? "probe_hung" : e.lastError;
        } else if (e.inFlight) {
            gm.status = GroupStatus.uninitialized;
            gm.refreshing = true;
        } else {
            gm.status = GroupStatus.uninitialized;
        }
        return gm;
    }

    StatusResponse snapshotStatusResponse(long nowMonoNs, long nowWallTs) const @safe {
        StatusResponse resp;
        resp.app = "hikari";
        resp.schema_version = SCHEMA_VERSION;
        resp.agent_version = AGENT_VERSION;
        resp.node_id = nodeId;
        resp.host = cachedIdentity.host;
        resp.fqdn = fqdn;
        resp.os = cachedIdentity.os;
        resp.arch = cachedIdentity.arch;
        resp.server_ts = nowWallTs;
        resp.boot_id = cachedIdentity.boot_id;
        resp.uptime_s = cachedIdentity.uptime_s;
        resp.hardware_summary = cachedHardwareSummary;

        foreach (g; [ProbeGroup.fast, ProbeGroup.processes, ProbeGroup.device_dynamic, ProbeGroup.filesystems, ProbeGroup.maintenance]) {
            resp.groups[cast(string) g] = buildGroupMeta(g, nowMonoNs, nowWallTs);
        }

        if (isUsableStale(ProbeGroup.fast, nowMonoNs, nowWallTs)) {
            resp.cpu = cachedCpu;
            resp.memory = cachedMemory;
            resp.swap = cachedSwap;
            resp.commit = cachedCommit;
            resp.network = cachedNetwork.dup;
        }
        if (isUsableStale(ProbeGroup.processes, nowMonoNs, nowWallTs)) {
            resp.top_cpu = cachedTopCpu.dup;
            resp.top_mem = cachedTopMem.dup;
        }
        if (isUsableStale(ProbeGroup.filesystems, nowMonoNs, nowWallTs)) {
            resp.mounts = cachedMounts.dup;
        }
        if (isUsableStale(ProbeGroup.device_dynamic, nowMonoNs, nowWallTs)) {
            resp.gpus = cachedGpus.dup;
            resp.batteries = cachedBatteries.dup;
        }
        if (isUsableStale(ProbeGroup.maintenance, nowMonoNs, nowWallTs)) {
            resp.drift = cachedDrift;
        }
        return resp;
    }

    HardwareInventory snapshotHardwareResponse(long nowMonoNs, long nowWallTs) @safe {
        HardwareInventory hw;
        if (!cachedHardware.isNull) {
            hw = cachedHardware.get;
        }
        hw.app = "hikari";
        hw.schema_version = SCHEMA_VERSION;
        hw.node_id = nodeId;
        auto gm = buildGroupMeta(ProbeGroup.hardware, nowMonoNs, nowWallTs);
        hw.collection.status = gm.status;
        hw.collection.age_s = gm.age_s;
        hw.collection.refreshing = gm.refreshing;
        hw.collection.error = gm.error;
        return hw;
    }

    InfoResponse buildInfoResponse(long nowWallTs) const @safe {
        InfoResponse ir;
        ir.app = "hikari";
        ir.schema_version = SCHEMA_VERSION;
        ir.agent_version = AGENT_VERSION;
        ir.node_id = nodeId;
        ir.host = cachedIdentity.host;
        ir.fqdn = fqdn;
        ir.os = cachedIdentity.os;
        ir.arch = cachedIdentity.arch;
        ir.tailnet_port = config.listen.tailnet_port;
        ir.base_path = config.listen.base_path;
        ir.server_ts = nowWallTs;
        ir.uptime_s = cachedIdentity.uptime_s;
        ir.health = (groups[ProbeGroup.fast].consecutiveFailures > 0 && !groups[ProbeGroup.fast].hasSuccess) ? "degraded" : "ok";
        ir.hardware_summary = cachedHardwareSummary;
        return ir;
    }
}
