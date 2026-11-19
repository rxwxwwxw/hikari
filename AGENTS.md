# AGENTS.md — hikari

> **Status:** Normative project specification for the initial implementation. This file defines architecture, contracts, safety rules, and acceptance criteria. `ROADMAP.md` will define implementation phases and sequencing separately.

## 1. Mission and design priorities

Build **hikari**, a small, decentralized, cross-platform monitoring application for personal computers and servers connected through a **Tailscale tailnet**. It must run on **Linux, macOS, and Windows**; be written primarily in **D**, compiled with **LDC (`ldc2`)**; install and update safely; and provide an attractive, responsive, **on-demand HTTPS fleet dashboard**.

The dashboard must answer two questions:

1. **How are my machines doing?** Availability, freshness, CPU, memory, network, storage, processes, GPU, battery, and OS maintenance/reboot state.
2. **What hardware is in each machine?** Human-readable CPU model and *usable instruction-set extensions*, motherboard/system model, firmware, RAM, GPUs, network adapters, storage devices, and other reliably discoverable hardware.

**Priorities, in order:**

1. **Do not break other services.** Never modify Tailscale or unrelated services. An existing Caddy may only be changed by the verified, reversible integration in §7.1 (one marked import line plus a hikari-owned site file); it is never restarted and is reloaded only on explicit request.
2. **Be quiet when nobody is looking:** no agent-initiated peer telemetry/discovery probes, high-frequency sampling, or polling loops while the dashboard is closed. Any exceptional update or certificate traffic must be documented and configurable.
3. **Be correct and honest:** distinguish missing, unsupported, stale, failed, and zero-valued measurements. Do not invent hardware details.
4. **Be secure and recoverable:** tailnet-only transport, least privilege, signed releases, transactional updates, and safe rollback.
5. **Be pleasant to use:** fast fleet overview, useful hardware cards, sensible grouping, clear labels, and graceful offline states.
6. **Be portable and easy to deploy:** native OS APIs, minimal dependencies, idempotent installers, and one D agent binary per target architecture.

### 1.1 Deployment model

Each participating machine ordinarily runs:

- **`hikari`**: one native D executable, with an idle loopback HTTP listener, an in-memory telemetry cache, a persistent hardware/known-node registry, and platform-specific collectors. It **does not periodically poll peers**.
- **An HTTPS front end**: either an existing Caddy that hikari joined under §7.1, or an isolated `hikari-caddy` instance. Either way, hikari's site serves the single-file dashboard and proxies versioned API requests to the local D listener, listens **only on the machine's Tailscale address**, and uses Caddy's native Tailscale certificate integration.
- **An optional maintenance policy**: release checks/updates are **deferred until dashboard activity by default**, or may be explicitly enabled on a schedule. Never silently enable periodic peer telemetry polling.

Each machine is independently useful. There is **no central coordinator, database, message broker, hosted service, or account required by hikari**. Any machine with the dashboard can show the fleet. Tailscale itself, Caddy, and the OS service manager are required infrastructure; “no D package dependencies” does **not** mean literally zero external software.

**Auto-deployable** means easy, safe *per-machine installation* and subsequent automatic software/configuration reconciliation. It does **not** imply unattended installation on arbitrary other machines merely because they are on the tailnet.

### 1.2 In scope / out of scope

**In scope:** on-demand cached telemetry, hardware inventory, named and categorized CPU ISA features, supported local device inventory, capability-based probes, processes and rate tracking, local Tailscale peer discovery and retained offline nodes, responsive dashboard, non-destructive installers, signed self-updates, service recovery, and cross-platform tests.

**Out of scope for the initial implementation:** historical time-series databases, central servers, push alerts, automatic remediation, remote shell execution, software or OS package installation, SMART self-tests, invasive hardware benchmarks, continuous packet capture, full PCI/vendor database downloads, mobile background agents, and an Internet-exposed dashboard.

---

## 2. Non-negotiable operating principles

1. **Request driven.** Opening the dashboard activates reads; closing/hiding it stops browser polling. A running agent or HTTPS listener is not permission to collect metrics continuously.
2. **Cache by probe group.** Return sufficiently fresh cached data without invoking OS probes. Re-sample only expired groups, except for an authorized explicit refresh. Never rebuild a static hardware inventory just to update CPU utilization.
3. **Stale is better than blocking, within limits.** Return a labeled, reasonably recent snapshot while an expired group refreshes. Never present old or failed values as newly measured. An empty/cold cache may respond `202 collecting` until ready.
4. **Single flight and bounded work.** One in-flight collection per probe group; parallel requests share that work. Apply deadlines, concurrency limits, cancellation where safe, and backoff on repeated failures.
5. **No unnecessary disk writes.** Keep live telemetry in memory. Persist only configuration, known-node registry, hardware inventory, verified update metadata, and operational state when they actually change.
6. **Never block live probes on slow dependencies.** Disk/network mounts, WMI/IOKit, GPU drivers, package tools, and GitHub requests run independently with explicit timeouts.
7. **No network calls from telemetry probes.** Package/version status must use locally available state unless an explicitly named maintenance operation is invoked.
8. **Preserve operator intent.** Config changes, installation reruns, auto-updates, and uninstalls must not erase aliases, custom ports, ignored devices, or other operator-owned settings.
9. **Least privilege.** Avoid running the telemetry service as root/Administrator; represent permission failures explicitly. Do not elevate within a probe.
10. **No silent global changes.** Never reconfigure unrelated firewalls, Tailscale policies, package sources, or existing services. The only permitted change to a system Caddy is the verified, recorded and reversible integration of §7.1, reported in the installer's plan before it happens.

---

## 3. Architecture and ownership

```text
Browser (visible dashboard only)
  |  HTTPS, peer-by-peer, bounded concurrency
  v
<peer MagicDNS FQDN>:9100  [isolated hikari-caddy, Tailscale-IP bind]
  |-- /                  -> self-contained static web/index.html
  `-- /api/v1/*          -> http://127.0.0.1:<private_port>/api/v1/*
                              |
                              v
                          hikari agent
                          |-- cache + refresh coordinator
                          |-- platform telemetry backends
                          |-- lazy hardware inventory
                          |-- persistent known-node registry
                          |-- on-demand Tailscale discovery
                          `-- trusted, transactional updater
```

**No public HTTP listener is permitted for the D agent.** Bind only `127.0.0.1` (optionally `::1` when deliberately configured) and ensure the chosen port belongs to hikari. The public-facing Caddy (isolated `hikari-caddy` or a joined existing Caddy) binds hikari's site only to a Tailscale interface address. If that address is unavailable, retry/reconcile without binding to all interfaces.

The **dashboard** makes peer requests only while visible, and **each peer** collects only what has become due. The node hosting the dashboard may do limited, on-demand discovery on behalf of its browser; this is not a central collector.

### 3.1 Module boundaries

- **Core:** cache, single-flight coordinator, rate trackers, typed model/schema, configuration, deadlines, serialization, and error handling. No `version(linux)` / `version(OSX)` / `version(Windows)` conditionals in general business logic.
- **Platform backends:** return typed raw facts and probe results, not HTML or JSON. OS-dependent APIs remain here.
- **Hardware catalog:** separate slowly changing inventory from frequently changing telemetry. Normalize names and CPU ISA capabilities without web lookups.
- **Tailnet:** local peer identity, endpoint registry, on-demand peer validation, and resilience to machine renames.
- **HTTPS boundary:** Caddy owns tailnet TLS and static files; D owns JSON APIs and their access policies.
- **Updates/install:** independently testable staging, verification, activation, health check, rollback, and configuration migration.

---

## 4. Collection and caching (authoritative behavior)

All TTLs are **per probe group**, measured using a **monotonic clock** for scheduling. JSON timestamps are wall-clock Unix seconds, used only for display and compatibility; wall-clock corrections must not create negative or enormous rates.

### 4.1 Default TTLs

| Group | Default fresh TTL | Normal contents | Notes |
|---|---:|---|---|
| `fast` | **10 s** | Aggregate CPU, RAM, swap/commit, network counters and rates, uptime | Inexpensive, sampled on requests only |
| `processes` | **20 s** | Top 5 CPU and top 5 memory processes | Enumerating all PIDs can be expensive |
| `device_dynamic` | **60 s** | GPU usage/temperature/VRAM, battery, active NIC link state | Skip unsupported device probes |
| `filesystems` | **120 s** | Mount usage and capacity | Bound and isolate queries that can hang |
| `tailnet` | **5 min** | Local Tailscale peer-list view | `tailscale status --json` or supported local API |
| `maintenance` | **12 h** | Cached OS, kernel and package/reboot drift | Local checks only; slow checks separate |
| `hardware` | **7 days** | Hardware inventory; CPU, board, firmware, NIC, RAM, disks | Persist safely; manual refresh available |

These are **defaults, not periodic timers**. There is **no unconditional 10-second wakeup**. A probe runs only after a request, an explicitly authorized one-shot operation, or an optional, separately configured maintenance job.

### 4.2 Cache state machine

Each group has: `uninitialized`, `fresh`, `stale`, `refreshing`, `error`, or `unsupported`. Retain the last successful data independently of the last error.

For a GET requiring group `G`:

1. **Fresh:** If the last successful sample age is `< G.ttl`, immediately return the cached sample; do not execute a collector.
2. **Expired but within allowable stale age:** Return cached data **immediately**, explicitly including `sampled_at`, `age_s`, and `refreshing: true` (if a refresh is scheduled). Start **one** nonblocking refresh; concurrent requests coalesce.
3. **Uninitialized or too old:** Start collection of **all groups needed by that endpoint whose TTLs are due** (not an unconditional hardware scan on a status request). Allow a short, configurable response wait (default **2 s**). If complete, return fresh data; otherwise return **HTTP `202`**, a `collecting` JSON result, and `Retry-After`. Do **not** claim that the node is offline.
4. **Collection failed:** Keep last successful data, mark it `error`/`stale`, and include a bounded retry delay. If no usable data remains, return a structured `503` error for the affected endpoint, not made-up zeros.

Default maximum stale ages: `fast: 60 s`, `processes: 2 min`, `device_dynamic: 10 min`, `filesystems: 20 min`, `tailnet: 1 h`, `maintenance: 7 days`, `hardware: 30 days`. Stale-age ceilings apply to **serving as a usable measurement**; older persisted hardware may still be shown in an explicitly marked **last-known inventory** section while a new scan runs. All limits are configurable.

**Important:** When a machine has not been contacted for days, the first `/status` request refreshes all **due status groups** rather than reusing arbitrarily old CPU values. `/hardware` is a separate lazy request, and its longer-lived cache is not discarded because dynamic metrics expired.

### 4.3 Rate and process semantics

- Backends provide **cumulative OS counters**, not rates; `CounterTracker!K` owns all delta math. Use monotonic sample time, guard wrap/resets, and suppress outlier spikes after suspend/resume.
- A process is keyed by **`(pid, process_start_identity)`**, not PID alone. Identify and discard reused PIDs; clean up exited process tracker entries.
- Network interfaces use stable OS interface identities when possible, not just a display name. Track counters separately for each interface and boot/session.
- The **first sample** cannot establish a rate. Return `null` for unknown rates. If the collector performs a short second sample, label the actual measurement interval; never substitute `0` for unknown.
- Aggregate CPU percentage is **0–100% across all processors**. Per-process CPU is **one logical CPU = 100%** (a multicore process can exceed 100%). Show which convention the UI uses.
- Bytes are stored as integer **bytes** and speeds as **bytes/second** (`rx_bytes_per_s`, `tx_bytes_per_s`). Format units in the browser; don't confuse `bps` (bits/s) and B/s.
- Physical and Tailscale NIC traffic can represent overlapping packets. Never add them as though they are independent volumes.
- Unix `load_1m` is a scheduler/load metric; an EMA of CPU use on Windows is **not** the same measure. Return `null` for unsupported load average, or a separately named CPU-average metric.

### 4.4 Resource policy

- Do not shell out from `fast`, `processes`, or `device_dynamic` collectors. A slow/maintenance command may be used only if read-only, bounded, local-state-only, and clearly documented.
- Do not instantiate heavy GPU libraries until the GPU group is first requested; unload or reuse resources safely. Unsupported means a capability is absent, not `0%` utilization.
- Use efficient top-K selection, avoid allocating complete per-process objects when unnecessary, and avoid reading executable command lines by default.
- Prefer no disk writes for frequent samples. Never persist a 10-second stream simply to feed the web UI.
- Dashboard hide, navigation, or close must abort outstanding browser requests and stop timers; **the agent must not interpret a missing heartbeat as a request to keep sampling**.
- Benchmark **idle wakeups, CPU, RSS, disk writes, and connections**, not only isolated probe wall time. Targets are soft, hardware-dependent budgets—not correctness claims such as universal `<1 ms` collection.

---

## 5. Canonical contracts and API

Use a **versioned HTTP API**: all JSON endpoints begin `/api/v1/`. The dashboard is self-contained and uses **relative URLs** against its configured base path. Endpoints are read-only unless an explicitly authenticated administrative route is enabled.

| Route | Purpose | Operation |
|---|---|---|
| `GET /api/v1/status` | Dynamic telemetry with per-group ages and errors | Read; refresh due groups lazily |
| `GET /api/v1/hardware` | Static/slow hardware inventory and capabilities | Read; refresh due hardware lazily |
| `GET /api/v1/nodes` | Known fleet inventory, local Tailscale candidates and discovery state | Read; local peer refresh + on-demand validation |
| `GET /api/v1/info` | Agent version, schema compatibility, endpoint configuration, health summary, optional last-cached hardware summary | Read; cheap; **never triggers collection** |
| Loopback-only `GET /healthz` | Health checks for supervisor/updater | No expensive probes |

`GET` operations must be bounded and safe to retry. Administrative actions (e.g., force a hardware scan, force an update, forget a node) are **local CLI first**. If later exposed to a web UI, use separate authenticated `POST` endpoints with explicit permissions and CSRF/origin protections; never hide administrative mutations behind a GET.

### 5.1 Dynamic status (`/api/v1/status`)

The following is an **illustrative contract**; numeric readings are examples, not implied platform support. All categories may include `{status, sampled_at, error}` metadata, and fields without measurements must be `null` rather than fabricated values.

```json
{
  "app": "hikari",
  "schema_version": 1,
  "agent_version": "0.1.0",
  "node_id": "hikari:installation-uuid",
  "host": "workstation-linux",
  "fqdn": "workstation-linux.tail1234.ts.net",
  "os": "linux",
  "arch": "x86_64",
  "server_ts": 1794945600,
  "boot_id": "platform-specific-boot-identity",
  "uptime_s": 432180,
  "hardware_summary": {"cpu": "AMD Ryzen 9 5900X", "ram_bytes": 68719476736, "system_model": null},
  "groups": {
    "fast": {"status": "fresh", "sampled_at": 1794945598, "age_s": 2, "refreshing": false},
    "processes": {"status": "stale", "sampled_at": 1794945560, "age_s": 40, "refreshing": true},
    "device_dynamic": {"status": "unsupported", "sampled_at": null, "age_s": null, "refreshing": false},
    "filesystems": {"status": "fresh", "sampled_at": 1794945540, "age_s": 60, "refreshing": false},
    "maintenance": {"status": "fresh", "sampled_at": 1794920000, "age_s": 25600, "refreshing": false}
  },
  "cpu": {"pct": 14.2, "load_1m": 1.35, "temp_c": null},
  "memory": {"used_bytes": 19756849562, "total_bytes": 68719476736, "pct": 28.8},
  "swap": {"used_bytes": 214748365, "total_bytes": 8589934592, "pct": 2.5},
  "network": [
    {"id": "ifindex:2", "name": "enp5s0", "kind": "physical", "rx_bytes": 98412049120, "tx_bytes": 14209182310, "rx_bytes_per_s": 124500, "tx_bytes_per_s": 18400}
  ],
  "mounts": [
    {"mount": "/", "source": "/dev/nvme0n1p2", "fs": "btrfs", "used_bytes": 225915279770, "total_bytes": 1000204886016, "pct": 22.6}
  ],
  "gpus": [],
  "batteries": [],
  "top_cpu": [{"pid": 4192, "start_id": "sampled-start-marker", "name": "example", "cpu_pct": 110.0, "rss_bytes": 3272089600}],
  "top_mem": [],
  "drift": {"running_kernel": "6.12.4", "installed_kernel": null, "reboot_required": true, "pending_updates": null, "package_cache_age_s": null}
}
```

**Rules:**

- Keep schema and agent versions separate. `schema_version` increments for incompatible representation changes; consumers ignore unknown fields and tolerate optional fields.
- `groups[*].status` is one of `uninitialized`, `fresh`, `stale`, `refreshing`, `error`, `unsupported`. A failed refresh may include both `last_success_at` and a bounded error code; errors must not leak private paths or credentials.
- `batteries` is **always an array** (zero or more); `gpus` is **always an array**. Distinguish absent hardware from unsupported enumeration via group/device capability status.
- `swap` is genuinely swap/pagefile usage where measured. **Windows commit charge is separate** (`commit` object), not mislabeled as swap because `ullTotalPageFile` is a commit limit.
- Process memory means a documented per-OS resident/working-set metric, not necessarily an identical interpretation across platforms. Preserve a `memory_kind` indicator if needed.
- Only include `cpu.temp_c` if the OS backend can support it accurately. No guessed temperatures.
- `hardware_summary` is an **optional, small copy of previously cached inventory** (CPU display name, RAM total and system model), never a reason to perform a hardware scan on `/status`. Expose the same last-cached summary through `/api/v1/info` without triggering a scan. A local dashboard host may retain it from a validated discovery/info response for offline display.
- Timestamp/age metadata is required for every group. Slow data must not appear fresh merely because the status envelope was recently returned.
- Cold start may use `202 {"app":"hikari","schema_version":1,"status":"collecting","retry_after_s":1}`. Always send appropriate `Cache-Control: no-store` on dynamic responses.

### 5.2 Hardware inventory (`/api/v1/hardware`)

**Hardware inventory is a first-class product feature**, not an unstructured appendix to status. Collect it lazily, cache for seven days by default, and persist sanitized last-known data so an offline machine can still be identified from the dashboard host's *previously observed* registry/summary. Fetch full hardware only when a machine's Hardware card is opened or intentionally preloaded.

Illustrative shape:

```json
{
  "app": "hikari",
  "schema_version": 1,
  "node_id": "hikari:installation-uuid",
  "collected_at": 1794945000,
  "collection": {"status": "fresh", "partial": false},
  "system": {
    "manufacturer": "Example Vendor",
    "model": "Example Workstation",
    "product_family": null,
    "form_factor": "desktop",
    "virtualization": null
  },
  "board": {"manufacturer": "Example Board Co.", "model": "X570 Example", "revision": null},
  "firmware": {"type": "UEFI", "vendor": "Example Firmware", "version": "1.0", "release_date": null},
  "cpu": {
    "display_name": "AMD Ryzen 9 5900X",
    "vendor": "AMD",
    "architecture": "x86_64",
    "microarchitecture": null,
    "sockets": 1,
    "physical_cores": 12,
    "logical_cores": 24,
    "performance_cores": null,
    "efficiency_cores": null,
    "cache_bytes": {"l1d": null, "l1i": null, "l2": null, "l3": null},
    "isa": {
      "hardware": ["sse2", "avx", "avx2", "aes", "bmi1", "bmi2"],
      "usable": ["sse2", "avx", "avx2", "aes", "bmi1", "bmi2"],
      "detection": "cpuid+os_state"
    }
  },
  "memory": {"total_bytes": 68719476736, "technology": null, "modules": [], "module_enumeration": "unavailable"},
  "network_adapters": [
    {"id": "pci:0000:05:00.0", "display_name": "Intel Ethernet Controller", "interface": "enp5s0", "kind": "ethernet", "bus": "pci", "driver": "igc", "vendor_id": "8086", "device_id": null, "link_speed_bps": null}
  ],
  "storage_devices": [
    {"id": "nvme:0", "display_name": "Example NVMe SSD", "bus": "nvme", "media_type": "ssd", "capacity_bytes": 1000204886016, "mounts": ["/"]}
  ],
  "graphics_adapters": [
    {"display_name": "NVIDIA GeForce RTX 3070", "vendor": "NVIDIA", "memory_total_bytes": 8589934592}
  ],
  "capabilities": {"board": "ok", "memory_modules": "unavailable", "network_adapters": "ok", "storage_devices": "ok", "isa": "ok"}
}
```

**Inventory requirements:**

- **System:** manufacturer, product/model, model identifier (especially Apple hardware), desktop/laptop/server/VM classification *when known*.
- **Motherboard/baseboard:** manufacturer, product/model, revision *when the OS exposes them*. On Macs, show the Mac model identifier even when a PC-style baseboard cannot be identified.
- **Firmware:** BIOS/UEFI vendor, version, and release date if safely available. Do not imply a firmware-update service exists.
- **CPU:** faithful marketing/model string, vendor, architecture, socket/package count, physical/logical cores, heterogeneous core classes if known, cache sizes where available, and **enumerated usable ISA extensions**.
- **Memory:** total size; optional DDR technology, speed, channels, slots, and per-DIMM sizes/models when the OS provides them without intrusive privileges. Never infer missing DIMM properties from aggregate RAM.
- **Network adapters:** friendly model (e.g. “Intel Ethernet Controller I225-V” when identifiable), interface name, kind (Ethernet/Wi-Fi/virtual/tailnet), driver, bus, vendor/device IDs, and optional current link speed. Keep virtual adapters distinguishable; allow hide/show in the UI.
- **Storage:** physical device model, media/bus (NVMe, SATA, USB, etc.), capacity, and relationship to mounted volumes **where reliably mappable**. Do not treat a logical filesystem as a physical disk. Do not wake spun-down disks merely to enumerate them.
- **Graphics:** GPU name/vendor and static video memory, separated from dynamic GPU usage; optional driver/version when available.
- **Other:** optional chassis/battery and network wireless capability details, but do not let these delay the core inventory.

**Privacy:** **Never collect or publish serial numbers, MAC addresses, public IPs, Tailscale authentication keys, unique disk identifiers, Windows product keys, or raw full device paths** by default. Operator-enabled private diagnostics must be a clearly separate, access-controlled option. Stable `node_id` is an application-generated installation ID (or a non-secret Tailscale node ID mapped locally), **not** a hardware serial. Sanitize OS strings before display and logging.

### 5.3 Friendly CPU extension presentation

ISA support is genuinely useful for deciding where to run code. The backend must report what is **usable by applications on that OS**, not merely what a processor model nominally supports.

- On **x86/x86-64**, use CPUID and required OS-managed extended-state checks (such as OSXSAVE/XCR0 for AVX-family instructions). Keep `hardware` and `usable` lists distinct where detection permits; never claim AVX-512 as a whole if only some subsets are enabled.
- On **Linux ARM**, prefer auxiliary-vector `HWCAP`/`HWCAP2` and supported kernel interfaces; on **macOS Apple Silicon**, use documented `sysctl` / `hw.optional.*` capabilities; on **Windows**, use supported processor feature and architecture APIs. Treat unavailable flags as unknown, not unsupported.
- Canonical extension identifiers are lowercase (`sse4_2`, `avx2`, `avx512f`, `aes`, `sha`, `bmi2`, `asimd`, `sve`, etc.). Keep a small version-controlled offline mapping to friendly labels, descriptions, and groups: **Vector/SIMD**, **Cryptography**, **Bit manipulation**, **Virtualization**, **Other**.
- The card shows a short human-friendly summary (e.g., **“12 cores / 24 threads · x86-64 · AVX2 · AES”**), expandable ISA chips with plain-English tooltips, and a searchable full feature list.
- Never derive an instruction feature from the CPU marketing name alone. Preserve unknown/partial detection explicitly. Do not perform CPU benchmarks or execute potentially unsupported instructions to test feature availability.

### 5.4 Known nodes (`/api/v1/nodes`)

`nodes.json` is a **persistent registry**, not a list of only currently online peers. It must survive restarts, upgrades, renames, and extended offline periods. A node remains visible until explicitly removed/hidden by the operator.

```json
{
  "schema_version": 1,
  "generated_at": 1794945600,
  "nodes": [
    {
      "node_id": "hikari:installation-uuid",
      "tailscale_node_id": null,
      "name": "workstation-linux",
      "alias": "Main workstation",
      "fqdn": "workstation-linux.tail1234.ts.net",
      "status_url": "https://workstation-linux.tail1234.ts.net:9100/api/v1/status",
      "hardware_url": "https://workstation-linux.tail1234.ts.net:9100/api/v1/hardware",
      "last_seen_ts": 1794945600,
      "last_success_ts": 1794945600,
      "last_known_hardware_summary": {"cpu": "AMD Ryzen 9 5900X", "ram_bytes": 68719476736},
      "hidden": false
    }
  ]
}
```

All `*_url` fields are **plain HTTPS URL strings**, never Markdown links. Values must be properly escaped and validated before use. An alias is user-owned; a machine rename never resets it. Store custom per-node ports and endpoint base paths instead of assuming all peers use 9100 or `/`.

---

## 6. Tailnet discovery, presence, and dashboard networking

### 6.1 Local peer discovery

- Use `tailscale status --json` (or an explicitly supported local API) to read `Self` and `Peer` metadata; trim trailing dots from `DNSName`. Handle absent/disabled MagicDNS, sleeping peers, empty peer lists, and restricted CLI permissions gracefully.
- Prefer a stable Tailscale node identity if available and cross-check it against hikari's own installation ID during a successful peer response. Names and FQDNs can change; do not equate a rename with a new machine.
- Refresh the **local Tailscale view on demand** and cache it for five minutes. Reading local status is **not** permission to probe peers.
- On dashboard activity or an explicit `nodes discover`, validate eligible candidates through the cheap `/api/v1/info` endpoint with bounded parallel HTTPS requests (default concurrency **4**; individual timeouts configurable). Validate TLS, expected FQDN, `app`, schema, and node identity; discovery alone must **not trigger a telemetry or hardware scan**. Never bypass certificate verification or fall back to plaintext.
- A candidate that fails validation is not automatically a hikari node. On a **successful** validated info response, save its identity, endpoint information, contact time, and optional previously cached `hardware_summary` to the local registry (write only on actual change). Previously confirmed nodes remain in the registry as unreachable/offline/stale, **not deleted after seven days**.
- Support explicit enrollment, aliases, exclusions, nondefault ports, alternate HTTPS base paths, and an isolated optional “scan candidates” action for larger tailnets.
- No peer probe runs because a 12-hour timer fired. Peer validation is initiated by viewing/discovering, and stops when canceled or its bounded work finishes.

### 6.2 Presence and freshness

The UI must keep these concepts separate:

- **Online:** a validated HTTPS response was obtained; current group samples may still be stale.
- **Unreachable:** current HTTPS attempt failed (timeout, ACL, DNS, or TLS); display last-known data where available.
- **Tailscale offline:** local Tailscale reports the peer offline; that is a hint, not proof that hikari was uninstalled.
- **Stale telemetry:** response succeeded but a probe group is old or failed.
- **Collecting:** endpoint is available but is preparing its first or expired sample (`202`).
- **Incompatible/unsupported:** app/schema mismatch or unsupported functionality.
- **Hidden/removed:** explicit operator state, not an automatic timeout.

Show `last seen`, `last successful telemetry`, and last sampled timestamps separately. Never equate HTTP request latency, data age, and Tailscale connection status.

### 6.3 Browser behavior

- On page load, fetch local `/api/v1/nodes`, render known hosts immediately, then request peer `/api/v1/status` endpoints with bounded concurrency and `Promise.allSettled`-style independent failure handling.
- Only poll while `document.visibilityState === 'visible'`; pause on hide and abort outstanding requests on hide/navigation/page close. Do not install a service worker or background sync mechanism.
- Default refresh interval **60 s** while visible, user-configurable and switchable off. Each successful response is still subject to the server's TTL; client refresh does not force an expensive probe.
- Fetch full `/api/v1/hardware` **only when a hardware drawer/card is opened** (or when explicitly requested); cache it in the page session. Persist only a minimal, sanitized last-known hardware **summary** in the node registry.
- If a node becomes unreachable, render cached information with an obvious offline/staleness label. No infinite spinner and no single peer that can delay the whole page.
- Show collection errors and unsupported capabilities without breaking the layout. Never assume every machine exposes temperature, GPU telemetry, battery health, or per-DIMM details.

---

## 7. HTTPS, CORS, identity, and coexistence

### 7.1 Coexisting with Caddy: verified integration or an isolated instance

Many machines already use Caddy, `tailscale serve`, and HTTPS on `:443`. The installer and updater **never modify** `tailscale serve` settings or Caddy service units, and never restart an existing Caddy. `caddy.mode` (`auto` by default, `integrate`, `isolated`, `snippet`) selects how hikari is served:

- **Integration (`auto`, `integrate`).** When an existing Caddy *service* runs a Caddyfile and every check passes, hikari appends exactly one marked block importing a hikari-owned site file, or drops that file into an existing top-level glob import, and changes nothing else. Requirements:
  - Parse the whole config, imports included, and **refuse anything uncertain**: parse errors, JSON or admin-API (`--resume`) configs, `{$ENV}` addresses, config-management headers, import cycles, port/host/`servers`/`http(s)_port` conflicts, brace-less site files, hand-edited or duplicated markers, foreign files at hikari's site path, Caddy older than 2.6.
  - Before writing, prove with `caddy adapt` that every original server and TLS policy is preserved. Only hikari's listener on `<tailscale-ip>:<port>` and policies that are provably equivalent may be added.
  - Edit by byte offset only (no re-serialization), write atomically, and keep a timestamped backup. Removal must restore the original bytes exactly. Re-verify after writing and roll back on any difference.
  - Reload only on explicit request (`--reload`/`-Reload`, or `caddy.reload`), restoring the original files if the reload fails.
  - Record what was done in hikari's state directory, so that repair, mode switches and uninstall reverse exactly that.
- **Isolated (`isolated`, and the fallback whenever integration is refused).** A dedicated `hikari-caddy`, configured as follows.

- Default dedicated service name: `hikari-caddy`; default external port: **9100**, configurable.
- Use a **separate Caddyfile**, storage directory, logs, runtime environment, and `admin off`. Disable automatic HTTP redirects to avoid port 80. Bind to the current **Tailscale address only**, never `0.0.0.0`, `:80`, or `:443` by default.
- Prefer an already installed, **compatible** Caddy binary in PATH without upgrading or changing its service; otherwise install an independently verified, pinned Caddy build under hikari's own binary directory.
- Validate configuration before starting; fail with an actionable port-conflict message rather than taking over an existing listener.
- MagicDNS and tailnet HTTPS certificates are prerequisites. Detect missing certificate permission for the dedicated service account and explain the required `tailscaled` configuration. **Do not silently restart `tailscaled`** or change its operator settings.
- Account for boot ordering, disconnected Tailscale, IP changes, sleep/resume, and certificate renewal. Do not bind a public fallback socket when Tailscale is unavailable.
- Tailscale certificate issuance may create externally visible certificate-transparency records for the MagicDNS name; document that privacy limitation.

Illustrative isolated config (render placeholders; test against the Caddy version actually shipped):

```caddyfile
{
    admin off
    auto_https disable_redirects
    storage file_system __STATE_DIR__/caddy
}

https://__MAGIC_DNS_FQDN__:__PORT__ {
    bind __TAILSCALE_IP__
    encode zstd gzip

    handle /api/v1/* {
        reverse_proxy 127.0.0.1:__LOCAL_PORT__
    }

    handle {
        root * __WEB_DIR__
        file_server
    }
}
```

### 7.2 Optional existing-Caddy snippet

`--snippet-only` **only writes** an importable snippet; it must not edit existing config or reload existing services. All routes are beneath a **single reserved prefix** such as `/hikari/`, including API routes, to avoid colliding with an existing site's `/status.json` or `/nodes.json`.

The built dashboard must support both root (`/`) and prefixed (`/hikari/`) deployments using relative paths. Test prefix stripping and route ordering with `caddy validate` and an integration request. Snippet inclusion and any reload remain a deliberate operator action.

### 7.3 Browser read security

- Access control is primarily **Tailscale policy + correctly bound HTTPS**, not CORS. Document an ACL/grant restricting access to the configured TCP port.
- **Never use `Access-Control-Allow-Origin: *`** for telemetry. Validate each requesting dashboard `Origin` against a configured allowlist or locally verified, same-tailnet dashboard origins; echo an authorized exact origin with `Vary: Origin`. Handle preflight requests deliberately.
- Reject unexpected `Host`/`Origin` combinations, cross-tailnet lookalikes, and untrusted endpoint URLs. Do not allow arbitrary proxy targets or browser-controlled SSRF endpoints.
- Cross-origin browser permissions protect browser reads; they are **not authentication**. If an administrative API is added, require real authorization, rate limiting, and CSRF defense in addition to origin checks.
- Use a restrictive CSP where compatible with the peer fetch design, avoid CDNs/external fonts, and always insert untrusted names as **text**, not `innerHTML`.
- Read-only JSON endpoints do not expose environment variables, full command lines, authentication tokens, or diagnostic files. Apply response-size and request-rate bounds.

---

## 8. Platform backend implementation guide

All platform modules implement a shared `PlatformBackend` interface. Keep the exact raw types extensible rather than baking unsupported OS assumptions into the API. Backend methods return values plus `ok`, `unsupported`, `unavailable`, `permission_denied`, or `error` state.

```d
interface PlatformBackend {
    PlatformIdentity identity();
    RawCpu sampleCpu();
    RawMemory sampleMemory();
    RawNetwork[] sampleNetwork();
    RawProcess[] sampleProcesses();
    RawFilesystem[] sampleFilesystems();
    RawGpu[] sampleGpus();
    RawBattery[] sampleBatteries();
    RawMaintenance sampleMaintenance();
    RawHardwareInventory scanHardware();
}
```

Names are conceptual; adjust D types as needed for safe allocation, ownership, and error propagation. Do not hard-code platform `version()` branches in the JSON serializer, dashboard, or scheduler.

### 8.1 Linux

- **Fast:** `/proc/stat`, `/proc/loadavg`, `/proc/meminfo`, `/proc/net/dev` or suitable sysfs data; monotonic boot/time information.
- **Processes:** `/proc/<pid>/stat` with correct parsing of names containing parentheses/spaces; `utime`/`stime`, start time, RSS pages, PID reuse, privilege failures and races. Never assume each PID survives between enumeration and read.
- **Mounts/storage:** `/proc/self/mountinfo`, `statvfs`, `/sys/block`, `/sys/class/nvme`, filesystem/device mapping where reliable. Deduplicate equivalent mounts without hiding meaningful Btrfs subvolumes or logical volumes; distinguish physical device capacity from filesystem capacity. Isolate potentially blocking network mounts.
- **GPU:** dynamic NVML for supported NVIDIA devices; documented DRM/sysfs metrics for AMD/Intel when available. Do not treat a GPU device's mere presence as evidence that utilization telemetry is supported.
- **Battery:** `/sys/class/power_supply`, including multiple batteries and `energy_*` / `charge_*` unit handling.
- **Inventory:** `/sys/class/dmi/id`, `/sys/bus/pci/devices`, network driver and device symlinks, CPU topology, `/proc/cpuinfo`/CPUID or auxiliary vectors, block-device metadata. Use optional **locally installed** PCI ID descriptions when available; never download a database during scanning.
- **Maintenance:** `uname`, installed kernel/package metadata and distribution-appropriate local cache checks. Never run `apt update`, `pacman -Sy`, or other network-hitting commands inside monitoring. A `checkupdates`/package simulation may be used only if locally read-only and timeout-safe; report unknown where a portable result is impossible.

### 8.2 macOS

- **Fast:** Mach `host_statistics`/`host_statistics64`, `getloadavg`, `sysctlbyname`, and `getifaddrs` counters with correct units and rollover handling.
- **Processes:** `libproc` (`proc_listallpids`, `proc_pidinfo`), process start identity, resident memory; tolerate protected processes.
- **Filesystem/storage:** `getfsstat`, Disk Arbitration/IOKit where useful; exclude unwanted APFS system volumes without suppressing meaningful data volumes.
- **Inventory:** `hw.model` / hardware model identifiers, suitable `sysctl` CPU topology/features, IORegistry/IOKit for display, NICs, GPUs, batteries, and supported board/system metadata. Apple Silicon and Intel Mac detection must be distinct; never assume a PC-style motherboard or a single fixed CPU clock is exposed.
- **GPU/battery:** IORegistry if documented/available; null or `unsupported` where useful utilization statistics cannot be obtained without private APIs.
- **Maintenance:** local Software Update metadata with a documented reliability warning; **do not run** `softwareupdate -l` in passive collection.

### 8.3 Windows

- **Fast:** `GetSystemTimes`, `GlobalMemoryStatusEx`, `GetIfTable2`, monotonic time and supported uptime APIs.
- **Processes:** Toolhelp enumeration, `GetProcessTimes`, bounded `OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, ...)`, `GetProcessMemoryInfo`, and creation-time identity. Close every handle.
- **Storage:** drive-volume APIs for filesystems; physical-disk/storage APIs and supported device properties for hardware inventory. Distinguish physical disks, logical volumes, and removable/network storage.
- **Inventory:** Windows SMBIOS/firmware APIs (e.g. `GetSystemFirmwareTable`), SetupAPI device descriptions and PCI IDs, supported CPU topology/feature APIs, and carefully bounded WMI/CIM only where native APIs are insufficient. No recurring `wmic` or PowerShell subprocesses in fast probes.
- **GPU/battery:** dynamic NVML when present and documented Windows power/battery APIs, with capability/error states.
- **Maintenance:** current OS build/update reboot flags from reliable registry/API sources; unknown pending-update count is preferable to a misleading `0`.
- **Memory:** Windows commit charge/pagefile data is **not Unix swap**; use a distinct `commit` contract and report actual pagefile use only if measurable.

### 8.4 Normalization and safety

- Normalize CPU feature names and hardware classes centrally. Preserve original OS-provided strings for display, escaped and length-limited.
- Use meaningful fallbacks: vendor/device ID, driver, or device class if a marketing name cannot be found. Avoid guessing exact NIC or board models from partial IDs.
- Support x86-64 and ARM64 where the OS/release matrix permits. A missing platform capability is not an installation failure.
- Avoid blocking probe threads on GPU driver crashes, inaccessible removable drives, unresponsive SMB shares, or WMI hangs. Use worker isolation and time budgets where necessary.

---

## 9. Dashboard UX requirements

Use a **self-contained HTML/CSS/vanilla JavaScript file**, no external CDNs, fonts, frontend build system, analytics, service worker, or persistent browser background task.

### 9.1 Fleet overview (default landing screen)

- Summary: **online / known**, unreachable/offline, stale, reboot required, and pending updates **when the metric is known**.
- Responsive dense table/cards: friendly alias, host, OS, CPU and RAM usage bars, disk pressure, top network activity, GPU (when relevant), battery, last contact, and clear health indicators.
- Search, filter, and sort by hostname/alias, operating system, CPU/RAM/disk utilization, last seen, and warning severity.
- Preserve offline/sleeping machines and display their last-known values only with an obvious **last measured** timestamp.
- Per-peer latency, timeout, error, and collection-in-progress states are distinct; the page never waits for the slowest host to render.

### 9.2 Machine detail and hardware cards

Each machine opens an organized detail view with **Overview**, **Hardware**, **Storage/Network**, and **Processes/Maintenance** sections. Hardware should be memorable and useful at a glance:

- **CPU card:** human-readable exact model, vendor, physical cores/threads, architecture, optional heterogeneous core layout/cache, summary ISA badges, expandable feature list with explanatory tooltips and hardware-versus-usable distinction.
- **Motherboard & firmware card:** system/board manufacturer and model, BIOS/UEFI version, Mac model identifier when applicable; clearly mark unavailable details.
- **Memory card:** total RAM, technology and speed if available, optional per-slot/module details, plus current usage from a separate dynamic data group.
- **GPU card(s):** make/model/VRAM and optional live utilization, temperature and driver; unknown metrics must not become zeroes.
- **Network adapters card(s):** friendly NIC model, Ethernet/Wi-Fi/virtual category, driver, bus, interface/link speed where known; visually distinguish tailnet adapter from the physical NIC.
- **Storage devices card(s):** physical device model, interface (NVMe/SATA/USB), SSD/HDD/unknown, capacity, related mounted volumes, and separate filesystem usage bars.
- **Battery and maintenance:** only when applicable; clear, non-alarmist interpretation of missing/unknown data.

Use human-friendly formatting (`GiB`, `MiB/s`, concise CPU ISA names), accessible contrast, keyboard navigation, tooltips with definitions, responsive layouts at roughly **1300×768** and mobile widths, and no unnecessary animation. Keep the cards readable rather than presenting a raw `lshw` or Device Manager dump.

### 9.3 Privacy and rendering

A dashboard visitor may be able to read sensitive machine metadata. Keep access limited to trusted tailnet members, make private fields opt-in, and ensure all strings are safely escaped. No telemetry is sent to third parties by the frontend.

---

## 10. Configuration and filesystem layout

Configuration is **persistent and operator-owned**. Separate binaries/assets, generated Caddy config, trusted update metadata, persistent state, and ephemeral telemetry. Do not treat `/tmp` on macOS or `C:\Windows\Temp` as guaranteed RAM disks; in-memory caching eliminates the need for an always-rewritten `status.json`.

| Purpose | Linux | macOS | Windows |
|---|---|---|---|
| App binaries/releases | `/opt/hikari/versions/` | `/opt/hikari/versions/` | `C:\ProgramData\hikari\versions\` |
| Web assets | Within versioned release | Within versioned release | Within versioned release |
| Config | `/etc/hikari/` | `/Library/Application Support/hikari/` | `C:\ProgramData\hikari\config\` |
| State/cache | `/var/lib/hikari/` | `/Library/Application Support/hikari/state/` | `C:\ProgramData\hikari\state\` |
| Dedicated Caddy storage | Under state dir | Under state dir | Under state dir |

State persists across updates and reinstall unless the operator explicitly requests a full purge. Use restricted filesystem permissions; do not put tokens or credentials in JSON exposed by Caddy.

Illustrative `config.json` (config file schema to be tested and versioned):

```json
{
  "schema_version": 1,
  "listen": {"tailnet_port": 9100, "loopback_port": 19100, "base_path": "/"},
  "collection": {
    "ttl_seconds": {"fast": 10, "processes": 20, "device_dynamic": 60, "filesystems": 120, "tailnet": 300, "maintenance": 43200, "hardware": 604800},
    "max_stale_seconds": {"fast": 60, "processes": 120, "device_dynamic": 600, "filesystems": 1200, "tailnet": 3600, "maintenance": 604800, "hardware": 2592000}
  },
  "discovery": {"enabled_on_dashboard_open": true, "max_concurrent_probes": 4},
  "updates": {"repo": "OWNER/REPO", "mode": "on_dashboard_open", "auto_install_verified": true, "check_interval_hours": 24},
  "privacy": {"expose_serials": false, "expose_mac_addresses": false}
}
```

`OWNER/REPO` is a placeholder, **not a usable default**. First installation must choose/pin the trusted repository and update signing key; updates stay disabled until that trust configuration is valid. Configuration migrations must be reversible or gracefully backwards compatible; keep unknown operator keys where reasonable.

### 10.1 CLI

Provide clear, scriptable subcommands:

```text
hikari serve --config <path>                 # loopback agent + on-demand cache
hikari snapshot --out <path|->               # one-shot status; rates null unless sampled twice
hikari hardware --out <path|-> [--refresh]   # hardware inventory
hikari nodes list|discover                   # local/explicit peer discovery
hikari update check|apply|rollback           # signed release lifecycle
hikari doctor                               # preflight checks, safe diagnostics
hikari version                              # agent + schema versions
```

`doctor` should check tailnet connectivity/identity, MagicDNS/HTTPS prerequisites, certificate permission, port conflicts, service state, local API health, Caddy validity, and update trust. It must not silently change the host. Old flag aliases (e.g. `--once`, `--daemon`) are optional before v1; if shipped, maintain them consistently.

---

## 11. Updater and maintenance network policy

### 11.1 Network-quiet default

**Default `updates.mode = on_dashboard_open`:** no autonomous GitHub checks when all dashboards are closed. When a dashboard becomes active, the agent may check a verified upstream release **if its cached check is due**. Apply randomized jitter so multiple nodes do not all hit GitHub at once. Update work is asynchronous, never blocks telemetry requests, and must not restart the agent mid-response.

Other explicit modes:

- `manual`: never contact GitHub or install an update unless the operator invokes a CLI update.
- `scheduled`: check at a configurable bounded interval (default 24 h, with jitter) even without a dashboard. This mode **intentionally sacrifices strict network quietness** for unattended freshness.

**Tradeoff:** `on_dashboard_open` cannot install updates on a computer that is never contacted. Document this honestly. “No idle connections” refers to **hikari-initiated connections**; the Tailscale daemon, OS updates, and certificate handling have separate network behavior outside hikari's complete control.

### 11.2 Signed, transactional release updates

Use GitHub Releases from a **pinned repository** with a trusted signing key distributed **independently of downloaded artifacts** (or an equivalently verified signature identity and policy). TLS and an unsigned SHA-256 file from the same release are not sufficient to establish authenticity.

1. Check version with semantic version parsing (not lexicographic comparison). Respect permitted channels, pinned versions, and no unexpected downgrade.
2. Download exact platform/arch archive and signed manifest to a staging area with size limits, deadlines and retries. Verify manifest signature and all file hashes **before extraction or execution**. Prevent path traversal and symlink extraction attacks.
3. Acquire a cross-process update lock; reject overlapping installer/maintenance jobs. Verify enough disk space and clean incomplete staging safely.
4. Extract into a **new version directory**. Validate embedded config/schema compatibility and Caddy config in an isolated test invocation.
5. Activate through an **OS-specific atomic pointer/service switch** and restart **only** hikari-owned services. On Windows, `hikari.exe` is itself a native Service Control Manager service (no wrapper binary) and activation swaps the versioned junction, then restarts the services through the SCM API; **never overwrite a running `.exe`**.
6. Probe local `/healthz`, confirm expected version, and require bounded successful startup. On failure, switch back to the previous complete version and preserve useful diagnostics.
7. Preserve the last known-good release, state, config, hardware cache, user aliases, and the local Caddy certificate store. Garbage-collect older verified releases later, never during the critical activation step.

**Fail closed** on missing/invalid signatures or unexpected manifest contents. Never silently install an unsigned update or rewrite trust configuration. Updating a privately managed Caddy binary is a distinct operation and cannot alter a system Caddy installation.

### 11.3 Reconfiguration

Regenerate only **hikari-owned generated files** when a release template or relevant local settings change. Back up the prior generated config, validate before activation, compare against the active config, and reload/restart only `hikari-caddy` if actually necessary. Do not import user changes into an existing Caddy installation automatically.

---

## 12. Installers, service managers, and release matrix

### 12.1 Installation guarantees

- Idempotent and non-destructive. Support fresh install, repeat install, reconfiguration, service repair, upgrade, and uninstall.
- Preflight before changing anything: required Tailscale binaries/permissions, HTTPS certificate support, download verification, ports, compatible Caddy, filesystem permissions, and service manager availability.
- Install the chosen platform binary, self-contained web assets, generated dedicated Caddy config, and isolated service definitions. Avoid introducing a permanent high-privilege helper.
- Run the telemetry agent as a restricted account where feasible. Document unavoidable local permissions and explain opt-in richer hardware enumeration.
- If a port is occupied, fail or request a different port. Never kill/reconfigure an unrelated listener.
- Uninstall removes **only hikari-owned** services/files and reverses any §7.1 Caddy integration byte for byte (refusing to proceed if it cannot). Keep config/state by default; require an explicit `--purge` to delete user-owned state. Never uninstall Tailscale or an existing shared Caddy binary.
- On reboot, start safely when Tailscale is absent and reconcile its eventual readiness without a busy loop. On sleep/resume, clear invalid rate baselines and recover listeners/certificates as needed.

### 12.2 Per-platform service strategy

- **Linux:** POSIX shell installer; `systemd` service and hardening options. Do not assume every distribution has the same package manager or Linux directory conventions.
- **macOS:** shell installer; `launchd` service using documented paths and appropriate account permissions. Support native arm64 and x86-64 builds.
- **Windows:** PowerShell installer; native SCM services for the D executable (`hikari serve --service`) and the dedicated Caddy instance (Caddy's built-in service support), registered by `hikari service install`; per-service virtual account, minimal privileges and SCM recovery actions; verified helper downloads; startup dependencies/retries. Use version-specific executable paths and Windows-safe service activation. Support x86-64; arm64 is a later capability unless a release is shipped and tested.
- **Snippet-only:** generate files and instructions, no service or user Caddy changes unless explicitly requested and safe.

### 12.3 Release artifacts

Build using LDC with native CI runners for at least:

```text
linux-x86_64     linux-aarch64
darwin-x86_64    darwin-arm64
windows-x86_64
```

Use stable, signed filenames such as `hikari-<os>-<arch>.tar.gz` (`.zip` on Windows), each with `hikari`, web assets, Caddy template(s), schema metadata, and installer compatibility information. Include a signed release manifest. Maintain and test `VERSION` against `v*` tags.

---

## 13. Required repository organization

The initial layout is a guideline, not a reason to avoid necessary refactoring. Keep platform-specific code isolated and schema/test fixtures easy to locate.

```text
hikari/
├── AGENTS.md
├── ROADMAP.md                    # to be written separately
├── README.md
├── VERSION
├── dub.sdl
├── src/
│   ├── main.d
│   ├── core/
│   │   ├── config.d
│   │   ├── model.d
│   │   ├── cache.d             # per-group TTLs + stale-while-refresh
│   │   ├── coordinator.d       # single-flight, deadlines, cancellation
│   │   ├── tracker.d           # monotonic rate tracking
│   │   └── serializer.d
│   ├── http/
│   │   ├── server.d           # loopback only
│   │   ├── routes.d
│   │   └── security.d
│   ├── hardware/
│   │   ├── inventory.d
│   │   └── isa_names.d        # offline feature aliases/descriptions
│   ├── platform/
│   │   ├── api.d
│   │   ├── linux.d
│   │   ├── darwin.d
│   │   ├── windows.d
│   │   └── nvml.d
│   ├── tailnet/
│   │   ├── discovery.d
│   │   └── registry.d
│   └── update/
│       ├── verify.d
│       ├── stage.d
│       └── activate.d
├── caddy/
│   ├── Caddyfile.tmpl
│   └── snippet.caddy.tmpl
├── web/
│   └── index.html
├── install/
│   ├── install.sh
│   ├── uninstall.sh
│   ├── install.ps1
│   └── uninstall.ps1
├── tests/
│   ├── fixtures/             # JSON contracts and fake platform data
│   ├── core/
│   ├── platform/
│   ├── http/
│   ├── install/
│   └── update/
└── .github/workflows/
    ├── ci.yml
    └── release.yml
```

---

## 14. Acceptance criteria and verification

No feature is complete merely because it compiles or returns plausible JSON. Add tests for the contract and for resource restraint.

### 14.1 Functional tests

- `dub build --compiler=ldc2`, release build, `dub test --compiler=ldc2`, and a JSON-valid one-shot snapshot on a supported host.
- Deterministic tracker tests: first sample unknown rate, counter reset, wrap, sub-50ms interval, monotonic clock discontinuity, suspend/resume, PID reuse, exited PIDs, reused interface names.
- Cache tests: fresh hit **does not invoke a probe**; TTL expiry does; multiple concurrent callers execute **one refresh**; stale response is labeled; over-age and failure paths obey `202`/`503` contracts.
- Hardware fixture tests: CPU extension normalization/OS usability, optional motherboard, multiple network adapters, multiple GPUs/batteries, unsupported RAM module enumeration, physical/logical storage separation, privacy redaction.
- JSON contract tests: schema version, nullable measurements, valid URLs, group timestamps, conversion boundaries, and cross-version unknown fields.
- Tailnet tests: rename, offline for 30+ days, custom port/base path, no MagicDNS, unrelated HTTPS service, unreachable peers, and TLS validation failure.
- Browser tests: mixed online/offline/collecting nodes, no polling when hidden, per-host timeout isolation, prefixed URL handling, hostile strings escaped, and hardware-on-demand behavior.
- Installer tests: idempotence; an existing Caddy untouched in isolated mode and changed only by the marked block when joined; join/repair/mode-switch/uninstall round trips restore the Caddyfile byte for byte; refused integrations fall back or fail before writing; unrelated port occupied; no Tailscale at boot; reinstall preserves state; uninstall only removes hikari assets.
- Caddyfile tests: a fixture corpus parsed by hikari and replayed against a real Caddy (listener agreement, rejection agreement, verified integrate/unintegrate round trips).
- Update tests: bad signature, malicious archive entries, interrupted download, lock contention, failed startup, Windows running binary, rollback, and preservation of user config.

### 14.2 Performance and network quietness

Measure on representative Linux, macOS (Intel and Apple Silicon where available), and Windows hosts:

- With **no dashboard open** and default quiet update policy, hikari initiates **no peer HTTP discovery/status traffic** and performs **no periodic high-frequency probes**. Record any allowed maintenance/certificate exceptions.
- Two status requests within a group's TTL do **not** cause two OS collections. Repeated hardware-card opens within the seven-day TTL do not re-enumerate hardware.
- Idle wakeups, CPU use, RSS, disk writes and sockets are measured over a meaningful interval; document results and regressions rather than declaring universal hard millisecond budgets.
- On a fleet containing sleeping/offline machines, the responsive dashboard renders reachable results independently and remains interactive within its own bounded request timeouts.
- Simulated slow mount/GPU/WMI/package checks cannot indefinitely stall the fast status path or other machines.

### 14.3 CI and operator checks

- Native CI builds and unit tests on Linux, macOS and Windows; artifact/signature manifest verification before publishing.
- `caddy validate` for generated isolated and snippet configs; basic HTTPS/local reverse-proxy integration tests where runners permit.
- `shellcheck` for shell installers if available, PowerShell lint/syntax checks, and clean install/uninstall smoke tests where practical.
- `hikari doctor` reports actionable prerequisites and conflicts **without modifying any external service**.
- Keep tests deterministic with faked OS backends and local HTTP fixtures. Tests must not depend on the user's actual tailnet, GitHub availability, or privileged hardware access.

---

## 15. Explicit prohibitions

**Never:**

- Poll peers or execute high-frequency telemetry probes on a background timer by default.
- Advertise a stale/unsupported/failed measurement as a fresh zero.
- Bind telemetry or Caddy publicly, use insecure HTTP for tailnet peer status, disable TLS certificate verification, or expose administrative actions without authorization.
- Modify Tailscale services/settings, or restart, overwrite or uninstall a pre-existing Caddy. The only permitted change to an existing Caddy is the verified, recorded, reversible integration of §7.1, reloaded only on request.
- Download PCI names, drivers, packages, models, or OS updates in telemetry collection.
- Collect default hardware serials, MAC addresses, auth tokens, full process command lines, or other unnecessary private identifiers.
- Replace a running Windows executable, execute an unsigned update, silently migrate trust roots, or skip rollback protections.
- Discard offline nodes merely because they have not been reachable for a week.
- Add a central collector, external frontend dependency, telemetry SaaS, or background browser service worker without explicit approval.
- Let an agent-generated file edit an existing application's routes or configuration, other than the documented, verified Caddy integration of §7.1.
- Assume a feature exists because a CPU model, driver name, OS version, or JSON property suggests it might.

## 16. Authoritative references for integrations

Confirm installed-version details against official documentation during implementation; vendor APIs and permissions may change:

- [Caddy automatic HTTPS](https://caddyserver.com/docs/automatic-https)
- [Caddy Caddyfile reference](https://caddyserver.com/docs/caddyfile)
- [Tailscale: Caddy certificates](https://tailscale.com/docs/integrations/web-servers/caddy/caddy-certificates)
- [Tailscale: HTTPS certificates](https://tailscale.com/docs/how-to/set-up-https-certificates)
- [Tailscale CLI](https://tailscale.com/docs/reference/tailscale-cli)
- [Apple: addressing macOS architectural differences](https://developer.apple.com/documentation/Apple-Silicon/addressing-architectural-differences-in-your-macos-code)
- [Microsoft: hardware configuration APIs](https://learn.microsoft.com/en-us/windows/win32/sysinfo/hardware-configuration)

**Implementation sequencing, release milestones, and increasing ease of installation belong in `ROADMAP.md` and are intentionally not prescribed here.**
