# hikari

**hikari** is a small, decentralized, request-driven monitoring and hardware inventory agent for personal machines connected via **Tailscale**.

Written in D (compiled with `ldc2`) with zero external D package dependencies and a single self-contained `web/index.html` dashboard, each machine serves its own HTTPS dashboard and JSON API on your tailnet—with no central database, no agent-initiated peer polling loops while the dashboard is closed, and honest handling of missing or unsupported metrics.

---

## Key Features (Stage 1: Linux)

- **Quiet when nobody is looking:** On-demand per-group TTL caching (`fast` 10s, `processes` 20s, `device_dynamic` 60s, `filesystems` 120s, `maintenance` 12h, `hardware` 7d) with single-flight coalescing, stale-while-refresh, and `202 collecting` / `503` error states.
- **First-class hardware inventory:** Lazy `/api/v1/hardware` endpoint with human-readable CPU, motherboard, firmware, RAM, NIC, storage, and GPU cards, plus **x86-64 `CPUID + OSXSAVE/XCR0`** and **ARM64 `HWCAP`** usable ISA extension detection with an offline glossary.
- **Isolated Tailscale HTTPS (`hikari-caddy`):** Runs a dedicated `hikari-caddy` unit bound strictly to your Tailscale IP on port `9100` (`admin off`), leaving any pre-existing system Caddy or `tailscale serve` configuration untouched—or generates a prefixed `/hikari/*` snippet (`--snippet-only`).
- **Loopback-only D agent:** `hikari` binds strictly to `127.0.0.1:19100` (or `::1`), rejects non-loopback configuration, enforces Origin/Host validation (no `Access-Control-Allow-Origin: *`), and redacts serials/MACs by default.
- **Signed transactional updates:** Ed25519 manifest signature + SHA-256 verification, traversal-safe staging, atomic symlink switching, and automatic health-checked rollback.

---

## Quickstart (Linux)

### Prerequisites
- Linux (`x86_64` or `aarch64`): Fedora, CachyOS/Arch, Ubuntu, Linux Mint, Armbian, or Debian.
- [Tailscale](https://tailscale.com/) installed and logged in with MagicDNS and HTTPS certificates enabled.
- [LDC (`ldc2`) and DUB (`dub`)](https://wiki.dlang.org/LDC) to build from source (version `0.1.0` tested with LDC 1.43.0 / DUB 1.42.0).

### Build & Install

```bash
# 1. Build release binary and run unit tests
dub build --compiler=ldc2 --build=release
dub test --compiler=ldc2

# 2. Preview installation changes without modifying the host
./install/install.sh --dry-run

# 3. Install systemd units (hikari.service + isolated hikari-caddy.service)
sudo ./install/install.sh

# 4. Verify Tailscale, Caddy, certificates, and local API health
hikari doctor
```

Once installed, open your machine's tailnet dashboard URL printed by the installer:

```text
https://<machine>.<tailnet>.ts.net:9100/
```

### Caddy Choices
- **Default (`--caddy-source=auto`):** Reuses an existing compatible `caddy` binary read-only (never touching your existing `caddy.service` or `/etc/caddy/Caddyfile`), or downloads a verified pinned Caddy binary into `/opt/hikari/bin/caddy`.
- **Existing Caddy integration (`--snippet-only`):** Generates `/etc/hikari/hikari-snippet.caddy` under `/hikari/*` without creating `hikari-caddy.service` or editing your existing Caddy config.

---

## CLI Commands

```text
hikari version                                # Print agent and schema versions
hikari doctor [--tailscale-fixture <file>]    # Non-destructive preflight checks
hikari snapshot [--out <path|->] [--sample-twice]
hikari hardware [--out <path|->] [--refresh]
hikari nodes list|discover [--tailscale-fixture <file>]
hikari caddy render|snippet                   # Render isolated Caddyfile or /hikari snippet
hikari serve [--config <path>] [--serve-web]  # Run loopback HTTP agent
hikari update check|apply|rollback            # Signed release lifecycle
```

---

## Documentation

- [Linux Installation Guide](file:///home/alex-work/repos/hikari/docs/install-linux.md) — Fedora, CachyOS/Arch, Ubuntu/Mint/Armbian, systemd, SELinux, and rollback/uninstall.
- [Linux Testing Guide](file:///home/alex-work/repos/hikari/docs/testing-linux.md) — Unit tests, no-Tailscale fixture mode, rootless installer tests, Docker distro matrix, and real tailnet validation.
- [Configuration Reference](file:///home/alex-work/repos/hikari/docs/configuration.md) — `config.json` schema, TTLs, ports, base paths, aliases, update policies, and privacy controls.
- [Security Architecture](file:///home/alex-work/repos/hikari/docs/security.md) — Loopback/Tailscale boundaries, CORS/Origin enforcement, Tailscale cert permissions, and signed update trust root.
