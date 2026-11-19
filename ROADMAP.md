# ROADMAP.md — hikari

> **Status:** Implementation plan. Read with [`AGENTS.md`](AGENTS.md), which remains authoritative for architecture, HTTP/JSON contracts, caching semantics, security boundaries, and platform API requirements. This roadmap controls **order, milestones, test gates, and deployment ergonomics**. Where a milestone uses an illustrative command or path, it is a **planned interface**, not a claim that it already exists.
>
> **Implementation order:** **Stage 1: Linux** (complete and deployable) → **Stage 2: Windows** (system-wide service and feature parity) → **Stage 3: macOS** (system-wide service and feature parity). No platform is considered finished just because it compiles.

## 0. Scope and success criteria

The goal is a useful, low-overhead personal tailnet monitor that can be installed once per machine and then managed safely, without a central server or per-user background process. The first supported environments are:

| Stage | Primary targets | Service owner | Installation prerequisites |
|---|---|---|---|
| **1 — Linux** | Fedora; CachyOS/Arch; Ubuntu-family (Ubuntu, Mint, Armbian); x86-64 and ARM64 where available | **systemd system service** | Tailscale already installed on real target; install Caddy if necessary |
| **2 — Windows** | Windows 11 x86-64 first; other supported Windows versions only after explicit testing | **Windows Service Control Manager**, native service support (no wrapper), not a login task | Tailscale already installed; bundled/private Caddy if missing |
| **3 — macOS** | Apple Silicon Macs on supported macOS releases; Intel macOS deferred | **system-domain launchd LaunchDaemons**, not LaunchAgents | Tailscale already installed; Homebrew installed; install Caddy if missing |

**Definition of platform parity:** From a browser on another tailnet device, a machine can be discovered, shown in the fleet dashboard, queried for truthful cached telemetry, inspected through readable hardware cards, and maintained by an installer/updater that survives reboot, restart, logout, disconnection, and interrupted updates. Unsupported *individual hardware metrics* are allowed if correctly labeled; missing **core lifecycle functionality** is not.

### 0.1 Non-negotiable assumptions and boundaries

- **Tailscale is preinstalled** on production target machines. hikari **never installs Tailscale**, enrolls a machine, changes tailnet ACLs, enables MagicDNS/HTTPS centrally, or rewrites Tailscale configuration without an explicitly separate operator action.
- **Caddy is optional before installation.**
  - **Existing Caddy service with a Caddyfile:** by default (`caddy.mode=auto`) hikari joins it under AGENTS.md §7.1. That means one marked import line plus a hikari-owned site file, verified with `caddy adapt`, backed up, byte-identically reversible, and reloaded only on request. Anything uncertain falls back to the isolated instance.
  - **Otherwise:** run an isolated `hikari-caddy`, reusing a compatible `caddy` executable read-only or arranging a **private hikari-owned Caddy binary** from a verified, pinned release. Optional distro/Homebrew package installation is a deliberate operator choice, because package hooks can alter system services.
  - Never start, stop or restart an unrelated system Caddy instance.
- **System-owned installation, not user login:** Linux, Windows, and macOS services must start at boot and remain available after the installing account signs out. No `systemctl --user`, Windows Startup folder/logon-only scheduled task, macOS Login Item, or `~/Library/LaunchAgents` dependency for core service availability.
- **Network-quiet by default:** listening on tailnet/loopback is permitted; sampling is request-driven, with per-group TTLs and accurate stale states. Peer requests start only from dashboard activity or explicit commands. Caddy/Tailscale/OS network behavior is outside the agent's blanket control and must be documented.
- **No public exposure:** the D HTTP listener remains loopback-only; hikari's Caddy site (isolated or joined) binds only to the node's Tailscale address. No insecure production fallback when the certificate, identity, or Tailscale interface is unavailable.
- **No cross-platform shortcuts:** platform-specific code belongs in `src/platform/`, lifecycle wrappers, or installers, never in shared schema/business logic.
- **Hardware inventory is part of the product:** boards, firmware, CPU extensions usable by the OS, memory, NICs, storage and GPUs should have friendly cards, with unmeasurable properties shown as unavailable rather than guessed.
- **Installer/update operations are non-destructive:** preserve user configuration, last-known nodes, aliases, certificate storage, and previous healthy version. Uninstall never removes Tailscale or an existing system Caddy.

### 0.2 Release philosophy

Each milestone should leave a runnable demonstrator and tests, even if it is not yet production-installable. **Do not declare a public production release** until the relevant platform's installer, TLS boundary, permissions, update recovery, and real-host gates pass.

Progression of ease of use:

1. Run a local binary and inspect JSON.
2. Open a local dashboard and exercise lazy collection.
3. Open the real tailnet HTTPS dashboard and inspect several machines.
4. Install/repair/uninstall with a predictable command.
5. Reinstall or update without losing settings; eventually verified self-update/rollback.

No later platform should require Linux-only CLI commands, hardcoded paths, or changes to an existing Caddy deployment.

---

## 1. Stage 1 — Linux, fully usable and thoroughly tested

**Goal:** Before beginning Windows implementation, hikari works end-to-end on representative Fedora, CachyOS/Arch, and Ubuntu-family hosts, including an ARM64 Ubuntu-family/Armbian target where available. The full dashboard, hardware inventory, service setup, Caddy isolation, signed updates, and uninstall/repair story are implemented on Linux.

### L0 — Repository skeleton, portable contracts, and deterministic test harness

**Deliver:**

- D/LDC2 project and working CLI (`version`, `doctor`, `snapshot`, `hardware`, `serve`, `nodes`, `update`), shared model types, versioned config and JSON schemas, and a stable fixture set.
- Interface boundaries for telemetry, hardware inventory, Tailscale discovery, service control, Caddy rendering, and update activation. Implement injectable fake backends for deterministic tests.
- Core security defaults: loopback-only HTTP, bounded request parsing and body sizes, safe file ownership/modes, no auth secrets in JSON or logs, no arbitrary filesystem serving from the D endpoint.
- CI for Linux x86-64 build/tests; a cross-compile or native ARM64 job if available; separate debug and release builds. Record glibc/runtime assumptions, supported architectures, and `VERSION`/schema compatibility.
- A developer mode which runs **without Tailscale** by using a fake local Tailscale-status fixture and local-only HTTP/API tests. This is **test injection**, not an unsafe production `--insecure` networking option.

**Pass when:** `dub build`, `dub test`, `hikari version`, `hikari snapshot`, and schema fixtures work on a clean Linux runner without an enrolled tailnet. Tests don't need live GitHub, Caddy, or hardware.

### L1 — Correct Linux telemetry with lazy caching

**Deliver:**

- `/api/v1/info`, `/api/v1/status`, and loopback `/healthz`; explicit status metadata (`fresh`, `stale`, `refreshing`, `uninitialized`, `unsupported`, `error`).
- Request-driven groups defined in `AGENTS.md`: fast, processes, device dynamics, filesystem, tailnet, maintenance, and hardware. Implement per-group monotonic TTL, maximum-stale limits, single-flight refresh, deadlines, failed-probe backoff, and `202 collecting`/`503` cold/error responses.
- Linux CPU, uptime/load, RAM/swap, network byte counters/rates, mount sizes, process CPU/RSS and stable process identities. Implement GPU and battery behind independently failing optional capabilities.
- `CounterTracker` tests for first sample, counter wrap/reset, PID reuse, suspend/resume, interface changes, and measured interval. Do not report an initial unknown rate as zero.
- Never run package-manager network operations or invoke shell programs in fast, process, or dynamic-device probes.

**Pass when:** many concurrent status requests result in at most one OS collection per expired group; repeated requests within TTL perform no additional probes; old values are visibly stale and never pass as new; failed mount/GPU probes cannot indefinitely delay CPU status. With no dashboard requests, there is **no scheduled high-frequency telemetry work**.

### L2 — First useful local dashboard

**Deliver:**

- Self-contained `web/index.html`, no CDN, build pipeline, background service worker, third-party telemetry, or external fonts.
- Clean single-host overview with CPU, RAM/swap, network activity, filesystems, process top-five, clear timestamps, group error indicators, and readable formatting.
- Responsive fleet/table structure from the beginning, even when only one local node exists. Use mocked peers for UI testing.
- Visibility-aware polling (default visible-page interval from `AGENTS.md`), request cancellation, independent host failures, bounded concurrency, keyboard accessibility, and safe DOM rendering of arbitrary OS text.

**Pass when:** a browser shows a compelling single-machine monitor using the loopback development fixture, never invents readings, survives `202`/`503` responses, and makes no fetch requests when the document is hidden. No hardware inventory scans occur merely because the overview is open.

### L3 — Linux hardware inventory and genuinely helpful hardware cards

**Deliver:**

- Lazy `/api/v1/hardware` endpoint, independent seven-day default TTL, persistent last-known inventory with collection age and partial/unavailable states.
- Human-friendly CPU vendor/model, sockets, physical/logical cores, cache sizes where measurable, `CPUID`/OSXSAVE/XCR0 checks on x86-64, `HWCAP`/`HWCAP2` on ARM64, and an offline glossary of usable SIMD/crypto/bit-manipulation extensions.
- Board/system/firmware metadata; memory total and DIMM details where permissions/API permit; GPU inventory separate from dynamic utilization; friendly network adapter names/drivers/PCI identifiers; storage device models/capacity/bus separate from logical mounts.
- Linux-native sources (`/proc`, `/sys`, DMI, sysfs PCI/block, kernel APIs), no web PCI database and no routine hardware serial/MAC collection. Safe fallbacks when DMI is root-only or board/driver metadata is missing.
- Detail view with cards: CPU & ISA, motherboard/firmware, RAM, GPUs, network adapters, physical storage. Preserve explicit `unknown` versus `unsupported` distinctions; short readable summary plus expandable technical data.

**Pass when:** hardware cards display useful information on at least one x86-64 desktop/server, one laptop if available, and an ARM64 target or fixture; opening status doesn't rescan hardware; stored inventory remains readable when its owner is offline; ARM/x86 extension names are not fabricated from CPU marketing strings.

### L4 — Real Tailscale/Caddy integration and fleet discovery

**Deliver:**

- Dedicated `hikari-caddy` runtime with isolated configuration, admin disabled, dedicated storage, HTTPS `.ts.net` hostname and Tailscale-address-only binding; proxy `/api/v1/*` to D loopback and serve dashboard assets.
- Safe Caddy config renderer, validator, and readiness checks. Handle Tailscale coming up late, changing address, and certificate permission failures through bounded retry/reconcile; never bind publicly to recover.
- On-demand `tailscale status --json` discovery with stable IDs, cheap `/api/v1/info` validation, operator-owned aliases, custom ports/base paths, retained offline machines, and separately measured online/telemetry freshness states.
- Multi-host dashboard with search/filter/sort, compact summaries, per-host cards, preserved last-known hardware summaries, and optional full hardware fetch on expansion.
- `hikari doctor` checks MagicDNS, Tailscale HTTPS/certificate access, Caddy version/capability, port collisions, permissions, proxying and schema compatibility. **Diagnose** external-service problems without silently modifying Tailscale configuration.
- A tested *snippet-only* export for operators who prefer to wire hikari into their Caddy by hand. The generated snippet must be self-consistent under a prefixed path; in this mode hikari does not edit or reload their Caddy instance.
- Verified integration into an existing Caddy (`hikari caddy inspect|integrate|unintegrate`, AGENTS.md §7.1), proven by a Caddyfile fixture corpus replayed against a real Caddy in CI.

**Pass when:** two or more real tailnet machines can serve valid HTTPS dashboards/status, discover one another, survive a sleeping/offline peer, and retain that peer indefinitely. A host already running Caddy or `tailscale serve` is demonstrably unaffected. Hostnames and port overrides work, and invalid peer TLS certificates are never accepted.

### L5 — Linux installer, Caddy provisioning, and Docker distribution matrix

**Deliver:**

- `install/install.sh` and `install/uninstall.sh` with documented modes such as `--dry-run`, install/reinstall, service repair, optional port/base-path settings, explicit snippet-only mode, and uninstall with optional `--purge`. Final flags must be consistent with `AGENTS.md` and documented in `README.md`.
- A safe bootstrap: inspect distro and architecture, detect needed elevation, confirm Tailscale prereqs, verify the downloaded hikari release, check Caddy executable compatibility, create dedicated dirs/accounts, render/validate generated Caddy config, and register **system-level** `hikari.service` and `hikari-caddy.service` with `systemd`.
- **Caddy when absent:** default to a **private verified, pinned Caddy executable** under a hikari-owned dependency directory. Do not assume that installing distro `caddy` packages is side-effect free. Provide an explicit, optional `--caddy-source=system-package` path where desired; use existing compatible Caddy binaries read-only. Never restart an existing `caddy.service`; join its Caddyfile only under AGENTS.md §7.1 (`--caddy-mode=auto|integrate|isolated|snippet`, `--reload`).
- `/etc/os-release` detection using `ID` and `ID_LIKE`, not only substring matching in `NAME`. Cover **Fedora/dnf**, **Arch/CachyOS/pacman**, **Ubuntu/Mint/Armbian/other Debian-family apt**. Avoid assuming all Arch or ARM hosts have identical kernels, package metadata, libraries or tools.
- Linux systemd system units with restart/backoff, startup after local services become available, hardening and a restricted service account subject to actual certificate/metric-access needs. Explicitly test Fedora SELinux behavior rather than disabling SELinux.
- Installation log and human-readable final report: service status, bound addresses, local health, tailnet dashboard URL, which Caddy executable is in use, whether certificate permissions work, and recovery instructions.
- Uninstall/reinstall must leave Tailscale, non-hikari ports, user data and other services intact, and must leave an existing Caddy either untouched (isolated mode) or restored byte for byte (after integration). State/config retained unless `--purge` is explicitly requested.

**Container test suite (must not require live Tailscale):**

| Container target | What it proves | What it does **not** prove |
|---|---|---|
| `fedora` | `dnf` detection; file layout; service template; Caddy decision; upgrade/uninstall paths | Host SELinux policy, real boot/Tailscale integration |
| `archlinux` | `pacman` detection; rolling-release assumptions; Arch/CachyOS branch selection via `os-release` fixtures | Actual CachyOS kernel, device drivers |
| `ubuntu` current LTS | `apt` branch; system dirs; installer prerequisites | Full Mint/Armbian hardware behavior |
| `debian` or `ubuntu` with `ID_LIKE` fixtures | Derivative fallback for Mint, Armbian, other Debian-family systems | Real derivative packaging/service quirks |
| ARM64 Ubuntu-family image, when runner supports it | ARM64 artifact path, architecture detection, CLI and basic API | Armbian-specific board firmware or boot conditions |

Implement `tests/integration/linux/` with Dockerfiles/Compose or a shell runner, fake Tailscale CLI output, local HTTP fixture peers, and a test-owned filesystem root/service-manager adapter. Exercise **dry-run, clean install, rerun, repair, Caddy present/absent, occupied port, fail-before-write, corrupted download, uninstall, and retained state**.

**Critical limitation:** Ordinary Docker containers usually do **not** have a real systemd PID 1, a real Tailscale identity, a trusted `*.ts.net` certificate, or realistic suspend/SELinux semantics. The tests must **not** pretend to validate those. Use a separate systemd-capable container or disposable VM to exercise actual unit activation, and use real machines/VMs enrolled in a test tailnet for HTTPS and ACL validation. Never require `--privileged`/host cgroup mounts as the default way to test installer logic.

**Pass when:** the Docker matrix and a real Fedora, Arch/CachyOS, and Ubuntu-family installation pass clean install, no-touch reinstall, repair, service restart/boot, and uninstall tests. Confirm at least one ARM64 Ubuntu-family host/build, including Armbian when available. Existing Caddy and Tailscale state checksums/configurations remain unchanged.

### L6 — Trusted updater, configuration reconciliation, and recoverability

**Deliver:**

- Signed release manifest and pinned trust root; per-platform artifacts and validated version metadata. Safe staging, size/time limits, archive traversal protection, cross-process update lock, signature + hash verification, and semantic-version comparison.
- Versioned installation directories, activation pointer/launcher, restart of only hikari-owned services, local health/version check and automatic rollback. Never overwrite the executing binary in place.
- Separate `update check`, `update apply`, `update rollback`; default `scheduled` checks after boot and daily with bounded check cache/jitter; optional quieter `on_dashboard_open` and `manual` policies. Do not restart mid-request; tolerate GitHub outage.
- Reconciliation only of hikari-generated configuration, including Caddy template changes. Preserve user-owned `config.json`, aliases, endpoint overrides, known nodes, hardware cache and dedicated certificate store.
- Document and test a **first-install trust bootstrap**: where verified release manifests and trusted keys come from, how the installer pins them, and why GitHub TLS alone or a neighboring unsigned SHA file is insufficient.

**Pass when:** an update succeeds, a simulated power interruption leaves a usable prior release, a bad signature or malicious archive fails closed, a bad new version rolls back automatically, and an offline system remains healthy. User config and a pre-existing Caddy service survive all paths.

### L7 — Linux release gate (Stage 1 complete)

Linux is **done** only when all of the following are true:

- [ ] Fedora, CachyOS/Arch, and an Ubuntu derivative have each passed a real-host end-to-end install; no custom hand-edited config required for normal setups.
- [ ] x86-64 and ARM64 Linux artifacts are built and verified; ARM64 is exercised on hardware or an explicitly documented comparable runner. Armbian device-specific limitations are recorded rather than assumed away.
- [ ] Docker distro suite, native CI, Caddy configuration validation, JSON contract fixtures, mocked browser tests and installer idempotence suite pass.
- [ ] Two or more real Tailscale endpoints serve HTTPS; real certificate permissions and ACL behavior are tested. No public listener; existing Caddy/`tailscale serve` configuration is untouched.
- [ ] UI has a polished fleet overview plus CPU/ISA, board/firmware, memory, GPU, NIC and disk cards; offline devices and stale samples are labeled correctly.
- [ ] No requests while all dashboards are closed ⇒ no high-frequency sampling, no agent-driven peer HTTP polling, and no GitHub traffic beyond the boot/daily release check (none in `on_dashboard_open` or `manual` mode). Idle CPU/wakeups/RSS/writes/connections are measured and recorded.
- [ ] Reboot, disconnect/reconnect, sleep/resume where available, hostname change, failed probes, custom port, and >30-day simulated offline retention work.
- [ ] Versioned signed update and automatic rollback are demonstrated; repair/reinstall/uninstall preserve unrelated services and operator configuration.
- [ ] Quickstart documents a normal install, `doctor`, dashboard URL, Caddy resolution, certificate permission requirements, data sensitivity and rollback/uninstall.

**Stage 1 deliverable:** a release suitable for the user's actual Linux fleet, not merely a proof of concept. Only then move to Windows.

---

## 2. Stage 2 — Windows, unattended machine-wide operation

**Goal:** A Windows gaming PC serves the tailnet dashboard **before login**, while a child's account is signed in, during Fast User Switching, after all users sign out, and after reboot. No one must start an app or remain logged in. Use the same protocol, web UI and cached telemetry design as Linux.

### W0 — Native build and Windows collection baseline

- Windows x86-64 LDC release build, CI tests, service-compatible startup/shutdown, bounded loopback HTTP server and durable paths under `C:\ProgramData\hikari\`.
- Native Win32 CPU, memory/commit (not mislabeled swap), network interface counters, process CPU/memory/start identity, volume usage and OS/reboot status.
- Hardware inventory: `GetSystemFirmwareTable`/SMBIOS for system/board/firmware when available; CPU topology/usable ISA; SetupAPI/other supported properties for NIC, storage and GPU; battery APIs where applicable. WMI/CIM is bounded, optional, and never in fast polling.
- Cross-platform JSON fixture tests ensure unsupported values are honest, without changing Linux's published schema.

**Exit:** direct CLI and local HTTP snapshot/status/hardware are accurate on a physical Windows machine, not just a CI runner.

### W1 — True Windows services and automatic Caddy provisioning

- Elevated, idempotent `install.ps1` plus `uninstall.ps1`; clear checks for PowerShell, administrator permission, architecture, Tailscale service/CLI, permissions, certificate prerequisites and existing Caddy.
- Register **two machine-wide Windows services** (`hikari` and `hikari-caddy`) under the Service Control Manager as native services: `hikari.exe` implements the SCM protocol (`serve --service`) and Caddy uses its built-in service support; no wrapper binary. Explicit service account policy (prefer restricted built-in/service-specific identity over default `LocalSystem` when feasible), ACLs on config/state, automatic startup and recovery/backoff.
- If Caddy is absent, install a **private pinned, verified Caddy executable**; don't require Chocolatey/Scoop/winget, alter IIS, or change an unrelated Caddy service. If Caddy is present, use a compatible executable path without modifying its existing service.
- Verify Tailscale access **from the actual service identity**, not just from an interactive administrator shell. If a Tailscale installation is only usable inside an interactive user's context, report an actionable incompatibility instead of installing a login-dependent workaround.
- Windows-safe versioned paths and installer-owned service/launcher management; do not overwrite running `.exe` or depend on a console window.

**Exit:** install as an administrator, sign out all users, reboot, and successfully query machine status from another tailnet node. Test with a standard/child account logged in; the service must remain active across user switches.

### W2 — Hardware cards, fleet parity, and gaming-machine behavior

- Reuse the Linux web UI unchanged for Windows: attractive machine overview, board/BIOS, CPU extensions, RAM, physical disks, GPU, NIC models and live GPU/CPU/process utilization where supported.
- Distinguish GPU telemetry unsupported versus an idle GPU. Handle NVIDIA NVML when present; never require GPU drivers simply to install the agent.
- Confirm network interfaces including Tailscale virtual adapters, system sleep/resume, Wi-Fi changes and games using significant GPU/CPU resources. Avoid aggressive WMI and expensive process scans while a dashboard is closed.
- Explicitly test heterogeneous CPUs and x86 instruction availability where accessible; no CPU-feature inference by marketing name.

**Exit:** from a Linux or Windows browser, a Windows PC behaves like a normal fleet member and exposes useful hardware information with accurate freshness.

### W3 — Windows updater, repair, and release gate

- Verified archive and helper (Caddy) downloads; signed manifest trust bootstrap; versioned atomic activation and rollback coordinated with Service Control Manager.
- Idempotent install/repair/uninstall, preservation of `ProgramData` state and aliases, optional intentional purge; no accidental removal of shared Caddy or Tailscale.
- Test service stopping/restarting, interrupted downloads, failed health check, Windows file locks, Defender/SmartScreen friction, restricted service account permissions, and Caddy TLS provisioning.
- CI: x86-64 build, tests, PowerShell static checks, install-service smoke tests in suitable Windows VM/runner; **real Windows host** integration is mandatory for the release gate.

**Stage 2 is done only when:** Windows is a genuinely unattended, auto-starting, recoverable tailnet member across reboot/logoff/user switching, shows hardware cards and live metrics through the same browser, passes signed update/rollback and does not interfere with unrelated services. Linux remains green throughout.

---

## 3. Stage 3 — Apple Silicon macOS and system-level launchd

**Scope:** Apple Silicon only for this release. The owner's older Intel Mac runs Linux and is covered by the Linux targets. Intel macOS support is deferred; existing compatibility code and fixtures may remain, but native Intel validation and release artifacts are not release requirements.

**Goal:** hikari stays available before interactive login and after logout; no user-space `brew services start` or `LaunchAgent` is required. The installer may use Homebrew to obtain Caddy, but the actual service is **hikari-owned and system-level**.

### M0 — macOS builds, hardware inventory, and telemetry

- Native Darwin arm64 LDC builds and CI; paths under `/Library/Application Support/hikari/` and `/opt/hikari/versions/` as specified in `AGENTS.md`.
- Mach/sysctl `CPU`, memory, network, process and filesystem probes; battery, GPU, reboot/updates where genuinely supported; no private or unsafe APIs just to manufacture GPU utilization.
- Apple Silicon ARM capabilities, with friendly human-readable cards; `hw.model`/Apple model ID when PC-style motherboard info is unavailable. IOKit/IORegistry for safely obtainable hardware facts.
- CPU/GPU/battery/system readouts properly reflect `unknown`, `unsupported`, and permission restrictions.

**Exit:** local CLI and loopback HTTP status/hardware are correct on an Apple Silicon Mac.

### M1 — System LaunchDaemons and Homebrew-aware Caddy installation

- Idempotent `install.sh`/`uninstall.sh` for macOS with required privileged step; create `hikari` and `hikari-caddy` **system-domain LaunchDaemons** in `/Library/LaunchDaemons/`, managed with `launchctl` in the system domain. Do **not** use per-user launch agents or login items.
- Run the D telemetry daemon and Caddy as low-privilege dedicated identities where permissions allow. Record operational exceptions instead of silently running everything as root.
- Homebrew **is assumed present**, not installed by hikari. Find it without depending on the login shell's `PATH` (`/opt/homebrew` versus `/usr/local`). If Caddy is absent, an explicit installer step may invoke `brew install caddy` as the invoking **normal user**, not `sudo brew`; alternatively install a verified hikari-private Caddy binary. Choose the path that preserves existing service isolation.
- **Do not start Homebrew's Caddy service** or alter `brew services` state. Use the detected/pinned executable from a dedicated hikari-owned LaunchDaemon configuration. Confirm how Homebrew upgrades change executable paths, and keep the service predictable.
- Detect the installed Tailscale macOS variant, its noninteractive CLI/daemon visibility and Tailscale certificate permission behavior. **Do not assume** an app usable in an interactive session necessarily exposes the same APIs to a LaunchDaemon; report constraints clearly and require actual service-context validation.
- Recover if Tailscale is unavailable at boot or the Mac resumes from sleep; never fall back to a public bind.

**Exit:** a real Mac can be restarted and signed out, and another tailnet device can still fetch its HTTPS status, independent of which person next logs in.

### M2 — macOS fleet parity, signed updates, and release gate

- Full machine hardware card and dashboard parity with Linux and Windows, with platform-appropriate unavailable states.
- Verified signed archive, versioned installation, launchd restart/health check, failure rollback and preservation of config/state/certificates.
- Idempotent reinstall/repair/uninstall; existing macOS Caddy services/configs untouched; normal Homebrew management not hijacked.
- CI native tests for Apple Silicon; real-host checks for **logout, login window, sleep/wake, Tailscale app variant, certificate access, reboot and version rollback**.

**Stage 3 is done only when:** Apple Silicon has validated builds, the service works without a logged-in user, the hardware inventory is useful and accurate, signed update/rollback works, and the unchanged dashboard can mix all three OSes in one fleet. Windows and Linux regression suites still pass.

---

### Stage 3 execution record — 2026-11-17

M0–M2 implementation is in progress. These checks do **not** waive the exit gates above.
See [`docs/testing-macos.md`](docs/testing-macos.md) for commands, interpretation and the real-host matrix.

- [x] Local Apple Silicon debug/release builds, nine native D test modules, browser regression tests, CLI status/hardware smoke, and a measured idle-agent observation.
- [x] Native Mach/sysctl/libproc/64-bit NIC counters, public battery APIs, sanitized IOKit storage/GPU inventory, and friendly NIC labels exercised on an M1.
- [x] Rootless installer/repair/uninstall and Caddy-reconciler fixtures; actual pinned-Caddy validation of spaced macOS paths, prefixed routes and the tailnet-only listener.
- [x] Signed-input verification, immutable releases, failed-health rollback and interrupted-activation recovery exercised through local fixtures.
- [x] Separate x86_64 release/test binaries linked with official LDC; nine modules passed under existing Rosetta before Intel macOS was deferred.
- [ ] Linux/Windows regression runs on the updated code.
- [x] User-run Apple Silicon temporary system LaunchDaemon passed low-privilege startup and crash recovery.
- [x] Apple Silicon CI passed real installer-account/permission tests, repair, retained-state uninstall and temporary system LaunchDaemon recovery (run 44210913386).
- [ ] Real Tailscale variant/service-context certificate permissions, a mixed fleet over HTTPS, and preservation of an existing Caddy/Tailscale deployment.
- [ ] Logout/login-window, reboot, sleep/wake, address-change, full installed-stack idle measurements and signed service-update/rollback gates.

---

## 4. Test strategy (begin in L0; maintain through all stages)

### 4.1 Four distinct levels — don't substitute one for another

1. **Unit/contract:** fake clocks, platform data, counters, config, JSON schema, signatures, manifest/zip extraction, path ownership, browser mocks. Must be deterministic and offline.
2. **Container integration (Linux):** distro detection/package branch, installers, simulated service-control commands, local HTTP and Caddy config validation, fake Tailscale/peer fixtures. **Tailscale installation and network enrollment are not required here.**
3. **Disposable VM/systemd integration:** real OS service manager, paths, permission profiles, boot order, upgrade/rollback and service recovery. Use Windows VMs for SCM tests and real macOS runners/hosts for launchd tests.
4. **Real tailnet physical/VM smoke:** genuine DNS, Tailscale IP binding, HTTPS certificate, ACLs, Caddy isolation, logout, reconnect and hardware collection. This is the release gate that containers cannot replace.

### 4.2 Required scripted fixtures

- Tailscale online/offline/unknown peers, renamed hostname, custom port, missing `DNSName`, malformed JSON, unreachable peer, TLS failure and an unrelated HTTP service.
- HTTP responses: complete fresh JSON, partial capabilities, delayed `202 collecting`, `503`, timeout, 404/incompatible schema, corrupted/oversized JSON, malicious text fields.
- Fake hardware: Linux x86-64 desktop, AMD/Intel CPU feature combinations, Linux ARM64 board, gaming PC with discrete GPU, laptop battery, Mac Intel, Mac Apple Silicon, virtual machine, missing DMI/SMBIOS.
- Probe timing: first sample, wrap/reset, suspend/resume, long-failed mount, expensive GPU call, 20 concurrent requests within and beyond TTL, retry backoff and collection cancellation.
- Installer/update: already-present Caddy, absent Caddy, conflicting port, partial prior installation, broken download, wrong signature, bad health check, pending activation, user-owned state, repeated uninstall.

### 4.3 Repository tooling and planned developer commands

Suggested additions (names may be adjusted **once** when implementing L0/L5, then kept stable):

```text
tests/integration/linux/
  Dockerfile.fedora
  Dockerfile.arch
  Dockerfile.ubuntu
  Dockerfile.debian
  fixtures/                 # os-release, tailscale status, Caddy/HTTP mocks
  run.sh                    # builds and tests distro containers
  test-installer.sh
  test-services.sh          # VM/systemd-capable tests, distinct from ordinary Docker

tests/integration/windows/   # PowerShell + Windows service/VM smoke
tests/integration/macos/     # launchctl + Tailscale variant/host smoke
tests/browser/               # mocked fleet and hardware API tests
.github/workflows/ci.yml
.github/workflows/release.yml
```

The Linux tester should have **one top-level reproducible command** and a documented method to select particular distributions. It must clean up containers and test fixtures, leave host services unchanged, and report which checks were skipped because they require a real tailnet or systemd host.

### 4.4 Observable quality gates

Automate comparisons where possible and record measurements rather than inventing guaranteed fixed CPU/wakeup budgets:

- Requests within TTL don't rerun a probe; expired requests refresh at most once concurrently; cold calls return documented collecting/error states.
- With dashboard closed, no hikari-initiated peer HTTP requests and no high-frequency metrics scans; GitHub is contacted only by the boot/daily release check (never in `on_dashboard_open` or `manual` mode). Distinguish idle listener sockets from outbound connections.
- Check RSS, CPU time, system wakeups, disk writes, collection latency, and max transient CPU under dashboard activity on representative desktops/laptops/ARM boards.
- Hardware scan latency and storage-query timeouts cannot indefinitely block the fast endpoint; permission and unsupported states remain clear.
- Existing Caddy configs, service status and listeners are unchanged by install, reinstall, update, and uninstall.
- Logs never contain Tailscale auth keys, serials, MACs, Windows product keys or other excluded identifiers; telemetry endpoints expose only allowed information.
- Unit and fleet/browser tests pass with all three kinds of OS nodes in the same response set once Stage 3 is complete.

---

## 5. Documentation and operator experience

By the **end of Stage 1**, provide:

- `README.md` with a minimal Linux install example and tailnet URL, clear Caddy decision, test prerequisites, and screenshots or meaningful illustrations of fleet and hardware cards.
- `docs/install-linux.md` with Fedora, CachyOS/Arch, Ubuntu/Mint/Armbian notes; detection behavior; ARM64 prerequisites; failure/recovery procedures; safe rerun/uninstall; systemd and SELinux troubleshooting.
- `docs/testing-linux.md` showing **no-Tailscale Docker tests**, what they validate, and how to do the additional real Tailscale test.
- `docs/configuration.md` for TTLs, aliases, custom ports, endpoint overrides, updates modes, privacy and explicit unsupported states.
- `docs/security.md` describing Tailscale ACL requirement, Caddy cert authorization, trusted release verification, data exposed, and no automatic Tailscale/network policy edits.

By the **end of Stage 2**, add `docs/install-windows.md`, administrator setup, service-account rationale, child/multiple-user and logged-out behavior, repair/update/uninstall, and Windows firewall/service troubleshooting (never change it silently).

By the **end of Stage 3**, add `docs/install-macos.md`, Apple Silicon, Homebrew-aware Caddy installation, LaunchDaemon setup, Tailscale variant limitations, noninteractive permissions, login-window validation and rollback.

Every installer should explain **what it will change before modifying the host**, report meaningful errors, make repeated invocations safe, and print the real dashboard URL only after validating the relevant prerequisites. A first-time installation should not require hand-editing a Caddyfile.

---

## 6. Deferred work — not required to complete Stages 1–3

These are explicitly **not blockers** for a good three-platform release:

- Historical time-series storage, charts covering weeks/months, alerting or notifications.
- Automatic OS/package upgrades or remote machine administration.
- Installing Tailscale or enrolling other computers automatically.
- Android/iOS agents, ARM32 Linux or Windows ARM64 until separately supported and tested.
- SMART self-tests, exhaustive PCI/vendor lookups, intrusive hardware benchmarks, hardware serial identification.
- A central database/server, native desktop application, browser extension, cloud account or third-party frontend framework.
- UI mutation endpoints for administratively controlling remote agents, unless separately designed and authenticated.

The default product remains: **boot-persistent, on-demand, decentralized monitoring with friendly hardware cards and quiet idle behavior.**

---

## 7. Official references to consult during implementation

- [Caddy installation and distribution packages](https://caddyserver.com/docs/install)
- [Caddy / Tailscale HTTPS certificates and local daemon permissions](https://tailscale.com/docs/integrations/web-servers/caddy/caddy-certificates)
- [Tailscale macOS variants and differences](https://tailscale.com/docs/concepts/macos-variants)
- [Microsoft: service programs (ServiceMain, control handlers, SetServiceStatus)](https://learn.microsoft.com/en-us/windows/win32/services/service-programs)
- [Caddy: running as a Windows service](https://caddyserver.com/docs/running#windows-service)
- [Microsoft Windows Services documentation](https://learn.microsoft.com/en-us/windows/win32/services/services)
- [Apple launchd LaunchDaemons and LaunchAgents](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingLaunchdJobs.html)
- [Homebrew command and service behavior](https://docs.brew.sh/Manpage)
- [Docker Engine documentation](https://docs.docker.com/engine/)

**Next action for an implementation agent:** complete **L0**, commit schemas and fake backends first, and make the no-Tailscale unit/container testing story work early. Do not start W0 until the entire L7 Linux release gate has passed.
