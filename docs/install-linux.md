# Linux Installation Guide

This guide covers installing, repairing, updating, and uninstalling **hikari** on Stage 1 Linux targets: **Fedora**, **CachyOS / Arch Linux**, and **Ubuntu-family** distributions (Ubuntu, Linux Mint, Armbian, Debian) on `x86_64` and `aarch64`.

## Install a release

Download `hikari-install.sh` from the [release page](https://github.com/rxwxwwxw/hikari/releases), then:

```sh
bash hikari-install.sh --dry-run
sudo bash hikari-install.sh --reload
```

Python 3.9+ and Ed25519-capable OpenSSL are required. See [bootstrap prerequisites, trust, and options](install-bootstrap.md). No compiler or checkout is needed. Existing compatible Caddy services are reused by default through a verified import and hikari-owned site; reload is explicitly authorized above. Unsafe integration falls back to isolated Caddy. The final report distinguishes **Ready** from **Installed; setup incomplete**.

## Distribution Detection

`install/install.sh` inspects `/etc/os-release` using both `ID` and `ID_LIKE`:
- **`fedora`, `rhel`, `centos`, `rocky`, `almalinux`** → `dnf` package family
- **`cachyos`, `arch`, `archlinux`, `endeavouros`, `manjaro`** → `pacman` package family
- **`ubuntu`, `linuxmint`, `armbian`, `debian`, `pop`, `raspbian`** → `apt` package family

## Caddy Resolution Policy

`--caddy-mode` decides how hikari is served. It defaults to `caddy.mode` in `config.json`, else `auto`:

- **`auto` (default):** if a `caddy.service` runs a Caddyfile and every safety check passes, hikari **joins it**. It appends one marked `import hikari.caddy` block and writes `hikari.caddy` next to that Caddyfile. The change is verified with `caddy adapt`, a backup is kept, and removal restores the file byte for byte. If anything is uncertain, hikari falls back to the isolated `hikari-caddy` below; the installer's plan shows which, and why. See [caddy-integration.md](caddy-integration.md).
- **`integrate`:** join the existing Caddy or stop before changing anything.
- **`isolated`:** never touch an existing Caddy; always run `hikari-caddy`.
- **`snippet`** (same as `--snippet-only`): only write a snippet for manual import.

hikari never restarts, stops or deletes an existing `caddy.service`. When it joins one, that Caddy is reloaded only with `--reload` (`systemctl reload caddy`); otherwise the installer prints the command. Switching modes on a later `--repair` reverses the previous choice first: from joined to isolated restores the user's Caddyfile; from isolated to joined removes `hikari-caddy.service` before the reload.

For the isolated instance, the binary is chosen as follows:

- **`--caddy-source=auto` (default):** If a compatible `caddy` binary (`>= 2.10.0`) is already on `PATH`, `hikari-caddy.service` invokes that binary with its own isolated `/etc/hikari/Caddyfile` (`admin off`, `auto_https disable_redirects`, storage in `/var/lib/hikari/caddy`, bound exclusively to the Tailscale IP). When no compatible `caddy` is installed, hikari refreshes package metadata (`pacman`/`dnf`/`apt`), checks if the distro package is `>= 2.10.0`, and offers to install it without enabling a system `caddy.service`; if the distro package is older than `2.10.0`, unavailable, fails, or is declined, hikari downloads the verified, SHA-512-pinned Caddy binary (`v2.11.9`) to `/opt/hikari/bin/caddy`.
- **`--caddy-source=private`:** Always installs/uses the private pinned binary in `/opt/hikari/bin/caddy`.
- **`--caddy-source=system-package`:** Installs the distro `caddy` package via `dnf`/`pacman`/`apt`, still running `hikari-caddy.service` separately.
- **`--snippet-only`:** Writes `/etc/hikari/hikari-snippet.caddy` mounted under `/hikari/*` so you can `import /etc/hikari/hikari-snippet.caddy` into an existing Caddy site block manually.

## Systemd Units & Directory Layout

- `/opt/hikari/versions/<version>/` — versioned binary (`hikari`), `web/index.html`, and Caddy templates, pointed to by `/opt/hikari/versions/current` (and `previous` for rollback).
- `/etc/hikari/config.json` — operator-owned configuration (never overwritten by reinstall/repair).
- `/etc/hikari/Caddyfile` — generated isolated Caddy configuration.
- `/var/lib/hikari/` — persistent `node_id`, `nodes.json`, `hardware_cache.json`, and dedicated Caddy certificate storage (`/var/lib/hikari/caddy`).
- `/etc/systemd/system/hikari.service` — runs `hikari serve` as the restricted `hikari` system user (`NoNewPrivileges=true`, `ProtectSystem=strict`).
- `/etc/systemd/system/hikari-caddy.service` — runs isolated Caddy on the Tailscale IP (`After=tailscaled.service hikari.service`).

## Tailscale Certificate Permissions & Fedora SELinux

1. **Tailscale HTTPS Certificates:** Caddy requests `.ts.net` TLS certificates from the local `tailscaled` daemon over its Unix socket. If you customize `hikari-caddy.service` to run as a non-root user, grant that user certificate permission in `/etc/default/tailscaled` (or `/etc/sysconfig/tailscaled` on Fedora) using `TS_PERMIT_CERT_UID=<uid>`, or keep `User=root` on `hikari-caddy.service` while `hikari.service` runs unprivileged.
2. **Fedora SELinux:** Keep SELinux in enforcing mode. When `hikari-caddy` serves static files from `/opt/hikari/versions/current/web` or binds port `9100`, ensure SELinux labels allow access (e.g. `restorecon -Rv /opt/hikari /etc/hikari /var/lib/hikari` and if port `9100` is blocked by SELinux `httpd_t` context, run `semanage port -a -t http_port_t -p tcp 9100` or choose an allowed port).
3. **ARM64 / Armbian notes:** On ARM64 boards lacking SMBIOS/DMI (`/sys/class/dmi/id`), hikari reads `/proc/device-tree/model` for the board model and auxiliary-vector `HWCAP`/`HWCAP2` for CPU ISA capabilities.

## Repair, Rollback, and Uninstall

```bash
# Reconcile generated systemd units & Caddyfile without losing config.json or nodes.json
sudo ./install/install.sh --repair

# Roll back to previous installed release version
sudo /opt/hikari/versions/current/hikari update rollback

# Remove hikari binaries & units while preserving /etc/hikari and /var/lib/hikari
sudo ./install/uninstall.sh

# Full removal including config, nodes.json, and Caddy cert cache (never touches Tailscale or system Caddy)
sudo ./install/uninstall.sh --purge
```
