# Prebuilt release installation

The release workflow publishes `hikari-install.sh` (Linux/macOS) and `hikari-install.ps1` (Windows). They are standalone entry points containing the release verifier and a pinned repository/public key. Obtain this initial installer through a trusted distribution channel; the signature check cannot establish trust in the program performing that check. Subsequent release payloads are verified before extraction or execution.

The pinned repository is `rxwxwwxw/hikari`. Releases are signed with a dedicated Ed25519 release key (not an SSH or account key), whose public half is:

```text
-----BEGIN PUBLIC KEY-----
MCowBQYDK2VwAyEAmg6idV2yVLLRlpsPxPs2XTYdWhixW85z6hLnKYyzcCU=
-----END PUBLIC KEY-----
```

`install/trust.json` stores this same SubjectPublicKeyInfo PEM. No private key is included. Release CI requires `HIKARI_RELEASE_ED25519_KEY` to contain the matching PEM private signing key and fails publication if its public key differs. An OpenSSH private-key file is not interchangeable with this PEM signing format; configuring release credentials is an operator action. Never put private keys in the repository.

## Prerequisites

- Tailscale enrolled, with MagicDNS and HTTPS certificates enabled. Hikari diagnoses missing access but does not change Tailscale, ACLs, or firewall settings.
- Python **3.9 or newer** (`python3` on Unix, `python` on Windows).
- OpenSSL supporting Ed25519 on PATH. macOS's bundled LibreSSL may not suffice; use an already installed compatible OpenSSL, such as Homebrew OpenSSL, and ensure its `bin` directory remains on PATH when invoking with sudo. On Windows, ensure both Python and OpenSSL are visible in the elevated PowerShell session.
- Python must have a working CA certificate store. If a python.org macOS installation reports `CERTIFICATE_VERIFY_FAILED`, run its supplied `Install Certificates.command` or configure a trusted CA bundle; never disable TLS verification.
- Administrator/root permission for service installation. Dry runs do not need elevation.

No compiler, source checkout, package manager, or manual choice of platform archive is required. Native dependency-free bootstrapping is deferred; this version reuses the existing Python/OpenSSL verification approach on all platforms.

## Options and outcomes

Unix:

```sh
bash hikari-install.sh --dry-run
sudo bash hikari-install.sh --reload
# Additional installer options follow --:
sudo bash hikari-install.sh --reload -- --tailnet-port 9200
```

Windows (Administrator PowerShell):

```powershell
.\hikari-install.ps1 -DryRun
.\hikari-install.ps1 -Reload
.\hikari-install.ps1 -Reload -InstallerArguments @('-TailnetPort', '9200')
```

`--version` / `-Version` selects a release; the default is latest. `--caddy-mode` / `-CaddyMode` accepts `auto`, `integrate`, `isolated`, and `snippet`. Auto reuses a verified compatible service; integrate requires one; isolated opts out of integration. Existing configuration is preserved. The normal route is a separate tailnet-only site on port 9100 within the existing Caddy service, not an unsolicited rewrite of an existing application's routes or port 443 site.

Reloading an existing Caddy requires `--reload` / `-Reload` or the saved `caddy.reload` setting. Without it, integration is staged and readiness reports the pending reload. Caddy is never restarted. Unsafe integration falls back in auto mode, with its reason in the installation plan.

Exit status **0** means success (or a completed dry run/staged install); **2** after installation means files are installed but readiness needs attention. Invalid arguments can also return 2 before installation. Verification and installation failures return nonzero and never claim readiness. Readiness checks use only `/healthz`, `/api/v1/info`, and the static dashboard, with verified TLS, bounded responses, no redirects, and no telemetry collection. The API identity/version must match the local agent and the page must match the installed dashboard asset.

If setup is incomplete, follow the printed action and rerun the installer. Existing aliases, configuration, and state are retained. Certificate issuance may need time on first use; rerun after Caddy finishes obtaining its certificate. Hikari does not disable certificate checking to get past a failed check.
