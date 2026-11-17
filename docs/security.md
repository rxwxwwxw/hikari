# Security & Privacy Architecture

## Transport & Network Isolation

1. **Loopback-only D listener:** The `hikari` binary binds exclusively to `127.0.0.1` (or `::1`) and validates `loopback_bind` on startup. It never opens a public or tailnet-facing plain HTTP socket.
2. **Tailscale-IP-only HTTPS proxy (`hikari-caddy`):** The dedicated Caddy instance binds only to the node's Tailscale IP on `listen.tailnet_port` (default `9100`), with `admin off` and `auto_https disable_redirects`. If Tailscale is offline at boot, Caddy does not fall back to `0.0.0.0`.
3. **Existing service preservation:** Installers, updaters, and `hikari doctor` never modify, reload, or stop pre-existing Caddy or `tailscaled` configurations.

## Tailnet Access Control & Certificates

- **Tailscale ACLs:** Restrict TCP port `9100` (or your custom `tailnet_port`) in your tailnet ACLs/grants to trusted admin devices allowed to view machine metrics and hardware inventory.
- **Tailscale HTTPS Certificates & CT Logs:** Tailscale issues Let's Encrypt certificates for `.ts.net` names; note that public Certificate Transparency (CT) logs record issued MagicDNS hostnames.
- **No insecure peer fetches:** Peer `/api/v1/info` and browser `/api/v1/status` fetches require valid HTTPS with strict certificate verification.

## Browser & HTTP Hardening

- **No wildcard CORS:** `Access-Control-Allow-Origin: *` is never emitted. `Origin` headers are validated against same-tailnet MagicDNS FQDNs, known nodes, configured `allowed_origins`, or loopback development origins, echoing the exact authorized origin with `Vary: Origin`.
- **DNS rebinding protection:** `Host` headers are validated against loopback names and the node's MagicDNS FQDN.
- **XSS safety:** The dashboard renders all OS-supplied names (hostnames, processes, mounts, hardware strings) strictly via `textContent`, never `innerHTML`, and sanitizes control characters server-side.
- **No administrative mutations over GET:** Read endpoints are strictly read-only and bounded in request/header size.

## Privacy Redaction

By default (`privacy.expose_serials: false`, `privacy.expose_mac_addresses: false`):
- Hardware serial numbers, UUIDs, disk serials, Windows product keys, Tailscale auth keys, and full process command lines (`/proc/<pid>/cmdline`, `environ`) are **never** collected or exposed.
- MAC addresses are excluded from `/api/v1/hardware`.
- `node_id` is an application-generated random UUID (`hikari:<uuid>`).

## Signed Update Trust Root

Updates **fail closed** unless both a pinned repository (`updates.repo != "OWNER/REPO"`) and an independently distributed Ed25519 public key (`updates.public_key`) are configured. Before extracting any archive:
1. `manifest.json` must pass Ed25519 signature verification (`manifest.sig`).
2. Repository, channel, and semantic version (`SemVer > current`) are checked.
3. Archive byte length and SHA-256 checksum must match the signed manifest.
4. `tar` entries are inspected to reject absolute paths, `..` traversal, symlinks, and hardlinks.
5. Activation uses atomic symlink switching and rolls back automatically if `/healthz` or `/api/v1/info` fails verification.
