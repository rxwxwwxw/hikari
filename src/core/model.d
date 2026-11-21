module core.model;

import std.typecons : Nullable;

enum int SCHEMA_VERSION = 1;
enum string AGENT_VERSION = "0.1.8";

enum ProbeGroup : string {
    fast = "fast",
    processes = "processes",
    device_dynamic = "device_dynamic",
    filesystems = "filesystems",
    tailnet = "tailnet",
    maintenance = "maintenance",
    hardware = "hardware",
}

static immutable ProbeGroup[5] STATUS_PROBE_GROUPS = [
    ProbeGroup.fast,
    ProbeGroup.processes,
    ProbeGroup.device_dynamic,
    ProbeGroup.filesystems,
    ProbeGroup.maintenance,
];

enum GroupStatus : string {
    uninitialized = "uninitialized",
    fresh = "fresh",
    stale = "stale",
    refreshing = "refreshing",
    error = "error",
    unsupported = "unsupported",
}

enum CapabilityState : string {
    ok = "ok",
    unsupported = "unsupported",
    unavailable = "unavailable",
    permission_denied = "permission_denied",
    error = "error",
}

struct GroupMeta {
    GroupStatus status = GroupStatus.uninitialized;
    Nullable!long sampled_at;
    Nullable!long age_s;
    bool refreshing = false;
    Nullable!long last_success_at;
    string error;
}

struct HardwareSummary {
    string cpu;
    Nullable!ulong ram_bytes;
    string system_model;
}

struct CpuStatus {
    Nullable!double pct;
    Nullable!double load_1m;
    Nullable!double temp_c;
}

struct MemoryStatus {
    Nullable!ulong used_bytes;
    Nullable!ulong total_bytes;
    Nullable!double pct;
}

struct SwapStatus {
    Nullable!ulong used_bytes;
    Nullable!ulong total_bytes;
    Nullable!double pct;
}

struct CommitStatus {
    Nullable!ulong used_bytes;
    Nullable!ulong limit_bytes;
    Nullable!double pct;
}

struct NetworkInterfaceStatus {
    string id;
    string name;
    string kind; // physical, wireless, tailnet, virtual, loopback, unknown
    Nullable!ulong rx_bytes;
    Nullable!ulong tx_bytes;
    Nullable!double rx_bytes_per_s;
    Nullable!double tx_bytes_per_s;
    Nullable!bool link_up;
    Nullable!ulong link_speed_bps;
}

struct MountStatus {
    string mount;
    string source;
    string fs;
    Nullable!ulong used_bytes;
    Nullable!ulong total_bytes;
    Nullable!double pct;
}

struct GpuDynamicStatus {
    string id;
    string display_name;
    string vendor;
    Nullable!double utilization_pct;
    Nullable!double temp_c;
    Nullable!ulong vram_used_bytes;
    Nullable!ulong vram_total_bytes;
    Nullable!double power_watts;
    CapabilityState capability = CapabilityState.ok;
    string error;
}

struct BatteryStatus {
    string id;
    string name;
    string status; // charging, discharging, full, not_charging, unknown
    Nullable!double pct;
    Nullable!double power_watts;
    Nullable!long time_remaining_s;
    // Full-charge capacity as a percentage of design capacity. May exceed 100
    // on a new battery; null when either capacity is unknown or only relative.
    Nullable!double health_pct;
    // Null when the battery or OS does not report it (Windows reports 0 for
    // "unsupported", so 0 is never published as a real count).
    Nullable!ulong cycle_count;
    Nullable!double design_capacity_wh;
    Nullable!double full_charge_capacity_wh;
}

struct ProcessStatus {
    uint pid;
    string start_id;
    string name;
    Nullable!double cpu_pct;
    Nullable!ulong rss_bytes;
    string memory_kind = "rss";
}

struct DriftStatus {
    string running_kernel;
    string installed_kernel;
    Nullable!bool reboot_required;
    Nullable!uint pending_updates;
    Nullable!long package_cache_age_s;
    string hikari_version;
    string caddy_version;
    string tailscale_version;
}

struct StatusResponse {
    string app = "hikari";
    int schema_version = SCHEMA_VERSION;
    string agent_version = AGENT_VERSION;
    string node_id;
    string host;
    string fqdn;
    string os;
    string arch;
    long server_ts;
    string boot_id;
    Nullable!long uptime_s;
    Nullable!HardwareSummary hardware_summary;
    GroupMeta[string] groups;
    bool use_fixed_groups = false;
    GroupMeta[5] fixed_groups;
    CpuStatus cpu;
    MemoryStatus memory;
    Nullable!SwapStatus swap;
    Nullable!CommitStatus commit;
    NetworkInterfaceStatus[] network;
    MountStatus[] mounts;
    GpuDynamicStatus[] gpus;
    BatteryStatus[] batteries;
    ProcessStatus[] top_cpu;
    ProcessStatus[] top_mem;
    DriftStatus drift;
}

struct HardwareCollectionMeta {
    GroupStatus status = GroupStatus.uninitialized;
    bool partial = false;
    Nullable!long age_s;
    bool refreshing = false;
    string error;
}

struct SystemHardwareInfo {
    string manufacturer;
    string model;
    string product_family;
    string form_factor;
    string virtualization;
}

struct BoardHardwareInfo {
    string manufacturer;
    string model;
    string revision;
}

struct FirmwareHardwareInfo {
    string type;
    string vendor;
    string version_str;
    string release_date;
}

struct CacheBytesInfo {
    Nullable!ulong l1d;
    Nullable!ulong l1i;
    Nullable!ulong l2;
    Nullable!ulong l3;
}

struct IsaInfo {
    string[] hardware;
    string[] usable;
    string detection = "unknown";
}

struct CpuHardwareInfo {
    string display_name;
    string vendor;
    string architecture;
    string microarchitecture;
    Nullable!uint sockets;
    Nullable!uint physical_cores;
    Nullable!uint logical_cores;
    Nullable!uint performance_cores;
    Nullable!uint efficiency_cores;
    CacheBytesInfo cache_bytes;
    IsaInfo isa;
}

struct MemoryModuleInfo {
    string slot;
    Nullable!ulong size_bytes;
    string technology;
    Nullable!uint speed_mt_s;
    string manufacturer;
    string part_number;
}

struct MemoryHardwareInfo {
    Nullable!ulong total_bytes;
    string technology;
    Nullable!uint speed_mt_s;
    MemoryModuleInfo[] modules;
    CapabilityState module_enumeration = CapabilityState.unavailable;
}

struct NetworkAdapterHardware {
    string id;
    string display_name;
    string interface_name;
    string kind;
    string bus;
    string driver;
    string vendor_id;
    string device_id;
    Nullable!ulong link_speed_bps;
    string mac_address; // only populated if privacy.expose_mac_addresses == true
}

struct StorageDeviceHardware {
    string id;
    string display_name;
    string bus;
    string media_type; // ssd, hdd, nvme, unknown
    Nullable!ulong capacity_bytes;
    string[] mounts;
}

struct GraphicsAdapterHardware {
    string id;
    string display_name;
    string vendor;
    string driver;
    string vendor_id;
    string device_id;
    Nullable!ulong memory_total_bytes;
}

struct HardwareInventory {
    string app = "hikari";
    int schema_version = SCHEMA_VERSION;
    string node_id;
    Nullable!long collected_at;
    HardwareCollectionMeta collection;
    SystemHardwareInfo system;
    BoardHardwareInfo board;
    FirmwareHardwareInfo firmware;
    CpuHardwareInfo cpu;
    MemoryHardwareInfo memory;
    NetworkAdapterHardware[] network_adapters;
    StorageDeviceHardware[] storage_devices;
    GraphicsAdapterHardware[] graphics_adapters;
    CapabilityState[string] capabilities;
}

struct NodeRecord {
    string node_id;
    string tailscale_node_id;
    string name;
    string alias_name;
    string fqdn;
    string status_url;
    string hardware_url;
    string info_url;
    ushort tailnet_port = 9100;
    string base_path = "/";
    string os;
    string arch;
    bool is_self = false;
    Nullable!bool tailscale_online;
    string discovery_state = "confirmed"; // confirmed, candidate, unreachable, incompatible
    Nullable!long last_seen_ts;
    Nullable!long last_success_ts;
    Nullable!HardwareSummary last_known_hardware_summary;
    bool hidden = false;
}

/// Background peer-validation state reported by GET /api/v1/nodes.
struct DiscoveryMeta {
    bool running = false;
    Nullable!long last_started_at;
    Nullable!long last_finished_at;
    /// Tailscale status read failed (stale or unavailable view of peers).
    bool tailscale_available = true;
}

struct NodesResponse {
    int schema_version = SCHEMA_VERSION;
    long generated_at;
    NodeRecord[] nodes;
    /// Set only on API responses; never persisted to nodes.json.
    Nullable!DiscoveryMeta discovery;
}

struct InfoResponse {
    string app = "hikari";
    int schema_version = SCHEMA_VERSION;
    string agent_version = AGENT_VERSION;
    string hikari_version = AGENT_VERSION;
    string caddy_version;
    string tailscale_version;
    string node_id;
    string host;
    string fqdn;
    string os;
    string arch;
    ushort tailnet_port = 9100;
    string base_path = "/";
    long server_ts;
    Nullable!long uptime_s;
    string health = "ok";
    Nullable!HardwareSummary hardware_summary;
}

struct HealthResponse {
    string app = "hikari";
    int schema_version = SCHEMA_VERSION;
    string agent_version = AGENT_VERSION;
    string status = "ok";
    string node_id;
    long server_ts;
}

struct CollectingResponse {
    string app = "hikari";
    int schema_version = SCHEMA_VERSION;
    string status = "collecting";
    uint retry_after_s = 1;
}

struct DoctorCheck {
    string name;
    string status; // pass, warn, fail, skip
    string summary;
    string remediation;
}

struct DoctorReport {
    string app = "hikari";
    int schema_version = SCHEMA_VERSION;
    string agent_version = AGENT_VERSION;
    string overall = "pass"; // pass, warn, fail
    DoctorCheck[] checks;
}

// Raw platform backend types

struct PlatformIdentity {
    string host;
    string os;
    string arch;
    string boot_id;
    Nullable!long uptime_s;
}

struct RawCpu {
    CapabilityState state = CapabilityState.ok;
    string error;
    ulong total_ticks;
    ulong idle_ticks;
    uint logical_cores = 1;
    Nullable!double load_1m;
    Nullable!double temp_c;
}

struct RawMemory {
    CapabilityState state = CapabilityState.ok;
    string error;
    Nullable!ulong total_bytes;
    Nullable!ulong used_bytes;
    Nullable!ulong swap_total_bytes;
    Nullable!ulong swap_used_bytes;
    Nullable!ulong commit_limit_bytes;
    Nullable!ulong commit_used_bytes;
}

struct RawNetworkInterface {
    string id;
    string name;
    string kind;
    ulong rx_bytes;
    ulong tx_bytes;
    Nullable!bool link_up;
    Nullable!ulong link_speed_bps;
}

struct RawNetworkResult {
    CapabilityState state = CapabilityState.ok;
    string error;
    RawNetworkInterface[] interfaces;
}

struct RawProcess {
    uint pid;
    string start_id;
    string name;
    ulong cpu_ticks;
    ulong rss_bytes;
    string memory_kind = "rss";
}

struct RawProcessResult {
    CapabilityState state = CapabilityState.ok;
    string error;
    ulong total_cpu_ticks;
    uint logical_cores = 1;
    RawProcess[] processes;
}

struct RawFilesystemResult {
    CapabilityState state = CapabilityState.ok;
    string error;
    MountStatus[] mounts;
}

struct RawGpuResult {
    CapabilityState state = CapabilityState.unsupported;
    string error;
    GpuDynamicStatus[] gpus;
}

struct RawBatteryResult {
    CapabilityState state = CapabilityState.ok;
    string error;
    BatteryStatus[] batteries;
}

struct RawMaintenanceResult {
    CapabilityState state = CapabilityState.ok;
    string error;
    DriftStatus drift;
}

struct RawHardwareResult {
    CapabilityState state = CapabilityState.ok;
    string error;
    HardwareInventory inventory;
}
