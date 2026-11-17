# Windows Installation Guide (Stage 2)

This guide covers building, testing, and installing **hikari** on Windows 11 (`x86_64`) as boot-persistent Windows services, so telemetry and hardware cards stay available before anyone logs in, while a standard/child account is signed in, during Fast User Switching, after every user signs out, and after reboot.

## Prerequisites

- **Tailscale for Windows**, enrolled in your tailnet, with MagicDNS and HTTPS certificates enabled. Turning on Tailscale's **Run unattended** option is recommended so `tailscaled` is not tied to one interactive user (see [Service accounts](#service-accounts-and-tailscale-access)).
- **WinSW** (Windows service wrapper, x64 build). Either pass `-WinSWBin C:\path\to\WinSW-x64.exe`, or pass `-WinSWSha256 <hash>` so the installer can download the pinned v2.12.0 release and check it. The installer does not download WinSW without a trusted hash.
- **Caddy** is optional. If no `caddy.exe` is on `PATH`, a pinned Caddy v2.9.1 is downloaded into `C:\ProgramData\hikari\bin\` and checked against its SHA-512. An existing Caddy is used read-only, and its service is never touched.
- To build from source: **LDC2 (`ldc2`) and DUB (`dub`)** with the Microsoft Visual C++ Build Tools.

## Building & testing locally

```powershell
dub build --compiler=ldc2 --build=release
dub test --compiler=ldc2
.\bin\hikari.exe version
.\bin\hikari.exe snapshot --sample-twice
.\bin\hikari.exe hardware
.\tests\integration\windows\test-installer.ps1   # isolated -Root install/repair/uninstall smoke test
```

None of these commands need administrator rights. SMBIOS, CPU topology, SetupAPI device descriptions and physical-disk attribute queries all work for a standard user.

## Installing as machine-wide services

Run from an **elevated Administrator PowerShell** prompt:

```powershell
# Print the plan and run every preflight check without changing anything
.\install\install.ps1 -DryRun

# Install the versioned release, isolated Caddy config, ACLs and both SCM services
.\install\install.ps1 -WinSWBin C:\path\to\WinSW-x64.exe

# Check Tailscale, Caddy, certificates and loopback API health
& 'C:\ProgramData\hikari\versions\current\hikari.exe' doctor
```

The installer prints everything it will change before it changes anything. After the services start, it checks `/healthz` and then confirms that the **service account itself** (not your admin shell) can read local Tailscale status.

### What gets installed

| Item | Location |
|---|---|
| Versioned releases | `C:\ProgramData\hikari\versions\<version>\`, plus a `current` junction and `current.txt` |
| WinSW wrappers, private Caddy | `C:\ProgramData\hikari\bin\` |
| `config.json`, generated `Caddyfile`, service XML | `C:\ProgramData\hikari\config\` |
| Node registry, hardware cache, Caddy certificates | `C:\ProgramData\hikari\state\` |
| Service and install logs | `C:\ProgramData\hikari\logs\` |

**ACLs:** by default, standard users can create files under `ProgramData`. The installer removes that: `ProgramData\hikari` is writable only by SYSTEM and Administrators, so a child account cannot plant or swap binaries that run as a service. `config\` is readable only by SYSTEM, Administrators and the agent account. `state\` and `logs\` are writable by the agent account.

### Services

| Service | Runs | Account | Notes |
|---|---|---|---|
| `hikari` | `versions\current\hikari.exe serve` | `NT AUTHORITY\LocalService` (default) | Listens on loopback only, with `SO_EXCLUSIVEADDRUSE` so no other process can share the port |
| `hikari-caddy` | isolated Caddy | `LocalSystem` | Binds only to the Tailscale IP on port 9100. Delayed auto-start |

Both services start automatically and restart on failure with backoff (5–10 s, then 30 s, then 2 min; the counter resets after 1 h). There are deliberately **no SCM dependencies** on the `Tailscale` service, or between the two hikari services. A dependency would make SCM refuse to stop or upgrade Tailscale while hikari runs. If Caddy starts before the Tailscale address exists, it fails and retries with backoff; it never falls back to binding all interfaces.

The agent swallows `CTRL_LOGOFF_EVENT`, which Windows delivers to service processes whenever *any* user signs out, so signing out never stops monitoring. Ctrl+C/Break from WinSW or a system shutdown stops it cleanly.

### Service accounts and Tailscale access

`LocalService` is the least-privileged built-in account that works:

- It can read SMBIOS, CPU/disk/NIC/GPU inventory, system CPU/memory/network counters and volume usage.
- It **cannot** open processes owned by other users. The *Top processes* lists show only processes it can query, typically services and its own; a child's game will not appear. Processes it cannot open are left out, never shown as zero.
- It needs to run `tailscale status --json`. If the installer warns that the service cannot read Tailscale status, enable Tailscale's **Run unattended** option, or reinstall with `-AgentAccount LocalSystem -Repair`. The second option trades least privilege for full process visibility. hikari never changes Tailscale settings itself.

## Repair, update & uninstall

```powershell
# Reconcile release, generated Caddyfile and service definitions; config.json and state are preserved
.\install\install.ps1 -Repair -WinSWBin C:\path\to\WinSW-x64.exe

# Remove hikari services and binaries, keeping config.json and state\
.\install\uninstall.ps1

# Remove everything, including the node registry, hardware cache and Caddy certificates
.\install\uninstall.ps1 -Purge
```

- Re-running the installer with an identical release is a no-op for binaries. A rebuilt binary with the same version number first stops the hikari services, so a running `.exe` is never overwritten.
- `hikari update apply` stages a verified release into a new version directory and swaps the `current` junction. It builds the new junction aside and renames it into place, so the old pointer comes back on failure. It then restarts only `hikari` and `hikari-caddy` through the Service Control Manager, waiting for each real stop/start. If `/healthz` does not report the new version, it rolls back automatically.
- The installer and uninstaller refuse to modify a service named `hikari` or `hikari-caddy` unless it points at hikari's own wrapper in `C:\ProgramData\hikari\bin\`.

## Data honesty on Windows

- **Memory:** `GlobalMemoryStatusEx` physical RAM, with a separate `commit` object (commit charge/limit). Unix `swap` and `load_1m` stay `null` rather than being mislabeled.
- **Network:** `GetIfTable2` 64-bit counters. NDIS lightweight-filter rows, WAN Miniports, Teredo/ISATAP and the kernel debugger adapter are hidden. The Tailscale (Wintun) adapter is reported as `tailnet`, Hyper-V `vEthernet` switches as `virtual`. Interface IDs use the NET_LUID, which is stable across reboots.
- **Storage:** physical disks come from zero-access `\\.\PhysicalDriveN` attribute queries: model, bus (NVMe/SATA/USB…), SSD/HDD via seek penalty, and capacity. Each disk is mapped to drive letters through volume extents. Serial numbers are never read. Network, optical and RAM-disk volumes are never queried, so they cannot hang the filesystem probe.
- **GPU:** present display adapters come from SetupAPI, with PCI IDs, driver and version, and VRAM when the driver publishes it. Live utilization/temperature comes only from NVML on NVIDIA; other GPUs report `unsupported`, not 0 %.
- **Maintenance:** OS build including UBR; `reboot_required` from the CBS/Windows Update reboot flags. `pending_updates` stays `null`: counting updates would need the Windows Update agent and network access.

## Troubleshooting

- **Port conflict:** the installer stops if another program already uses the loopback or tailnet port. Choose another with `-LoopbackPort` / `-TailnetPort`; hikari never takes over another listener.
- **Dashboard unreachable from other nodes:** check that your Tailscale ACL/grant allows TCP 9100 to this machine. hikari never edits Windows Firewall. If Windows Firewall blocks inbound traffic on the Tailscale interface, add a rule yourself.
- **Logs:** `C:\ProgramData\hikari\logs\` holds `hikari-service.*.log` and `hikari-caddy-service.*.log`, plus `install.log`.
