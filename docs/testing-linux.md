# Linux Testing Guide

hikari separates testing into four explicit tiers (`ROADMAP.md` §4) so container checks never pretend to validate real systemd PID 1 or live Tailscale TLS.

## 1. Unit & Contract Tests (No Tailscale or Root Required)

```bash
dub test --compiler=ldc2
```

Covers:
- `CounterTracker!K` and `SystemRateState`: unknown initial rates (`null`), counter wrap/reset, sub-50ms intervals, backwards monotonic clock jumps, suspend/resume gap detection, PID reuse via `(pid, start_id)`, and exited PID pruning.
- `RefreshCoordinator` & `TelemetryCacheStore`: per-group TTLs, stale-while-refresh, 20-caller single-flight coalescing, `202 collecting` & `503` cold failure semantics, isolation of hung mount/GPU probes from fast CPU status, and `/info` / `/status` never triggering `/hardware`.
- Linux `/proc` & `/sys` parsers: process names with spaces/parentheses, `mountinfo` octal unescaping & Btrfs subvolume retention, dual battery `energy_*`/`charge_*` units, kernel drift, SMBIOS Type 17 parser, DMI placeholder scrubbing, and serial/MAC redaction.
- HTTP security & Tailnet registry: CORS origin allowlisting, cross-tailnet lookalike rejection, Host header checks, MagicDNS trailing dot trimming, host renames preserving operator aliases/ports, and >30-day offline node retention.
- Signed updater: SemVer ordering, Ed25519 sign/verify with OpenSSL, archive traversal/symlink rejection, update locking, and automatic rollback on failed health checks.

## 2. Browser Dashboard Tests

```bash
node tests/browser/test_dashboard.js
```

Validates `web/index.html` in a sandboxed DOM environment: no external CDN/fonts/service worker, relative API URL handling, visibility-hidden timer shutdown & `AbortController` cancellation, mixed `200`/`202`/`503`/offline states, lazy hardware loading, and strict XSS escaping (`textContent`).

## 3. Linux Installer & Distro Matrix Tests

```bash
# Run rootless installer tests, live loopback service smoke test, and container matrix (auto-detects Podman/Docker)
bash tests/integration/linux/run.sh

# Force Podman (auto-bootstraps rootless podman-static if podman is not installed globally)
bash tests/integration/linux/run.sh --engine=podman

# Select a single distro container or skip container builds
bash tests/integration/linux/run.sh --distro fedora
bash tests/integration/linux/run.sh --local-only
```

### What Docker Containers Validate vs What They Do Not
- **Validated:** `/etc/os-release` detection across `fedora`, `arch`, `ubuntu`, and `debian`; `--dry-run`; idempotent reinstall/repair preserving config & state; non-interference with pre-existing Caddy & Tailscale files; `--snippet-only` output; port-conflict fail-before-write; `uninstall.sh` and `--purge`.
- **Not validated by ordinary containers:** Real `systemd` PID 1 unit boot ordering, Fedora SELinux policy enforcement, real `tailscaled` MagicDNS & `.ts.net` HTTPS certificates, and cross-node tailnet ACL behavior. Validate those on disposable systemd VMs and real tailnet hosts (`hikari doctor`).

## 4. Local No-Tailscale Developer Server Mode

```bash
./bin/hikari serve \
  --port 19100 \
  --state-dir /tmp/hikari-dev \
  --tailscale-fixture tests/fixtures/tailscale/online_fleet.json \
  --serve-web
```

Open `http://127.0.0.1:19100/` in a browser to inspect the local node and mocked fleet UI.
