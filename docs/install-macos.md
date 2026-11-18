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
MACOS_SMOKE_STATE=$(mktemp -d /tmp/hikari-smoke-XXXXXX)
./bin/hikari snapshot --state-dir "$MACOS_SMOKE_STATE" --sample-twice
./bin/hikari hardware --state-dir "$MACOS_SMOKE_STATE"
rm -rf "$MACOS_SMOKE_STATE"
```

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
builds and local tests are exercised during development; Stage 3 remains gated on
Intel execution and real service/tailnet/logout/reboot/sleep tests. Do not infer
production readiness from a successful build or staged installer test.

Python 3 and an OpenSSL build supporting Ed25519 are also required for archive
installation verification; Node is required only for browser tests. Homebrew is
never installed by hikari, and `sudo brew`/`brew services` are never used.

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

Adjust the executable for Intel Homebrew or the installed Tailscale app. Do not
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

Use `x86_64` artifacts on Intel. The bootstrap validates the signature, pinned
repository, target architecture, size, digest, archive paths and file types before
extracting. A trusted local binary build can still be installed without an archive.
Do not use `--no-restart` for production updates: it deliberately bypasses service
restart and health validation and exists for staging/test workflows.

`--snippet-only` exports only a prefixed snippet, without installing binaries,
accounts, configuration or services. Importing it and reloading an existing Caddy
instance remain operator actions.
