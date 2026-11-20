module core.limits;

/// Compile-time fleet and telemetry capacity limits.
/// Override MAX_FLEET_NODES via `-d-version=HikariMaxNodes64`,
/// `-d-version=HikariMaxNodes256`, or `-d-version=HikariMaxNodes512`,
/// or edit the defaults directly.
version (HikariMaxNodes512) {
    enum size_t MAX_FLEET_NODES = 512;
} else version (HikariMaxNodes256) {
    enum size_t MAX_FLEET_NODES = 256;
} else version (HikariMaxNodes64) {
    enum size_t MAX_FLEET_NODES = 64;
} else {
    enum size_t MAX_FLEET_NODES = 128;
}

enum size_t MAX_NETWORK_INTERFACES = 64;
enum size_t MAX_FILESYSTEM_MOUNTS = 64;
enum size_t MAX_GPUS = 8;
enum size_t MAX_BATTERIES = 4;
enum size_t MAX_TOP_PROCESSES = 5;
enum size_t MAX_TRACKED_PROCESSES = 4096;

/// Power-of-two open-addressing hash table capacities (<= 50% load factor).
enum size_t NET_TRACKER_SLOTS = MAX_NETWORK_INTERFACES * 2;
enum size_t PROC_TRACKER_SLOTS = MAX_TRACKED_PROCESSES * 2;

enum uint DEFAULT_HTTP_WORKERS = 4;
enum uint MAX_HTTP_WORKERS = 32;
enum size_t HTTP_RESPONSE_BUF_SIZE = 128 * 1024;
