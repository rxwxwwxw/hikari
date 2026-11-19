# macOS Installation Guide (Stage 3)

This guide covers building, testing, and installing **hikari** on **Apple Silicon (`arm64`)** Macs using system-domain **launchd LaunchDaemons** (`/Library/LaunchDaemons/`) so monitoring remains active at the login window and after users log out. Intel macOS support is deferred for this release; Intel Macs running Linux use the Linux targets.

## Install a release

Download `hikari-install.sh` from the [release page](https://github.com/rxwxwwxw/hikari/releases), then:

```sh
bash hikari-install.sh --dry-run
sudo bash hikari-install.sh --reload
```

Python 3.9+ and OpenSSL 3 (`brew install openssl@3`; macOS's own `/usr/bin/openssl` is LibreSSL and cannot verify the Ed25519 release signature) are required. See [bootstrap prerequisites, trust, and options](install-bootstrap.md). No compiler or checkout is needed. Existing compatible Caddy services are reused by default through a verified import and hikari-owned site; reload is explicitly authorized above. Unsafe integration falls back to isolated Caddy. The final report distinguishes **Ready** from **Installed; setup incomplete**.

## Prerequisites

- macOS with **Tailscale** installed and enrolled (MagicDNS and HTTPS certificates enabled).
- **Homebrew** is only needed if you choose it to obtain development tools, Python/OpenSSL, or Caddy; hikari never installs Homebrew.
- **LDC2 (`ldc2`) and DUB (`dub`)** (`brew install ldc dub`) to build from source.

For developer builds, see [building from source](building.md).

## Installing System-Domain LaunchDaemons

```bash
# Preview changes without modifying macOS
./install/install.sh --dry-run

# Install binaries, /Library/Application Support/hikari/, and system LaunchDaemons
sudo ./install/install.sh

# Verify Tailscale variant, certificates, Caddyfile, and local health
/opt/hikari/versions/current/hikari doctor
```

### macOS Architecture & Isolation Notes

- **LaunchDaemons, not LaunchAgents:** Services are installed as `io.hikari.agent` and `io.hikari.caddy` in `/Library/LaunchDaemons/` and managed with `launchctl bootstrap system`. No login session or `~/Library/LaunchAgents` is required.
- **Homebrew & Caddy isolation:** `install.sh` detects `/opt/homebrew/bin/caddy` or `/usr/local/bin/caddy` read-only without running `sudo brew` or touching `brew services`. If Caddy is absent, it downloads and SHA-512 verifies the pinned `v2.9.1` binary into `/opt/hikari/bin/caddy` (or runs `brew install caddy` as `$SUDO_USER` only if `--caddy-source=system-package` is explicitly requested).
- **Joining a Homebrew Caddy:** with `--caddy-mode=auto` (default), if `brew services` runs Caddy with a Caddyfile and every safety check passes, hikari joins it instead of running its own instance: one marked import line plus a hikari-owned site file, verified with `caddy adapt` and reversible byte for byte. It reloads that Caddy only with `--reload` (`caddy reload`); otherwise the installer prints the command. Use `--caddy-mode=isolated` to opt out. See [caddy-integration.md](caddy-integration.md).
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

## Current validation status

See [macOS testing and release gates](testing-macos.md). Native Apple Silicon
builds, unit tests and disposable installer-account/permission checks passed in CI;
Stage 3 remains gated on real tailnet/logout/reboot/sleep tests. Do not infer
production readiness from a successful build or staged installer test.

Python 3 and OpenSSL 3 are also required for archive installation verification;
Node is required only for browser tests. Homebrew is never installed by hikari,
and `sudo brew`/`brew services` are never used.

### OpenSSL for release signatures

Installer, bootstrap and self-update verify the Ed25519 release signature with
`openssl pkeyutl -verify -rawin`, which needs **OpenSSL 3.0 or newer**.
`/usr/bin/openssl` on macOS is LibreSSL, which cannot do this, and launchd
daemons (`io.hikari.agent`, `io.hikari.maintenance`) and `sudo` run with a minimal
PATH where LibreSSL comes first. hikari therefore probes, in order:

1. `/opt/homebrew/opt/openssl@3/bin/openssl` (Homebrew, Apple Silicon)
2. `/usr/local/opt/openssl@3/bin/openssl` (Homebrew, Intel)
3. `/opt/local/libexec/openssl3/bin/openssl` (MacPorts `openssl3`)
4. `openssl` from PATH

and uses the first one whose `openssl version` reports OpenSSL 3 or newer. No
PATH change is needed. LibreSSL and OpenSSL 1.x are rejected with an explicit
message, for example:

```text
No Ed25519-capable OpenSSL found for release signature verification:
/usr/bin/openssl is LibreSSL 3.3.6 (LibreSSL cannot verify Ed25519 signatures
with pkeyutl -rawin). Install OpenSSL 3 (macOS: `brew install openssl@3`) ...
```

In that case the update or installation fails closed: nothing is installed
and the signature check is never skipped. `hikari doctor` reports which OpenSSL
it will use in its `signature_verifier` check. The chosen binary is part of the
update trust path, so keep the Homebrew prefix writable only by trusted
administrators.

### Service identities and recovery

`io.hikari.agent` runs as `_hikari`; `io.hikari.caddy` runs as `_hikari_caddy`.
Their state and certificate storage are separate; `_hikari_config` grants both identities read access to the root-owned configuration. A root-owned sticky state parent prevents either daemon from replacing the other daemon’s directory entry. A short-lived root job,
`io.hikari.recover`, does no collection or downloads: at boot it checks for an
interrupted activation and invokes the prior known-good binary to restore and
health-check the old release. Recovery retries are throttled to 30 seconds on
failure. Dedicated service accounts are retained on uninstall to avoid reassigning
ownership of retained files; they are hidden and cannot log in.

Application releases are immutable. Repair/reinstall of identical contents is
safe; changed contents with the same version fail rather than replacing a live
release. Use a new version for changed release contents. Configuration, node
aliases, hardware cache, endpoint overrides and certificate state remain outside
the version directories.

### Network reconciliation and certificate permissions

The Caddy wrapper reads local Tailscale status at startup and every 60 seconds to
recover from delayed startup, disconnects, and address changes. This is local
service reconciliation: it does not contact peers, collect telemetry or check
GitHub. Unchanged generated configurations are held in memory without rewriting
files. Caddy owns certificate issuance/renewal traffic and may contact Tailscale's
certificate service. Issuance can publish the MagicDNS hostname in certificate
transparency logs.

The operator-owned file
`/Library/Application Support/hikari/network-reconcile-seconds` controls the
interval (zero means startup-only; otherwise at least 15 seconds). Repair preserves
it. Restart `io.hikari.caddy` after editing it. With zero, unavailable startup
identity is retried by launchd instead of an internal loop.

Validate noninteractive access with the actual installed CLI, for example:

```sh
sudo -u _hikari /opt/homebrew/bin/tailscale status --json
sudo -u _hikari_caddy /opt/homebrew/bin/tailscale status --json
```

Adjust the executable for your Homebrew prefix or the installed Tailscale app. Do not
commit the resulting peer metadata. The [Tailscale macOS variants](https://tailscale.com/docs/concepts/macos-variants)
have different daemon/CLI behavior. A successful interactive status command does
not establish that Caddy can access its certificate API. Follow the
[Tailscale Caddy certificate guide](https://tailscale.com/docs/integrations/web-servers/caddy/caddy-certificates)
for the installed variant's supported permission mechanism, then verify HTTPS
from another tailnet machine. hikari diagnoses this boundary without changing
Tailscale operator settings or restarting its daemon. If the variant cannot
provide the required service-context APIs, the HTTPS gate remains unmet; do not
use plaintext or disable certificate validation.

### Signed archive installation and update

Obtain the release public key through an independently trusted channel. Keep the
installer/verifier from a trusted checkout or independently verified release;
a key downloaded beside an unsigned archive does not establish trust.

```sh
sudo ./install/install.sh --binary-source hikari-darwin-arm64.tar.gz \
  --manifest manifest.json --sig manifest.sig \
  --repo OWNER/REPO --pubkey /trusted/location/release-public-key.pem

sudo /opt/hikari/versions/current/hikari update apply \
  --manifest manifest.json --sig manifest.sig --archive hikari-darwin-arm64.tar.gz
sudo /opt/hikari/versions/current/hikari update recover
```

The bootstrap validates the signature, pinned
repository, target architecture, size, digest, archive paths and file types before
extracting. A trusted local binary build can still be installed without an archive.
Do not use `--no-restart` for production updates: it deliberately bypasses service
restart and health validation and exists for staging/test workflows.

`--snippet-only` exports only a prefixed snippet, without installing binaries,
accounts, configuration or services. Importing it and reloading an existing Caddy
instance remain operator actions.
