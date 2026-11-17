# Windows Installation Guide (Stage 2)

This guide covers building, testing, and installing **hikari** on Windows 11 (`x86_64`) as boot-persistent Windows Services so telemetry and hardware cards remain available across reboots, sign-outs, and Fast User Switching.

## Prerequisites

- **Tailscale for Windows** installed and enrolled in your tailnet with MagicDNS and HTTPS certificates enabled.
- **LDC2 (`ldc2`) and DUB (`dub`)** with the Microsoft Visual C++ Build Tools (to build from source).
- **WinSW** (`winsw.exe` placed in `C:\ProgramData\hikari\bin\winsw.exe` or passed via `-WinSWBin`) for Windows Service Control Manager (SCM) hosting.

## Building & Testing Locally

```powershell
dub build --compiler=ldc2 --build=release
dub test --compiler=ldc2
.\bin\hikari.exe version
.\bin\hikari.exe snapshot --sample-twice
.\bin\hikari.exe hardware
```

## Installing as Machine-Wide Windows Services

Run from an **elevated Administrator PowerShell** prompt:

```powershell
# Preview changes without modifying the host
.\install\install.ps1 -DryRun

# Install versioned binaries, isolated Caddy config, and WinSW SCM services
.\install\install.ps1 -WinSWBin C:\path\to\winsw-x64.exe

# Verify Tailscale, Caddy, certificates, and loopback API health
.\bin\hikari.exe doctor
```

### Key Windows Design Notes

- **Unattended boot persistence:** Both `hikari` and `hikari-caddy` run under the Service Control Manager (`Automatic` startup), remaining online before login and when standard/child user accounts switch sessions.
- **Caddy isolation:** `install.ps1` reuses an existing `caddy.exe` read-only without changing IIS or any pre-existing Caddy service, or downloads the verified SHA-512 pinned `v2.9.1` binary into `C:\ProgramData\hikari\bin\caddy.exe`.
- **Memory & Load semantics:** `GlobalMemoryStatusEx` reports physical RAM and a separate `commit` object (`ullTotalPageFile`); Unix `load_1m` and `swap` are left `null` rather than mislabeled.
- **Tailscale service visibility:** Verify `tailscale status --json` and Tailscale certificate retrieval work from the service account context (not just your interactive desktop session).

## Repair & Uninstall

```powershell
# Reconcile generated service XML and Caddyfile without losing config.json or nodes.json
.\install\install.ps1 -Repair

# Remove hikari services and binaries while preserving C:\ProgramData\hikari\config\config.json and state\
.\install\uninstall.ps1

# Full purge of all hikari configuration, node registry, and Caddy certificates
.\install\uninstall.ps1 -Purge
```
