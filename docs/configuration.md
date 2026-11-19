# Configuration Reference

Configuration lives at `/etc/hikari/config.json` on Linux. User settings and unknown operator keys are preserved across upgrades, repairs, and reinstalls.

## Schema Overview

```json
{
  "schema_version": 1,
  "listen": {
    "tailnet_port": 9100,
    "loopback_port": 19100,
    "loopback_bind": "127.0.0.1",
    "base_path": "/",
    "allowed_origins": []
  },
  "collection": {
    "ttl_seconds": {
      "fast": 10,
      "processes": 20,
      "device_dynamic": 60,
      "filesystems": 120,
      "tailnet": 300,
      "maintenance": 43200,
      "hardware": 604800
    },
    "max_stale_seconds": {
      "fast": 60,
      "processes": 120,
      "device_dynamic": 600,
      "filesystems": 1200,
      "tailnet": 3600,
      "maintenance": 604800,
      "hardware": 2592000
    },
    "cold_wait_ms": 2000,
    "probe_timeout_ms": 5000
  },
  "discovery": {
    "enabled_on_dashboard_open": true,
    "max_concurrent_probes": 4,
    "probe_timeout_ms": 3000
  },
  "updates": {
    "repo": "OWNER/REPO",
    "mode": "on_dashboard_open",
    "auto_install_verified": true,
    "check_interval_hours": 24,
    "public_key": "",
    "channel": "stable"
  },
  "privacy": {
    "expose_serials": false,
    "expose_mac_addresses": false
  }
}
```

## Field Notes

- **`listen.loopback_bind`:** Must be `127.0.0.1`, `::1`, or `localhost`. Any public bind address (`0.0.0.0`, `::`, LAN IP) is rejected at startup.
- **`listen.base_path`:** `/` by default, or a prefix such as `/hikari` when sharing a Caddy site via `--snippet-only`.
- **`caddy.mode`:** how the dashboard is served over HTTPS.
  - `auto` (default): join an existing Caddy service when every safety check passes, otherwise use the isolated `hikari-caddy`.
  - `integrate`: join, or fail before changing anything.
  - `isolated`: never touch an existing Caddy.
  - `snippet`: only write a snippet.

  The installer's `--caddy-mode` / `-CaddyMode` overrides it for one run. What was actually done is recorded in `<state_dir>/caddy-integration.json` (inspect it with `hikari caddy status`), so repair, mode switches and uninstall reverse exactly that.
- **`caddy.reload`:** `false` by default. When `true`, the installer reloads a joined Caddy after changing it (rolling back if the reload fails); otherwise it prints the reload command.
- **`collection.ttl_seconds` & `max_stale_seconds`:** Request-driven freshness windows (never background polling intervals). When age is between `ttl` and `max_stale`, hikari returns the stale snapshot immediately labeled `stale` while refreshing once in the background.
- **`updates.mode`:**
  - `on_dashboard_open` (default): quiet when dashboards are closed; checks verified releases only when active and due.
  - `manual`: never contacts GitHub automatically; updates only via `hikari update apply`.
  - `scheduled`: checks at `check_interval_hours` (with jitter) even when no dashboard is open.
- **`updates.repo` & `updates.public_key`:** Updates remain **disabled (fail closed)** until `repo` is changed from the `OWNER/REPO` placeholder and a trusted Ed25519 public key is pinned.
- **`privacy`:** Serial numbers and MAC addresses are omitted by default (`false`).

## Persistent Known Nodes (`/var/lib/hikari/nodes.json`)

Confirmed tailnet machines are stored in `nodes.json` along with operator-owned `alias`, custom `tailnet_port`, `base_path`, `hidden`, and `last_known_hardware_summary`. Machine renames on Tailscale reconcile via `node_id` / `tailscale_node_id` without overwriting operator aliases. Offline nodes are retained indefinitely.

### Automatic release maintenance

Installed services include a short-lived, privileged `hikari-maintenance` job
(`io.hikari.maintenance` on macOS). The OS runs a local eligibility check every
five minutes; it does not collect telemetry, discover peers, or contact GitHub
unless the configured update policy and interval permit it. This low-frequency
local wakeup is separate from the telemetry agent's request-driven collection.
In `manual` mode, or without a pinned repository and signing key, it performs no
network operations. Removing/disabling the maintenance timer, LaunchDaemon, or
Windows scheduled task disables automatic maintenance completely.

Dashboard activity also triggers the job immediately through a systemd path
watch, a launchd path watch, or a Windows task with read/execute permission for
the agent. The five-minute eligibility check supports scheduled mode and recovery.
Windows task permissions follow [Microsoft’s task security model](https://learn.microsoft.com/en-us/windows/win32/taskschd/security-contexts-for-running-tasks); the agent cannot edit the privileged task.

In `on_dashboard_open` mode, a successfully served nodes/status response records
activity at most once per check interval plus a two-minute dispatch allowance. The maintenance job only accepts recent
activity (two minutes), adds up to sixty seconds of jitter, and verifies the
signed manifest before trusting its contents. `scheduled` mode uses the same
interval without requiring dashboard activity. Attempts, including failures,
are limited across restarts by protected state under `versions/.maintenance`.
The default release-discovery channel is `stable`; other channels currently need
explicit signed local inputs with `update apply`.

`auto_install_verified: false` checks and records the verified version without
installing. Otherwise the separate maintenance process downloads the exact
platform archive, verifies its signed size/hash, stages it, and performs the
existing health-checked activation/rollback. The agent stays restricted; the
privileged job reads the operator-owned configuration and accepts no commands,
paths, or URLs from the activity request. Downloads use HTTPS only, bounded
sizes/deadlines and retries. `curl` and OpenSSL 3.0+ must be available to the
maintenance account; LibreSSL is rejected (see
[OpenSSL for release signatures](install-macos.md#openssl-for-release-signatures);
on Windows, Git for Windows' OpenSSL is found without PATH changes, see
[Windows prerequisites](install-windows.md#prerequisites)).

`hikari update check` now fetches and verifies the latest stable release. It does
not install it. Supplying `--manifest` and `--sig` retains offline verification.
Install/repair registers the maintenance job; uninstall removes it. Source-only
`hikari serve` records activity but needs an installed maintenance job for
unattended updates.
