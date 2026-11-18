# hikari

**hikari** is a small, decentralized, request-driven monitoring and hardware inventory agent for personal machines connected via **Tailscale**.

Written in D (compiled with `ldc2`) with zero external D package dependencies and a single self-contained `web/index.html` dashboard, each machine serves its own HTTPS dashboard and JSON API on your tailnet—with no central database, no agent-initiated peer polling loops while the dashboard is closed, and honest handling of missing or unsupported metrics.

---

## Key Features (Stage 1: Linux)

- **Quiet when nobody is looking:** On-demand per-group TTL caching (`fast` 10s, `processes` 20s, `device_dynamic` 60s, `filesystems` 120s, `maintenance` 12h, `hardware` 7d) with single-flight coalescing, stale-while-refresh, and `202 collecting` / `503` error states.
- **First-class hardware inventory:** Lazy `/api/v1/hardware` endpoint with human-readable CPU, motherboard, firmware, RAM, NIC, storage, and GPU cards, plus **x86-64 `CPUID + OSXSAVE/XCR0`** and **ARM64 `HWCAP`** usable ISA extension detection with an offline glossary.
- **Tailscale HTTPS:** Reuses a compatible existing Caddy service through verified, reversible integration by default, or runs an isolated `hikari-caddy`. Hikari routes bind only to the Tailscale IP; `tailscale serve` is never changed.
- **Loopback-only D agent:** `hikari` binds strictly to `127.0.0.1:19100` (or `::1`), rejects non-loopback configuration, enforces Origin/Host validation (no `Access-Control-Allow-Origin: *`), and redacts serials/MACs by default.
- **Signed transactional updates:** Ed25519 manifest signature + SHA-256 verification, traversal-safe staging, atomic symlink switching, and automatic health-checked rollback.

---

## Install a prebuilt release

Download the standalone installer for your OS from the [release page](https://github.com/rxwxwwxw/hikari/releases). No Git checkout, D compiler, or DUB is needed. The installer detects the architecture, downloads the release, and verifies its Ed25519 signature before running it.

Prerequisites: Tailscale installed and logged in, MagicDNS and HTTPS certificates enabled, **Python 3.9+**, and **OpenSSL with Ed25519 support** on PATH. Supported release targets are Linux x86-64/ARM64, macOS Apple Silicon, and Windows x86-64. See [bootstrap trust and prerequisites](docs/install-bootstrap.md) before first use.

Linux / macOS, from the directory containing `hikari-install.sh`:

```sh
bash hikari-install.sh --dry-run
sudo bash hikari-install.sh --reload
```

Windows, from an Administrator PowerShell in the directory containing `hikari-install.ps1`:

```powershell
.\hikari-install.ps1 -DryRun
.\hikari-install.ps1 -Reload
```

**By default, hikari reuses an existing compatible Caddy service**, adds a verified import and a hikari-owned site serving the dashboard and `/api/v1/*`, and preserves existing routes. `--reload` / `-Reload` explicitly authorizes applying the addition without restarting Caddy. If integration is unsafe or no service exists, the installer explains why and uses an isolated `hikari-caddy`. Use `--caddy-mode isolated` / `-CaddyMode isolated` to choose isolation explicitly. Saved operator choices remain authoritative on reinstall.

The installer prints **Ready** only after checking the agent, TLS-verified API, and dashboard route. Otherwise it prints **Installed; setup incomplete**, an intended address, and the remaining action. Fix that prerequisite and rerun the same command; configuration and node aliases are preserved. A dry run downloads and verifies temporary files and prints the plan, without changing installed files or services.

Use `--version 0.2.0` / `-Version 0.2.0` to select a published version (replace the example with the desired release). Local readiness does not prove another tailnet member's ACL access; open the printed URL from a second machine to check that boundary.

Platform details: [Linux](docs/install-linux.md), [macOS](docs/install-macos.md), [Windows](docs/install-windows.md). Developers: [building from source](docs/building.md).

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

- [Linux Installation Guide](docs/install-linux.md) — Fedora, CachyOS/Arch, Ubuntu/Mint/Armbian, systemd, SELinux, and rollback/uninstall.
- [Linux Testing Guide](docs/testing-linux.md) — Unit tests, no-Tailscale fixture mode, rootless installer tests, Docker distro matrix, and real tailnet validation.
- [Configuration Reference](docs/configuration.md) — `config.json` schema, TTLs, ports, base paths, aliases, update policies, and privacy controls.
- [Security Architecture](docs/security.md) — Loopback/Tailscale boundaries, CORS/Origin enforcement, Tailscale cert permissions, and signed update trust root.
