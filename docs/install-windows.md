# Windows Installation Guide (Stage 2)

This guide covers building, testing, and installing **hikari** on Windows 11 (`x86_64`) as boot-persistent Windows services, so telemetry and hardware cards stay available before anyone logs in, while a standard/child account is signed in, during Fast User Switching, after every user signs out, and after reboot.

## Install a release

Download `hikari-install.ps1` from the [release page](https://github.com/rxwxwwxw/hikari/releases). In Administrator PowerShell:

```powershell
.\hikari-install.ps1 -DryRun
.\hikari-install.ps1 -Reload
```

Python 3.9+ and Ed25519-capable OpenSSL are required. See [bootstrap prerequisites, trust, and options](install-bootstrap.md). No compiler or checkout is needed. Existing compatible Caddy services are reused by default through a verified import and hikari-owned site; reload is explicitly authorized above. Unsafe integration falls back to isolated Caddy. The final report distinguishes **Ready** from **Installed; setup incomplete**.

## Prerequisites

- **Tailscale for Windows**, enrolled in your tailnet, with MagicDNS and HTTPS certificates enabled. Turning on Tailscale's **Run unattended** option is recommended so `tailscaled` is not tied to one interactive user (see [Service accounts](#service-accounts-and-tailscale-access)).
- **Caddy** is optional. If no `caddy.exe` is on `PATH`, a pinned Caddy v2.9.1 is downloaded into `C:\ProgramData\hikari\bin\` and checked against its SHA-512. A compatible existing Caddy service is reused through the verified integration; it is never restarted and reload requires explicit authorization.
- To build from source: **LDC2 (`ldc2`) and DUB (`dub`)** with the Microsoft Visual C++ Build Tools.

For developer builds, see [building from source](building.md).

## Installing as machine-wide services

Run from an **elevated Administrator PowerShell** prompt:

```powershell
# Print the plan and run every preflight check without changing anything
.\install\install.ps1 -DryRun

# Install the versioned release, isolated Caddy config, ACLs and both SCM services
.\install\install.ps1

# Check Tailscale, Caddy, certificates and loopback API health
& 'C:\ProgramData\hikari\versions\current\hikari.exe' doctor
```

The installer prints everything it will change before it changes anything. After the services start, it checks `/healthz` and then confirms that the **service account itself** (not your admin shell) can read local Tailscale status.

### What gets installed

| Item | Location |
|---|---|
| Versioned releases | `C:\ProgramData\hikari\versions\<version>\`, plus a `current` junction and `current.txt` |
| Private Caddy (only if none was found) | `C:\ProgramData\hikari\bin\` |
| `config.json`, generated `Caddyfile` | `C:\ProgramData\hikari\config\` |
| Node registry, hardware cache, Caddy certificates | `C:\ProgramData\hikari\state\` |
| Logs: `hikari.log`, `caddy.log`, `install.log` (size-rotated) | `C:\ProgramData\hikari\logs\` |

**ACLs:** by default, standard users can create files under `ProgramData`. The installer removes that: `ProgramData\hikari` is writable only by SYSTEM and Administrators, so a child account cannot plant or swap binaries that run as a service. `config\` is readable only by SYSTEM, Administrators and the agent service (`NT SERVICE\hikari`). `state\` and `logs\` are writable by that service alone, not by every service that shares a built-in account.

### Services

Both are **native Windows services**; no wrapper program is involved. `hikari.exe` implements the Service Control Manager (SCM) protocol itself when started as `serve --service`, and Caddy has built-in Windows service support. `hikari.exe service install` registers both through the Win32 service APIs.

| Service | Command | Account | Notes |
|---|---|---|---|
| `hikari` | `"…\versions\current\hikari.exe" serve --service --config "…\config.json"` | `NT SERVICE\hikari` (virtual account, default) | Loopback only, with `SO_EXCLUSIVEADDRUSE` so no other process can share the port. Token stripped to `SeChangeNotifyPrivilege` |
| `hikari-caddy` | `"…\caddy.exe" run --config "…\Caddyfile" --adapter caddyfile` | `LocalSystem` | Binds only to the Tailscale IP on port 9100. Delayed auto-start |

- **Startup and recovery:** both start automatically. SCM restarts them after a crash, or after a non-zero exit such as a port conflict, with backoff: 5 s, then 30 s, then 2 min. The failure counter resets after 1 h.
- **No dependencies:** there are deliberately no SCM dependencies on the `Tailscale` service or between the two hikari services. A dependency would make SCM refuse to stop or upgrade Tailscale while hikari runs. If Caddy starts before the Tailscale address exists, it fails and retries with backoff; it never falls back to binding all interfaces.
- **Stop, shutdown, sign-out:** Stop and system shutdown are handled through the SCM control handler: the agent reports `STOP_PENDING`, closes its listener and reports `STOPPED` with exit code 0. The agent also ignores `CTRL_LOGOFF_EVENT`, which Windows sends to service processes whenever *any* user signs out, so signing out never stops monitoring.
- **Sleep/resume:** the agent subscribes to SCM power events. After resume it drops its rate baselines, so the first CPU/network/process rate afterwards is reported as unknown instead of a bogus spike.

Inspect them with standard tools:

```powershell
Get-Service hikari, hikari-caddy
sc.exe qc hikari          # command line, account, start type
sc.exe qfailure hikari    # restart actions
sc.exe qprivs hikari      # SeChangeNotifyPrivilege only
& 'C:\ProgramData\hikari\versions\current\hikari.exe' service status --name hikari
```

### An existing Caddy on Windows

If a Windows service already runs `caddy.exe run --config <Caddyfile>`, the default `-CaddyMode auto` joins it instead of creating `hikari-caddy`, when every safety check passes:
- one marked `import hikari.caddy` block is appended to that Caddyfile, and `hikari.caddy` is written next to it;
- the change is verified with `caddy adapt`, a backup is kept, and the file's ACL is preserved.

Other modes:
- `-CaddyMode integrate` joins or stops before writing anything.
- `-CaddyMode isolated` never touches the existing Caddy.
- `-Reload` reloads it afterwards (`caddy reload` through its admin endpoint); otherwise the command is printed.

Switching modes with `-Repair` reverses the previous choice first, and `uninstall.ps1` restores the Caddyfile byte for byte. Details are in [caddy-integration.md](caddy-integration.md).

### Service accounts and Tailscale access

The agent runs as its own **virtual account**, `NT SERVICE\hikari`. Windows manages it automatically: there is no password and no user profile, and it has no group memberships beyond a normal service. Files are granted to this one service, not to every service that shares `LocalService`.

- It can read SMBIOS, CPU/disk/NIC/GPU inventory, system CPU/memory/network counters and volume usage.
- It **cannot** open processes owned by other users. The *Top processes* lists show only processes it can query; a child's game will not appear. Processes it cannot open are left out, never shown as zero.
- It needs to run `tailscale status --json`. If the installer warns that the service cannot read Tailscale status, enable Tailscale's **Run unattended** option, or reinstall with `-AgentAccount LocalSystem -Repair`. The second option trades least privilege for full process visibility. hikari never changes Tailscale settings itself.

## Repair, update & uninstall

```powershell
# Reconcile release, generated Caddyfile and service definitions; config.json and state are preserved
.\install\install.ps1 -Repair

# Remove hikari services and binaries, keeping config.json and state\
.\install\uninstall.ps1

# Remove everything, including the node registry, hardware cache and Caddy certificates
.\install\uninstall.ps1 -Purge
```

- **Idempotent reinstall:** re-running the installer with an identical release changes nothing, and running services are left alone. A rebuilt binary with the same version number first stops the hikari services, so a running `.exe` is never overwritten. A changed service definition or Caddyfile restarts only the affected service.
- **Updates:** `hikari update apply` stages a verified release into a new version directory and swaps the `current` junction. It builds the new junction aside and renames it into place, so the old pointer comes back on failure. It then restarts only `hikari` and `hikari-caddy` through the SCM, waiting for each real stop/start. If `/healthz` does not report the new version, it rolls back automatically.
- **Ownership:** hikari only modifies or removes a service named `hikari` / `hikari-caddy` if its command line is the exact shape hikari registers *and* points at this installation's own config file or Caddyfile. Anything else is refused and left untouched.
- **Migration from WinSW:** installs made with the earlier WinSW-based installer are converted automatically on the next `install.ps1 -Repair`. The wrapper services are removed and native ones registered; config and state are kept.

## Data honesty on Windows

- **Memory:** `GlobalMemoryStatusEx` physical RAM, with a separate `commit` object (commit charge/limit). Unix `swap` and `load_1m` stay `null` rather than being mislabeled.
- **Network:** `GetIfTable2` 64-bit counters. NDIS lightweight-filter rows, WAN Miniports, Teredo/ISATAP and the kernel debugger adapter are hidden. The Tailscale (Wintun) adapter is reported as `tailnet`, Hyper-V `vEthernet` switches as `virtual`. Interface IDs use the NET_LUID, which is stable across reboots.
- **Storage:** physical disks come from zero-access `\\.\PhysicalDriveN` attribute queries: model, bus (NVMe/SATA/USB…), SSD/HDD via seek penalty, and capacity. Each disk is mapped to drive letters through volume extents. Serial numbers are never read. Network, optical and RAM-disk volumes are never queried, so they cannot hang the filesystem probe.
- **GPU:** present display adapters come from SetupAPI, with PCI IDs, driver and version, and VRAM when the driver publishes it. Live utilization/temperature comes only from NVML on NVIDIA; other GPUs report `unsupported`, not 0 %.
- **Maintenance:** OS build including UBR; `reboot_required` from the CBS/Windows Update reboot flags. `pending_updates` stays `null`: counting updates would need the Windows Update agent and network access.

## Troubleshooting

- **Port conflict:** the installer stops if another program already uses the loopback or tailnet port. Choose another with `-LoopbackPort` / `-TailnetPort`; hikari never takes over another listener.
- **Dashboard unreachable from other nodes:** check that your Tailscale ACL/grant allows TCP 9100 to this machine. hikari never edits Windows Firewall. If Windows Firewall blocks inbound traffic on the Tailscale interface, add a rule yourself.
- **Logs:** `C:\ProgramData\hikari\logs\` holds `hikari.log` (agent), `caddy.log` (isolated Caddy) and `install.log`. Agent and Caddy logs rotate at 1 MiB and keep 3 old files.
- **Service won't start:** run `sc.exe query hikari`. A `SERVICE_SPECIFIC_EXIT_CODE` of 1 means a port conflict, and 3 means an invalid config. Details are in `hikari.log`. Running `hikari serve --service` from a terminal prints a reminder that this mode is only for the SCM; use `hikari serve` to run in the foreground.
