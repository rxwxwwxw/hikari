# macOS Installation Guide (Stage 3)

This guide covers building, testing, and installing **hikari** on **Apple Silicon (`arm64`)** and **Intel (`x86_64`)** Macs using system-domain **launchd LaunchDaemons** (`/Library/LaunchDaemons/`) so monitoring remains active at the login window and after users log out.

## Prerequisites

- macOS with **Tailscale** installed and enrolled (MagicDNS and HTTPS certificates enabled).
- **Homebrew** installed (`/opt/homebrew` on Apple Silicon or `/usr/local` on Intel).
- **LDC2 (`ldc2`) and DUB (`dub`)** (`brew install ldc dub`) to build from source.

## Building & Testing Locally

```bash
dub build --compiler=ldc2 --build=release
dub test --compiler=ldc2
./bin/hikari version
./bin/hikari snapshot --sample-twice
./bin/hikari hardware
```

## Installing System-Domain LaunchDaemons

```bash
# Preview changes without modifying macOS
./install/install.sh --dry-run

# Install binaries, /Library/Application Support/hikari/, and system LaunchDaemons
sudo ./install/install.sh

# Verify Tailscale variant, certificates, Caddyfile, and local health
hikari doctor
```

### macOS Architecture & Isolation Notes

- **LaunchDaemons, not LaunchAgents:** Services are installed as `io.hikari.agent` and `io.hikari.caddy` in `/Library/LaunchDaemons/` and managed with `launchctl bootstrap system`. No login session or `~/Library/LaunchAgents` is required.
- **Homebrew & Caddy isolation:** `install.sh` detects `/opt/homebrew/bin/caddy` or `/usr/local/bin/caddy` read-only without running `sudo brew` or touching `brew services`. If Caddy is absent, it downloads and SHA-512 verifies the pinned `v2.9.1` binary into `/opt/hikari/bin/caddy` (or runs `brew install caddy` as `$SUDO_USER` only if `--caddy-source=system-package` is explicitly requested).
- **Tailscale macOS variants:** Verify that the installed Tailscale variant allows non-interactive daemon access to `tailscale status --json` and HTTPS certificates from the `LaunchDaemon` context.
- **Hardware cards:** Apple Silicon reports `hw.model`, `hw.perflevel0.physicalcpu` / `hw.perflevel1.physicalcpu` (P/E cores), and `hw.optional.*` ISA flags; unsupported live GPU utilization is honestly marked `unsupported`.

## Repair, Rollback, & Uninstall

```bash
# Reconcile LaunchDaemon plists and Caddyfile while preserving config.json and state/
sudo ./install/install.sh --repair

# Roll back to previous version
sudo /opt/hikari/versions/current/hikari update rollback

# Remove hikari binaries and LaunchDaemons (preserves /Library/Application Support/hikari/)
sudo ./install/uninstall.sh

# Full removal including config.json, nodes.json, and Caddy certs
sudo ./install/uninstall.sh --purge
```
