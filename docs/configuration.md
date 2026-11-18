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
