module core.cache;

import core.config;
import core.limits;
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

struct InfoScratch {
    FixedString!64 hikariVer;
    FixedString!64 caddyVer;
    FixedString!64 tailscaleVer;
    FixedString!128 host;
    FixedString!256 fqdn;
    FixedString!32 os;
    FixedString!32 arch;
}

class TelemetryCacheStore {
    HikariConfig config;
    string nodeId;
    string fqdn;
    private FixedString!256 fqdnStore;

    SystemRateState rateState;
    GroupCacheEntry[ProbeGroup] groups;

    // Cached group payloads (backed by preallocated inline string storage)
    PlatformIdentity cachedIdentity;
    private FixedString!128 idHostStore;
    private FixedString!32 idOsStore;
    private FixedString!32 idArchStore;
    private FixedString!128 idBootStore;

    CpuStatus cachedCpu;
    MemoryStatus cachedMemory;
    Nullable!SwapStatus cachedSwap;
    Nullable!CommitStatus cachedCommit;

    private NetworkInterfaceStatus[MAX_NETWORK_INTERFACES] cachedNetworkBuf;
    private size_t cachedNetworkLen = 0;
    private FixedString!64[MAX_NETWORK_INTERFACES] cachedNetIdStore;
    private FixedString!64[MAX_NETWORK_INTERFACES] cachedNetNameStore;
    private FixedString!16[MAX_NETWORK_INTERFACES] cachedNetKindStore;

    private ProcessStatus[MAX_TOP_PROCESSES] cachedTopCpuBuf;
    private size_t cachedTopCpuLen = 0;
    private FixedString!31[MAX_TOP_PROCESSES] cachedTopCpuStartStore;
    private FixedString!128[MAX_TOP_PROCESSES] cachedTopCpuNameStore;

    private ProcessStatus[MAX_TOP_PROCESSES] cachedTopMemBuf;
    private size_t cachedTopMemLen = 0;
    private FixedString!31[MAX_TOP_PROCESSES] cachedTopMemStartStore;
    private FixedString!128[MAX_TOP_PROCESSES] cachedTopMemNameStore;

    private MountStatus[MAX_FILESYSTEM_MOUNTS] cachedMountsBuf;
    private size_t cachedMountsLen = 0;
    private FixedString!512[MAX_FILESYSTEM_MOUNTS] cachedMountPathStore;
    private FixedString!256[MAX_FILESYSTEM_MOUNTS] cachedMountSrcStore;
    private FixedString!64[MAX_FILESYSTEM_MOUNTS] cachedMountFsStore;

    private GpuDynamicStatus[MAX_GPUS] cachedGpusBuf;
    private size_t cachedGpusLen = 0;
    private FixedString!64[MAX_GPUS] cachedGpuIdStore;
    private FixedString!160[MAX_GPUS] cachedGpuNameStore;
    private FixedString!64[MAX_GPUS] cachedGpuVendorStore;
    private FixedString!128[MAX_GPUS] cachedGpuErrStore;

    private BatteryStatus[MAX_BATTERIES] cachedBatteriesBuf;
    private size_t cachedBatteriesLen = 0;
    private FixedString!64[MAX_BATTERIES] cachedBatIdStore;
    private FixedString!64[MAX_BATTERIES] cachedBatNameStore;
    private FixedString!32[MAX_BATTERIES] cachedBatStatusStore;

    DriftStatus cachedDrift;
    private FixedString!128 driftRunKernelStore;
    private FixedString!128 driftInstKernelStore;
    private FixedString!64 driftHikariVerStore;
    private FixedString!64 driftCaddyVerStore;
    private FixedString!64 driftTailscaleVerStore;

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

    @nogc nothrow @safe {
        void setFqdn(const(char)[] f) {
            fqdnStore.set(f);
            fqdn = fqdnStore.slice();
        }

        void setIdentity(const ref PlatformIdentity id) {
            idHostStore.set(id.host);
            idOsStore.set(id.os);
            idArchStore.set(id.arch);
            idBootStore.set(id.boot_id);
            cachedIdentity.host = idHostStore.slice();
            cachedIdentity.os = idOsStore.slice();
            cachedIdentity.arch = idArchStore.slice();
            cachedIdentity.boot_id = idBootStore.slice();
            cachedIdentity.uptime_s = id.uptime_s;
        }

        void setNetwork(const NetworkInterfaceStatus[] items) {
            size_t n = items.length > MAX_NETWORK_INTERFACES ? MAX_NETWORK_INTERFACES : items.length;
            foreach (i; 0 .. n) {
                cachedNetIdStore[i].set(items[i].id);
                cachedNetNameStore[i].set(items[i].name);
                cachedNetKindStore[i].set(items[i].kind);
                cachedNetworkBuf[i] = items[i];
                cachedNetworkBuf[i].id = cachedNetIdStore[i].slice();
                cachedNetworkBuf[i].name = cachedNetNameStore[i].slice();
                cachedNetworkBuf[i].kind = cachedNetKindStore[i].slice();
            }
            cachedNetworkLen = n;
        }

        void setTopCpu(const ProcessStatus[] items) {
            size_t n = items.length > MAX_TOP_PROCESSES ? MAX_TOP_PROCESSES : items.length;
            foreach (i; 0 .. n) {
                cachedTopCpuStartStore[i].set(items[i].start_id);
                cachedTopCpuNameStore[i].set(items[i].name);
                cachedTopCpuBuf[i] = items[i];
                cachedTopCpuBuf[i].start_id = cachedTopCpuStartStore[i].slice();
                cachedTopCpuBuf[i].name = cachedTopCpuNameStore[i].slice();
            }
            cachedTopCpuLen = n;
        }

        void setTopMem(const ProcessStatus[] items) {
            size_t n = items.length > MAX_TOP_PROCESSES ? MAX_TOP_PROCESSES : items.length;
            foreach (i; 0 .. n) {
                cachedTopMemStartStore[i].set(items[i].start_id);
                cachedTopMemNameStore[i].set(items[i].name);
                cachedTopMemBuf[i] = items[i];
                cachedTopMemBuf[i].start_id = cachedTopMemStartStore[i].slice();
                cachedTopMemBuf[i].name = cachedTopMemNameStore[i].slice();
            }
            cachedTopMemLen = n;
        }

        void setMounts(const MountStatus[] items) {
            size_t n = items.length > MAX_FILESYSTEM_MOUNTS ? MAX_FILESYSTEM_MOUNTS : items.length;
            foreach (i; 0 .. n) {
                cachedMountPathStore[i].set(items[i].mount);
                cachedMountSrcStore[i].set(items[i].source);
                cachedMountFsStore[i].set(items[i].fs);
                cachedMountsBuf[i] = items[i];
                cachedMountsBuf[i].mount = cachedMountPathStore[i].slice();
                cachedMountsBuf[i].source = cachedMountSrcStore[i].slice();
                cachedMountsBuf[i].fs = cachedMountFsStore[i].slice();
            }
            cachedMountsLen = n;
        }

        void setGpus(const GpuDynamicStatus[] items) {
            size_t n = items.length > MAX_GPUS ? MAX_GPUS : items.length;
            foreach (i; 0 .. n) {
                cachedGpuIdStore[i].set(items[i].id);
                cachedGpuNameStore[i].set(items[i].display_name);
                cachedGpuVendorStore[i].set(items[i].vendor);
                cachedGpuErrStore[i].set(items[i].error);
                cachedGpusBuf[i] = items[i];
                cachedGpusBuf[i].id = cachedGpuIdStore[i].slice();
                cachedGpusBuf[i].display_name = cachedGpuNameStore[i].slice();
                cachedGpusBuf[i].vendor = cachedGpuVendorStore[i].slice();
                cachedGpusBuf[i].error = cachedGpuErrStore[i].slice();
            }
            cachedGpusLen = n;
        }

        void setBatteries(const BatteryStatus[] items) {
            size_t n = items.length > MAX_BATTERIES ? MAX_BATTERIES : items.length;
            foreach (i; 0 .. n) {
                cachedBatIdStore[i].set(items[i].id);
                cachedBatNameStore[i].set(items[i].name);
                cachedBatStatusStore[i].set(items[i].status);
                cachedBatteriesBuf[i] = items[i];
                cachedBatteriesBuf[i].id = cachedBatIdStore[i].slice();
                cachedBatteriesBuf[i].name = cachedBatNameStore[i].slice();
                cachedBatteriesBuf[i].status = cachedBatStatusStore[i].slice();
            }
            cachedBatteriesLen = n;
        }

        void setDrift(const ref DriftStatus d) {
            driftRunKernelStore.set(d.running_kernel);
            driftInstKernelStore.set(d.installed_kernel);
            driftHikariVerStore.set(d.hikari_version);
            driftCaddyVerStore.set(d.caddy_version);
            driftTailscaleVerStore.set(d.tailscale_version);
            cachedDrift = d;
            cachedDrift.running_kernel = driftRunKernelStore.slice();
            cachedDrift.installed_kernel = driftInstKernelStore.slice();
            cachedDrift.hikari_version = driftHikariVerStore.slice();
            cachedDrift.caddy_version = driftCaddyVerStore.slice();
            cachedDrift.tailscale_version = driftTailscaleVerStore.slice();
        }
    }

    @property NetworkInterfaceStatus[] cachedNetwork() return @safe { return cachedNetworkBuf[0 .. cachedNetworkLen]; }
    @property void cachedNetwork(const NetworkInterfaceStatus[] items) @nogc nothrow @safe { setNetwork(items); }

    @property ProcessStatus[] cachedTopCpu() return @safe { return cachedTopCpuBuf[0 .. cachedTopCpuLen]; }
    @property void cachedTopCpu(const ProcessStatus[] items) @nogc nothrow @safe { setTopCpu(items); }

    @property ProcessStatus[] cachedTopMem() return @safe { return cachedTopMemBuf[0 .. cachedTopMemLen]; }
    @property void cachedTopMem(const ProcessStatus[] items) @nogc nothrow @safe { setTopMem(items); }

    @property MountStatus[] cachedMounts() return @safe { return cachedMountsBuf[0 .. cachedMountsLen]; }
    @property void cachedMounts(const MountStatus[] items) @nogc nothrow @safe { setMounts(items); }

    @property GpuDynamicStatus[] cachedGpus() return @safe { return cachedGpusBuf[0 .. cachedGpusLen]; }
    @property void cachedGpus(const GpuDynamicStatus[] items) @nogc nothrow @safe { setGpus(items); }

    @property BatteryStatus[] cachedBatteries() return @safe { return cachedBatteriesBuf[0 .. cachedBatteriesLen]; }
    @property void cachedBatteries(const BatteryStatus[] items) @nogc nothrow @safe { setBatteries(items); }

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
                    auto entry = groups[ProbeGroup.hardware];
                    entry.hasSuccess = true;
                    entry.lastSuccessWallTs = hw.collected_at.get;
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
        if (hw.system.product_family.length > 0 && hw.system.model.length > 0 && hw.system.product_family != hw.system.model) {
            hs.system_model = hw.system.product_family ~ " (" ~ hw.system.model ~ ")";
        } else if (hw.system.model.length > 0 && hw.system.manufacturer.length > 0) {
            hs.system_model = hw.system.manufacturer ~ " " ~ hw.system.model;
        } else if (hw.system.model.length > 0) {
            hs.system_model = hw.system.model;
        }
        cachedHardwareSummary = hs;
    }

    long computeGroupAgeS(ProbeGroup g, long nowMonoNs, long nowWallTs) const pure nothrow @nogc @safe {
        auto p = g in groups;
        if (p is null || !p.hasSuccess) return long.max;
        if (p.lastSuccessMonoNs >= 0) {
            long d = (nowMonoNs - p.lastSuccessMonoNs) / 1_000_000_000L;
            return d < 0 ? 0 : d;
        }
        long dw = nowWallTs - p.lastSuccessWallTs;
        return dw < 0 ? 0 : dw;
    }

    bool isFresh(ProbeGroup g, long nowMonoNs, long nowWallTs) const pure nothrow @nogc @safe {
        auto p = g in groups;
        if (p is null) return false;
        long ttl = config.collection.ttl_seconds.get(g);
        if (p.unsupported && !p.hasSuccess) {
            long d = (p.lastAttemptMonoNs >= 0 && nowMonoNs >= p.lastAttemptMonoNs)
                ? (nowMonoNs - p.lastAttemptMonoNs) / 1_000_000_000L
                : long.max;
            return d < ttl;
        }
        if (!p.hasSuccess) return false;
        return computeGroupAgeS(g, nowMonoNs, nowWallTs) < ttl;
    }

    bool isUsableStale(ProbeGroup g, long nowMonoNs, long nowWallTs) const pure nothrow @nogc @safe {
        auto p = g in groups;
        if (p is null || !p.hasSuccess) return false;
        long ageS = computeGroupAgeS(g, nowMonoNs, nowWallTs);
        return ageS <= config.collection.max_stale_seconds.get(g);
    }

    GroupMeta buildGroupMeta(ProbeGroup g, long nowMonoNs, long nowWallTs) const pure nothrow @nogc @safe {
        auto p = g in groups;
        GroupMeta gm;
        if (p is null) return gm;
        auto e = *p;
        gm.refreshing = e.inFlight;
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

    void snapshotStatusInto(ref StatusResponse resp, long nowMonoNs, long nowWallTs) @nogc nothrow @safe {
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

        resp.use_fixed_groups = true;
        foreach (i, g; STATUS_PROBE_GROUPS) {
            resp.fixed_groups[i] = buildGroupMeta(g, nowMonoNs, nowWallTs);
        }

        if (isUsableStale(ProbeGroup.fast, nowMonoNs, nowWallTs)) {
            resp.cpu = cachedCpu;
            resp.memory = cachedMemory;
            resp.swap = cachedSwap;
            resp.commit = cachedCommit;
            resp.network = cachedNetworkBuf[0 .. cachedNetworkLen];
        } else {
            resp.cpu = CpuStatus.init;
            resp.memory = MemoryStatus.init;
            resp.swap = Nullable!SwapStatus.init;
            resp.commit = Nullable!CommitStatus.init;
            resp.network = null;
        }
        if (isUsableStale(ProbeGroup.processes, nowMonoNs, nowWallTs)) {
            resp.top_cpu = cachedTopCpuBuf[0 .. cachedTopCpuLen];
            resp.top_mem = cachedTopMemBuf[0 .. cachedTopMemLen];
        } else {
            resp.top_cpu = null;
            resp.top_mem = null;
        }
        if (isUsableStale(ProbeGroup.filesystems, nowMonoNs, nowWallTs)) {
            resp.mounts = cachedMountsBuf[0 .. cachedMountsLen];
        } else {
            resp.mounts = null;
        }
        if (isUsableStale(ProbeGroup.device_dynamic, nowMonoNs, nowWallTs)) {
            resp.gpus = cachedGpusBuf[0 .. cachedGpusLen];
            resp.batteries = cachedBatteriesBuf[0 .. cachedBatteriesLen];
        } else {
            resp.gpus = null;
            resp.batteries = null;
        }
        if (isUsableStale(ProbeGroup.maintenance, nowMonoNs, nowWallTs)) {
            resp.drift = cachedDrift;
        } else {
            resp.drift = DriftStatus.init;
        }
    }

    private static string ownedCopy(string s) pure @safe {
        return s.length > 0 ? s.idup : "";
    }

    StatusResponse snapshotStatusResponse(long nowMonoNs, long nowWallTs) @safe {
        StatusResponse resp;
        snapshotStatusInto(resp, nowMonoNs, nowWallTs);
        resp.host = ownedCopy(resp.host);
        resp.fqdn = ownedCopy(resp.fqdn);
        resp.os = ownedCopy(resp.os);
        resp.arch = ownedCopy(resp.arch);
        resp.boot_id = ownedCopy(resp.boot_id);
        resp.drift.running_kernel = ownedCopy(resp.drift.running_kernel);
        resp.drift.installed_kernel = ownedCopy(resp.drift.installed_kernel);
        resp.drift.hikari_version = ownedCopy(resp.drift.hikari_version);
        resp.drift.caddy_version = ownedCopy(resp.drift.caddy_version);
        resp.drift.tailscale_version = ownedCopy(resp.drift.tailscale_version);

        if (resp.network.length > 0) {
            auto nets = new NetworkInterfaceStatus[resp.network.length];
            foreach (i, n; resp.network) {
                nets[i] = n;
                nets[i].id = ownedCopy(n.id);
                nets[i].name = ownedCopy(n.name);
                nets[i].kind = ownedCopy(n.kind);
            }
            resp.network = nets;
        }
        if (resp.top_cpu.length > 0) {
            auto cpus = new ProcessStatus[resp.top_cpu.length];
            foreach (i, p; resp.top_cpu) {
                cpus[i] = p;
                cpus[i].start_id = ownedCopy(p.start_id);
                cpus[i].name = ownedCopy(p.name);
                cpus[i].memory_kind = ownedCopy(p.memory_kind);
            }
            resp.top_cpu = cpus;
        }
        if (resp.top_mem.length > 0) {
            auto mems = new ProcessStatus[resp.top_mem.length];
            foreach (i, p; resp.top_mem) {
                mems[i] = p;
                mems[i].start_id = ownedCopy(p.start_id);
                mems[i].name = ownedCopy(p.name);
                mems[i].memory_kind = ownedCopy(p.memory_kind);
            }
            resp.top_mem = mems;
        }
        if (resp.mounts.length > 0) {
            auto mnts = new MountStatus[resp.mounts.length];
            foreach (i, m; resp.mounts) {
                mnts[i] = m;
                mnts[i].mount = ownedCopy(m.mount);
                mnts[i].source = ownedCopy(m.source);
                mnts[i].fs = ownedCopy(m.fs);
            }
            resp.mounts = mnts;
        }
        if (resp.gpus.length > 0) {
            auto gpus = new GpuDynamicStatus[resp.gpus.length];
            foreach (i, g; resp.gpus) {
                gpus[i] = g;
                gpus[i].id = ownedCopy(g.id);
                gpus[i].display_name = ownedCopy(g.display_name);
                gpus[i].vendor = ownedCopy(g.vendor);
                gpus[i].error = ownedCopy(g.error);
            }
            resp.gpus = gpus;
        }
        if (resp.batteries.length > 0) {
            auto bats = new BatteryStatus[resp.batteries.length];
            foreach (i, b; resp.batteries) {
                bats[i] = b;
                bats[i].id = ownedCopy(b.id);
                bats[i].name = ownedCopy(b.name);
                bats[i].status = ownedCopy(b.status);
            }
            resp.batteries = bats;
        }

        foreach (i, g; STATUS_PROBE_GROUPS) {
            resp.groups[cast(string) g] = resp.fixed_groups[i];
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

    InfoResponse buildInfoResponse(long nowWallTs) const nothrow @nogc @safe {
        InfoResponse ir;
        ir.app = "hikari";
        ir.schema_version = SCHEMA_VERSION;
        ir.agent_version = AGENT_VERSION;
        ir.hikari_version = cachedDrift.hikari_version.length > 0 ? cachedDrift.hikari_version : AGENT_VERSION;
        ir.caddy_version = cachedDrift.caddy_version;
        ir.tailscale_version = cachedDrift.tailscale_version;
        ir.node_id = nodeId;
        ir.host = cachedIdentity.host;
        ir.fqdn = fqdn;
        ir.os = cachedIdentity.os;
        ir.arch = cachedIdentity.arch;
        ir.tailnet_port = config.listen.tailnet_port;
        ir.base_path = config.listen.base_path;
        ir.server_ts = nowWallTs;
        ir.uptime_s = cachedIdentity.uptime_s;
        auto fp = ProbeGroup.fast in groups;
        ir.health = (fp !is null && fp.consecutiveFailures > 0 && !fp.hasSuccess) ? "degraded" : "ok";
        ir.hardware_summary = cachedHardwareSummary;
        return ir;
    }

    InfoResponse copyInfoResponseInto(ref InfoScratch scratch, long nowWallTs) const nothrow @nogc @trusted {
        auto ir = buildInfoResponse(nowWallTs);
        scratch.hikariVer.set(ir.hikari_version);
        scratch.caddyVer.set(ir.caddy_version);
        scratch.tailscaleVer.set(ir.tailscale_version);
        scratch.host.set(ir.host);
        scratch.fqdn.set(ir.fqdn);
        scratch.os.set(ir.os);
        scratch.arch.set(ir.arch);
        ir.hikari_version = scratch.hikariVer.slice();
        ir.caddy_version = scratch.caddyVer.slice();
        ir.tailscale_version = scratch.tailscaleVer.slice();
        ir.host = scratch.host.slice();
        ir.fqdn = scratch.fqdn.slice();
        ir.os = scratch.os.slice();
        ir.arch = scratch.arch.slice();
        return ir;
    }
}
