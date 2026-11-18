# macOS verification and release gates

M0–M2 require native builds and lifecycle evidence; fixture tests alone do not prove
logout, sleep/wake, certificate access, or a working tailnet dashboard.

## Automated checks

From a trusted checkout with LDC, DUB, Python 3, OpenSSL and Node available:

```sh
dub build --compiler=ldc2 --build=debug
dub build --compiler=ldc2 --build=release
dub test --compiler=ldc2
node tests/browser/test_dashboard.js
bash tests/integration/macos/test-installer.sh
bash tests/integration/macos/test-reconciler.sh
python3 tests/integration/macos/test-reconcile-lifecycle.py
python3 tests/integration/macos/test-release-verification.py
python3 tests/integration/macos/test-activation.py
python3 tests/integration/macos/test-startup.py
bash tests/integration/macos/test-caddy.sh --download-pinned
sudo bash tests/integration/macos/test-services.sh --system-test
# Disposable hosts only; refuses any existing hikari files/accounts:
sudo bash tests/integration/macos/test-system-install.sh --system-test
```

The installer test writes only a temporary root and does not manage real services.
The reconciler tests use fake executables; the lifecycle test uses real 15-second intervals to verify that unchanged configurations are not rewritten, address changes replace the child process, lost identity stops it, and restored identity recovers it. The signature test generates a disposable
Ed25519 key and exercises the actual bootstrap verifier. D update tests verify
signature/hash rejection, immutable staging, activation, failed-health rollback,
lock contention and recovery of an interrupted activation. Installer activation is separately checked against a real loopback health server, including compatibility with the native recovery marker. A blocked local Tailscale CLI is also tested to ensure it cannot delay health/info availability.

The system test creates a uniquely named `io.hikari.test.*` system-domain job under
`/private/tmp`, runs the native binary as `nobody`, verifies HTTP health and a
collection-free info response, kills that test process, and checks launchd recovery.
Its logs are writable by the test identity, and failures include launchd state and captured logs. It removes only its job and temporary files. It does not install production jobs,
create service accounts, require Tailscale, or validate HTTPS.

The separate system-install test requires a disposable host without existing
hikari files or accounts. It creates the real dedicated identities and directories,
checks config access and isolation between telemetry and certificate state, repairs,
uninstalls, and removes its own test accounts. It skips service activation and uses
a fake Caddy; the native service and pinned-Caddy checks cover those separately.

The official LDC 1.43.0 Intel macOS package was downloaded to temporary storage and verified against its published SHA-256 digest. A separate x86_64 release binary and test executable linked successfully; all nine D test modules passed under the machine’s already-installed Rosetta runtime. This found and fixed the Intel `getfsstat$INODE64` binding and native Mach process-counter normalization. This is historical compatibility evidence, not a claim of supported Intel macOS behavior.

macOS support is scoped to Apple Silicon for this release. Intel macOS validation
and artifacts are deferred; Intel machines running Linux remain Linux targets.
CI uses the Apple Silicon runner. Its build, unit, CLI, pinned-Caddy, temporary
LaunchDaemon and real installer-account/permission checks passed in
[run 44210913386](https://github.com/rxwxwwxw/hikari/actions/runs/44210913386).
That run's Linux/Windows static-check failures are separate regression work.

## Real-host matrix (required before declaring Stage 3 complete)

Record macOS release, architecture, Tailscale variant/version, Caddy version,
commands, results, and any limitations. Keep private hostnames and identifiers out
of committed results.

| Gate | Apple Silicon |
| --- | --- |
| Native debug/release build and D tests | Local M1 and native CI passed |
| Native CLI telemetry and hardware | Local M1 and native CI exercised |
| Low-privilege system LaunchDaemon smoke | User-run temporary job and native CI passed startup as nobody and crash recovery |
| Installer identities, permissions, repair and retained-state uninstall | Disposable native CI passed with service activation skipped and fake Caddy |
| Production installed stack; existing services unchanged | Pending full service integration |
| Valid HTTPS from another tailnet device; service-account certificate permission | Pending enrolled hosts |
| Logout/login window and reboot | Pending operator-run host test |
| Sleep/wake, network disconnect and address change | Pending operator-run host test |
| Signed update, health failure, rollback and interrupted activation under launchd | Pending full service integration |
| Mixed Linux/Windows/macOS fleet and hardware cards | Browser fixtures pass; real fleet pending |
| Idle CPU, RSS, wakeups, disk writes and connections | Local 20-second agent measurement below; installed stack pending |

Do not reboot or log out somebody's active development machine to satisfy a test.
Use disposable/test hosts and arrange these disruptive gates explicitly.

## Telemetry interpretation

Darwin memory usage is active + wired + compressed physical pages; it is not a
promise to match Activity Monitor's accounting. Process memory is resident bytes.
Process CPU uses native kernel Mach ticks normalized with `hw.tbfrequency` to scheduler ticks, with one logical CPU equal to 100%. This also avoids Rosetta’s emulated timebase mismatch. The units follow [Apple XNU process accounting](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/bsd_kern.c) and the [public timebase-frequency selector](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/sysctl.h). Aggregate CPU is 0–100%. First rates are null.

NIC byte counters come from the 64-bit IF-MIB. Carrier state comes from
`SIOCGIFMEDIA` when supported; unsupported link state stays null. A `utun` name alone
never establishes Tailscale ownership. Network adapters have localized friendly
labels where SystemConfiguration exposes them. Physical disks are distinguished
from APFS containers by IORegistry ancestry; uncertain mount relationships remain
empty. Unified system RAM is never presented as dedicated GPU VRAM.

Missing firmware, DIMM details, maintenance drift and live GPU metrics stay
unknown/unsupported. Hardware strings and identifiers are read from allowlisted
properties, without serial numbers, MAC addresses, disk UUIDs or raw device paths.

## Local agent idle observation (2026-11-17)

On the development M1, `python3 tests/integration/macos/test-idle.py --seconds 20`
observed 20.010 seconds with no dashboard requests: 0 ms additional CPU time,
7,356,416 bytes RSS, zero additional package/interrupt wakeups, zero process disk
read/write bytes, and unchanged persistent state. The final socket snapshot had
only the loopback listener and no outbound connection. These are one host's
observations, not universal resource guarantees or a packet trace of the entire
window. Tailscale startup was fixture-backed; this does not measure installed
Caddy/Tailscale certificate or reconciliation overhead.
