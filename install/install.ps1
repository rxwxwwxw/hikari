<#
.SYNOPSIS
Idempotent machine-wide Windows installer for hikari (Stage 2).

.DESCRIPTION
Registers two Service Control Manager services, `hikari` (loopback telemetry agent) and
`hikari-caddy` (isolated HTTPS proxy bound to the Tailscale address). Both are native
services: hikari.exe implements the SCM protocol itself and Caddy supports it natively, so
no wrapper binary is involved. Services start at boot and keep running with no user signed in, during Fast User Switching and
after every user signs out.

Caddy modes (-CaddyMode, default from config.json `caddy.mode`, else auto):
  auto       join an existing Caddy service when every safety check passes (one marked
             import line + a hikari-owned site file, verified with `caddy adapt`), otherwise
             run the isolated hikari-caddy service
  integrate  join an existing Caddy or fail before changing anything
  isolated   always run the isolated hikari-caddy; never touch an existing Caddy
  snippet    only write an importable snippet (same as -SnippetOnly)
An existing Caddy is reloaded only with -Reload; otherwise the exact command is printed.

Guarantees:
  * Prints the full plan before changing anything; -DryRun changes nothing.
  * Never modifies Tailscale, IIS, firewall rules, or any pre-existing Caddy service.
  * Never overwrites a running executable: hikari-owned services are stopped first.
  * Refuses to touch a service named hikari/hikari-caddy that it does not own.
  * Preserves config.json, nodes.json, the hardware cache and Caddy certificates.
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$Repair,
    [switch]$SnippetOnly,
    [ValidateSet("", "auto", "integrate", "isolated", "snippet")]
    [string]$CaddyMode = "",
    [switch]$Reload,
    # Point at a specific existing Caddyfile/binary instead of detecting the Caddy service
    # (also the only way integration is considered under -Root, so tests never touch a real Caddy).
    [string]$ExistingCaddyfile = "",
    [string]$ExistingCaddyBin = "",
    [ValidateSet("auto", "private", "existing")]
    [string]$CaddySource = "auto",
    [int]$TailnetPort = 9100,
    [int]$LoopbackPort = 19100,
    [string]$BasePath = "/",
    [string]$Root = "",
    [string]$BinarySource = "",
    [string]$CaddyBin = "",
    [string]$TailscaleFixture = "",
    [ValidateSet("auto", "skip")]
    [string]$ServiceMode = "auto",
    # Per-service virtual account (NT SERVICE\hikari) by default: no password, no privileges
    # beyond traverse checking, and file access granted to this service alone. LocalSystem
    # adds visibility of other users' processes at the cost of least privilege.
    [ValidateSet("Virtual", "LocalSystem")]
    [string]$AgentAccount = "Virtual",
    [string]$Repo = "OWNER/REPO",
    [string]$PubKey = "",
    [string]$Manifest = "",
    [string]$Signature = ""
)

$ErrorActionPreference = "Stop"
if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
    throw "Python 3.9+ is required for release verification and readiness checks; install it and rerun."
}
& python -c "import sys; sys.exit(0 if sys.version_info >= (3,9) else 1)"
if ($LASTEXITCODE -ne 0) { throw "Python 3.9+ is required; install it and rerun." }

$CaddyPinnedVersion = "2.9.1"
# Official Caddy v2.9.1 windows_amd64.zip SHA-512 from caddy_2.9.1_checksums.txt
$CaddySha512WinAmd64 = "4f0f85b42015ff2276d08705751472e6a98bdc7fda5ec76dd41b7a0c16fee90af012f1a7beb226164408cfbe656bd3453ed5ccbb596f80c45d0fa1c749fc8da2"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $ScriptDir

$ProgramDataBase = if ($Root) { Join-Path $Root "ProgramData\hikari" } else { "C:\ProgramData\hikari" }
$VersionsDir = Join-Path $ProgramDataBase "versions"
$PrivateBinDir = Join-Path $ProgramDataBase "bin"
$ConfigDir = Join-Path $ProgramDataBase "config"
$StateDir = Join-Path $ProgramDataBase "state"
$LogsDir = Join-Path $ProgramDataBase "logs"
$LogFile = Join-Path $LogsDir "install.log"
$ConfigPath = Join-Path $ConfigDir "config.json"
$CaddyfilePath = Join-Path $ConfigDir "Caddyfile"
$CurrentJunction = Join-Path $VersionsDir "current"
$ManageServices = ($ServiceMode -eq "auto") -and (-not $Root)

function Write-Log([string]$Message) {
    $line = "[{0}] {1}" -f (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ"), $Message
    Write-Host $line
    if (-not $DryRun) {
        if (-not (Test-Path $LogsDir)) { New-Item -ItemType Directory -Force -Path $LogsDir | Out-Null }
        Add-Content -Path $LogFile -Value $line
    }
}

function Write-Utf8NoBom([string]$Path, [string]$Text) {
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

function Test-SameFile([string]$A, [string]$B) {
    if (-not (Test-Path $A) -or -not (Test-Path $B)) { return $false }
    return (Get-FileHash -Algorithm SHA256 $A).Hash -eq (Get-FileHash -Algorithm SHA256 $B).Hash
}

# ---------------------------------------------------------------------------
# 1. Preflight (read-only)
# ---------------------------------------------------------------------------
if ($ManageServices -and -not $DryRun) {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "System service installation requires an elevated Administrator PowerShell session (or pass -DryRun / -Root / -ServiceMode skip)."
    }
}
if ($PSVersionTable.PSVersion.Major -lt 5) { throw "PowerShell 5.1 or newer is required." }
if (-not $Root -and $env:PROCESSOR_ARCHITECTURE -ne "AMD64") {
    throw "Unsupported architecture '$env:PROCESSOR_ARCHITECTURE'. Windows x86-64 is the only tested target."
}
if ($TailnetPort -lt 1 -or $TailnetPort -gt 65535) { throw "Invalid TailnetPort: $TailnetPort" }
if ($LoopbackPort -lt 1 -or $LoopbackPort -gt 65535) { throw "Invalid LoopbackPort: $LoopbackPort" }

# Existing operator config wins over parameters for ports/base path.
if (Test-Path $ConfigPath) {
    try {
        $existingCfg = Get-Content -Raw $ConfigPath | ConvertFrom-Json
        if ($existingCfg.listen.loopback_port) { $LoopbackPort = [int]$existingCfg.listen.loopback_port }
        if ($existingCfg.listen.tailnet_port) { $TailnetPort = [int]$existingCfg.listen.tailnet_port }
        if ($existingCfg.listen.base_path) { $BasePath = [string]$existingCfg.listen.base_path }
    } catch {
        throw "Existing $ConfigPath is not valid JSON; fix or move it aside before re-running (it is never overwritten)."
    }
}

# Effective Caddy mode: explicit flag > operator config > auto.
$EffectiveCaddyMode = "auto"
$EffectiveReload = [bool]$Reload
if ($existingCfg -and $existingCfg.caddy) {
    if ($existingCfg.caddy.mode) { $EffectiveCaddyMode = [string]$existingCfg.caddy.mode }
    if ($existingCfg.caddy.reload) { $EffectiveReload = $true }
}
if ($CaddyMode) { $EffectiveCaddyMode = $CaddyMode }
if ($SnippetOnly) { $EffectiveCaddyMode = "snippet" }
$SnippetOnly = ($EffectiveCaddyMode -eq "snippet")
if ($existingCfg -and $existingCfg.paths -and $existingCfg.paths.state_dir -and -not $Root) { $StateDir = [string]$existingCfg.paths.state_dir }
$IntegrationRecord = Join-Path $StateDir "caddy-integration.json"
$WasIntegrated = Test-Path $IntegrationRecord

if (-not $BinarySource) {
    $cand = Join-Path $RepoRoot "bin\hikari.exe"
    if (Test-Path $cand) { $BinarySource = $cand }
}
if (-not $BinarySource -or -not (Test-Path $BinarySource)) {
    throw "hikari.exe binary not found. Pass -BinarySource <path> or build with dub build --compiler=ldc2 --build=release."
}

# Classify existing services named hikari/hikari-caddy:
#   native  - registered by this installation (hikari.exe serve --service / Caddy with our Caddyfile)
#   legacy  - an earlier hikari install that used the WinSW wrapper (migrated below)
#   foreign - anything else: never touched
function Get-ServiceOwnership([string]$Name) {
    $svc = Get-CimInstance Win32_Service -Filter "Name='$Name'" -ErrorAction SilentlyContinue
    if (-not $svc) { return "absent" }
    $p = [string]$svc.PathName
    if ($p -like "*$(Join-Path $PrivateBinDir "$Name-service.exe")*") { return "legacy" }
    if ($Name -eq "hikari" -and $p -like "*\hikari.exe*serve --service --config*" -and $p -like "*$ConfigPath*") { return "native" }
    if ($Name -eq "hikari-caddy" -and $p -like "* run --config *" -and $p -like "*$CaddyfilePath*") { return "native" }
    return "foreign"
}
$OwnedServices = @{}
$LegacyServices = @()
foreach ($svcName in $(if ($ManageServices) { @("hikari", "hikari-caddy") } else { @() })) {
    $own = Get-ServiceOwnership $svcName
    if ($own -eq "foreign") {
        $pn = (Get-CimInstance Win32_Service -Filter "Name='$svcName'").PathName
        throw "A service named '$svcName' already exists and is not managed by hikari ($pn). Refusing to modify it."
    }
    if ($own -ne "absent") { $OwnedServices[$svcName] = Get-CimInstance Win32_Service -Filter "Name='$svcName'" }
    if ($own -eq "legacy") { $LegacyServices += $svcName }
}

# Read-only Tailscale status (prefer the standard install path; services may lack PATH).
$TsCli = Join-Path $env:ProgramFiles "Tailscale\tailscale.exe"
if (-not (Test-Path $TsCli)) {
    $cmd = Get-Command tailscale -ErrorAction SilentlyContinue
    $TsCli = if ($cmd) { $cmd.Source } else { "" }
}
$TsJsonText = ""
if ($TailscaleFixture) {
    if (-not (Test-Path $TailscaleFixture)) { throw "Tailscale fixture not found: $TailscaleFixture" }
    $TsJsonText = Get-Content -Raw -Path $TailscaleFixture
} elseif ($TsCli) {
    try { $TsJsonText = (& $TsCli status --json 2>$null) -join "`n" } catch {}
}
$TsFqdn = ""
$TsIp = ""
if ($TsJsonText) {
    try {
        $tsObj = $TsJsonText | ConvertFrom-Json
        if ($tsObj.Self) {
            if ($tsObj.Self.DNSName) { $TsFqdn = ($tsObj.Self.DNSName).TrimEnd('.') }
            $v4 = @($tsObj.Self.TailscaleIPs | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' })
            if ($v4.Count -gt 0) { $TsIp = $v4[0] } elseif ($tsObj.Self.TailscaleIPs) { $TsIp = @($tsObj.Self.TailscaleIPs)[0] }
        }
    } catch {}
}
$TsServicePresent = [bool](Get-Service -Name "Tailscale" -ErrorAction SilentlyContinue)

function Test-TcpPortInUse([int]$Port) {
    try {
        $listeners = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners()
        return @($listeners | Where-Object { $_.Port -eq $Port }).Count -gt 0
    } catch {
        return $false
    }
}
# Run hikari's own read-only analysis of any existing Caddy (no changes anywhere).
function Invoke-Native([string]$Exe, [string[]]$NArgs) {
    $ErrorActionPreference = "Continue"
    $o = (& $Exe @NArgs 2>&1 | ForEach-Object { "$_" }) -join "`n"
    return @{ Code = $LASTEXITCODE; Out = $o }
}
# Verify archives before executing even the read-only probe binary.
function Get-VerifiedRelease([string]$Destination = "") {
    if (-not $Manifest -or -not $Signature -or -not $PubKey -or $Repo -eq "OWNER/REPO") {
        throw "ZIP installation requires -Manifest, -Signature, -Repo and a trusted -PubKey."
    }
    $verifyArgs = @((Join-Path $ScriptDir "verify-release.py"), "--archive", $BinarySource,
        "--manifest", $Manifest, "--signature", $Signature, "--public-key", $PubKey,
        "--repo", $Repo, "--os", "windows", "--arch", "x86_64")
    if ($Destination) { $verifyArgs += @("--extract-dir", $Destination) }
    $version = & python @verifyArgs
    if ($LASTEXITCODE -ne 0) { throw "Release verification failed; nothing from this archive will be executed." }
    return "$version".Trim()
}
$VerifiedVersion = ""
$ProbeExe = $BinarySource
$ProbeDir = ""
if ($BinarySource -like "*.zip") {
    $ProbeDir = Join-Path $env:TEMP ("hikari-probe-" + [guid]::NewGuid().ToString("N"))
    $VerifiedVersion = Get-VerifiedRelease $ProbeDir
    $ProbeExe = Join-Path $ProbeDir "hikari.exe"
}
$CaddyDecision = "isolated"
$CaddyDecisionReason = ""
$IntegrateCaddyfile = ""
if ($EffectiveCaddyMode -eq "auto" -or $EffectiveCaddyMode -eq "integrate") {
    if ($Root -and -not $ExistingCaddyfile) {
        $CaddyDecisionReason = "existing-Caddy detection is disabled under -Root (pass -ExistingCaddyfile to test integration)"
    } else {
        $inspectArgs = @("caddy", "inspect", "--verdict", "--config", $ConfigPath, "--state-dir", $StateDir, "--port", "$TailnetPort")
        if ($TsFqdn) { $inspectArgs += @("--fqdn", $TsFqdn) }
        if ($TsIp) { $inspectArgs += @("--tailscale-ip", $TsIp) }
        if ($ExistingCaddyfile) { $inspectArgs += @("--caddyfile", $ExistingCaddyfile) }
        if ($ExistingCaddyBin) { $inspectArgs += @("--caddy", $ExistingCaddyBin) }
        $v = Invoke-Native $ProbeExe $inspectArgs
        $line = ($v.Out -split "`n" | Where-Object { $_ -match '^(integrate |isolated:)' } | Select-Object -First 1)
        if ($line -and $line.StartsWith("integrate ")) {
            $CaddyDecision = "integrate"
            $IntegrateCaddyfile = $line.Substring(10).Trim()
        } else {
            $CaddyDecisionReason = if ($line) { ($line -replace '^isolated:\s*', '') } else { "inspection failed: $($v.Out)" }
        }
    }
    if ($EffectiveCaddyMode -eq "integrate" -and $CaddyDecision -ne "integrate") {
        throw "-CaddyMode integrate: cannot join the existing Caddy ($CaddyDecisionReason). Nothing was changed."
    }
} elseif ($EffectiveCaddyMode -eq "isolated") {
    $CaddyDecisionReason = "caddy mode is 'isolated'"
}
if ($ProbeDir) { Remove-Item -Recurse -Force $ProbeDir -ErrorAction SilentlyContinue }

# Ports held by our own running services are expected on reinstall.
$OurAgentRunning = $OwnedServices.ContainsKey("hikari") -and $OwnedServices["hikari"].State -eq "Running"
$OurCaddyRunning = $OwnedServices.ContainsKey("hikari-caddy") -and $OwnedServices["hikari-caddy"].State -eq "Running"
if (-not $Repair) {
    if (-not $OurAgentRunning -and (Test-TcpPortInUse $LoopbackPort)) {
        throw "Port conflict: loopback port $LoopbackPort is already used by another program. Re-run with -LoopbackPort <free port>."
    }
    if (-not $SnippetOnly -and $CaddyDecision -eq "isolated" -and -not $OurCaddyRunning -and (Test-TcpPortInUse $TailnetPort)) {
        throw "Port conflict: tailnet port $TailnetPort is already used by another program. Re-run with -TailnetPort <free port>."
    }
}

# Caddy binary for the isolated instance (an existing Caddy binary is used read-only; its
# service is never touched).
$ResolvedCaddy = ""
$CaddyOrigin = "none"
$NeedCaddyDownload = $false
function Resolve-IsolatedCaddy {
    if ($CaddyBin -and (Test-Path $CaddyBin)) {
        $script:ResolvedCaddy = $CaddyBin; $script:CaddyOrigin = "explicit"
    } elseif ($CaddySource -ne "private" -and (Get-Command caddy.exe -ErrorAction SilentlyContinue)) {
        $script:ResolvedCaddy = (Get-Command caddy.exe).Source; $script:CaddyOrigin = "existing_readonly"
    } elseif ($CaddySource -eq "existing") {
        throw "No existing caddy.exe found on PATH (-CaddySource existing)."
    } else {
        $script:ResolvedCaddy = Join-Path $PrivateBinDir "caddy.exe"; $script:CaddyOrigin = "private"
        $script:NeedCaddyDownload = -not (Test-Path $script:ResolvedCaddy)
    }
}
if (-not $SnippetOnly -and $CaddyDecision -eq "isolated") { Resolve-IsolatedCaddy }

$AppVersion = if ($VerifiedVersion) { $VerifiedVersion } elseif (Test-Path (Join-Path $RepoRoot "VERSION")) { (Get-Content -Raw (Join-Path $RepoRoot "VERSION")).Trim() } else { "0.1.0" }

# Fail before writes when the maintenance task name belongs to someone else.
if ($ManageServices) {
    $taskBeforeInstall = Get-ScheduledTask -TaskName "hikari-maintenance" -ErrorAction SilentlyContinue
    if ($taskBeforeInstall -and ($taskBeforeInstall.Description -ne "hikari-owned maintenance" -or
            @($taskBeforeInstall.Actions).Count -ne 1 -or
            $taskBeforeInstall.Actions[0].Execute -ne (Join-Path $CurrentJunction "hikari.exe") -or
            $taskBeforeInstall.Actions[0].Arguments -ne "update maintain --config `"$ConfigPath`"")) {
        throw "Refusing to replace a foreign hikari-maintenance task"
    }
}

Write-Host "=== hikari Windows install plan ==="
Write-Host "  Maintenance:      hikari-maintenance scheduled task (SYSTEM), local eligibility every 5 min; network only when update policy permits."
Write-Host "  Version:          $AppVersion -> $VersionsDir\$AppVersion (versions\current junction)"
Write-Host "  Config / state:   $ConfigDir (config.json preserved if present) / $StateDir"
Write-Host "  Ports:            tailnet=$TailnetPort loopback=127.0.0.1:$LoopbackPort base_path=$BasePath"
if ($SnippetOnly) {
    Write-Host "  Caddy:            snippet only (written to $ConfigDir; nothing imported or reloaded)"
} elseif ($CaddyDecision -eq "integrate") {
    Write-Host "  Caddy:            join existing Caddy: append one marked import line to $IntegrateCaddyfile + hikari-owned site file (verified with caddy adapt, backup kept)"
    Write-Host "                    reload: $(if ($EffectiveReload) { 'yes (rolled back if the reload fails)' } else { 'no - the exact reload command is printed' })"
    if ($OwnedServices.ContainsKey("hikari-caddy")) { Write-Host "                    the isolated hikari-caddy service will be removed (its port moves to the existing Caddy)" }
} else {
    Write-Host "  Caddy:            isolated hikari-caddy$(if ($CaddyDecisionReason) { " ($CaddyDecisionReason)" })"
    Write-Host "  Caddy binary:     $(if ($ResolvedCaddy) { $ResolvedCaddy } else { '<none>' }) ($CaddyOrigin$(if ($NeedCaddyDownload) { ', will download pinned v' + $CaddyPinnedVersion }))"
    if ($WasIntegrated) { Write-Host "                    hikari's block will first be removed from the previously joined Caddy (restored byte for byte)" }
}
Write-Host "  Tailscale:        FQDN=$(if ($TsFqdn) { $TsFqdn } else { '<unavailable>' }) IP=$(if ($TsIp) { $TsIp } else { '<none>' }) service=$(if ($TsServicePresent) { 'present' } else { 'absent' })"
Write-Host "  Services:         $(if ($ManageServices) { "native SCM: hikari ($(if ($AgentAccount -eq 'Virtual') { 'NT SERVICE\hikari' } else { 'LocalSystem' }))$(if (-not $SnippetOnly -and $CaddyDecision -eq 'isolated') { ', hikari-caddy (LocalSystem)' })" } else { 'not managed (-Root or -ServiceMode skip)' })"
if ($LegacyServices.Count -gt 0) {
    Write-Host "  Migration:        replace WinSW-wrapped $($LegacyServices -join ', ') with native services (config/state kept)"
}
Write-Host "  ACLs:             $(if ($Root) { 'skipped (-Root)' } else { 'restrict ProgramData\hikari to SYSTEM/Administrators; agent service gets config read + state/logs write' })"
Write-Host "  Not modified:     Tailscale, firewall, IIS, any other service$(if ($CaddyDecision -ne 'integrate') { ', any other Caddy' })"
if ($ManageServices -and -not $TsServicePresent) {
    Write-Host "  WARNING: Tailscale service not found. hikari-caddy will retry with backoff until Tailscale is installed and up."
}

if ($DryRun) {
    Write-Host "[dry-run] Preflight succeeded; no changes written."
    exit 0
}

# ---------------------------------------------------------------------------
# 2. Directories and ACLs
# ---------------------------------------------------------------------------
New-Item -ItemType Directory -Force -Path $VersionsDir, $PrivateBinDir, $ConfigDir, (Join-Path $StateDir "caddy"), $LogsDir | Out-Null

# Well-known SIDs (locale independent).
$S_SYSTEM = "*S-1-5-18"; $S_ADMINS = "*S-1-5-32-544"; $S_USERS = "*S-1-5-32-545"
function Set-Acl-Strict([string]$Path, [string[]]$Grants) {
    $icaclsArgs = @($Path, "/inheritance:r", "/grant:r") + $Grants
    & icacls.exe @icaclsArgs | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "icacls failed for $Path" }
}
if (-not $Root) {
    # Default ProgramData lets standard users create files; a child account must not be able
    # to plant or replace binaries that run as a service.
    Set-Acl-Strict $ProgramDataBase @("${S_SYSTEM}:(OI)(CI)F", "${S_ADMINS}:(OI)(CI)F", "${S_USERS}:(OI)(CI)RX")
    Set-Acl-Strict $ConfigDir @("${S_SYSTEM}:(OI)(CI)F", "${S_ADMINS}:(OI)(CI)F")
    Set-Acl-Strict $StateDir @("${S_SYSTEM}:(OI)(CI)F", "${S_ADMINS}:(OI)(CI)F")
    Set-Acl-Strict $LogsDir @("${S_SYSTEM}:(OI)(CI)F", "${S_ADMINS}:(OI)(CI)F")
    Write-Log "Applied restricted ACLs under $ProgramDataBase"
}

# ---------------------------------------------------------------------------
# 3. Helper downloads (verified before use)
# ---------------------------------------------------------------------------
function Install-PrivateCaddyIfNeeded {
    if (-not $script:NeedCaddyDownload) { return }
    $url = "https://github.com/caddyserver/caddy/releases/download/v$CaddyPinnedVersion/caddy_${CaddyPinnedVersion}_windows_amd64.zip"
    $dlDir = Join-Path $env:TEMP ("hikari-caddy-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force -Path $dlDir | Out-Null
    try {
        $tmpZip = Join-Path $dlDir "caddy.zip"
        Write-Log "Downloading pinned Caddy v$CaddyPinnedVersion..."
        Invoke-WebRequest -Uri $url -OutFile $tmpZip -UseBasicParsing
        $hash = (Get-FileHash -Path $tmpZip -Algorithm SHA512).Hash.ToLower()
        if ($hash -ne $CaddySha512WinAmd64) { throw "Caddy checksum mismatch! expected=$CaddySha512WinAmd64 actual=$hash" }
        Expand-Archive -Path $tmpZip -DestinationPath (Join-Path $dlDir "x") -Force
        Copy-Item (Join-Path $dlDir "x\caddy.exe") $script:ResolvedCaddy -Force
        $script:NeedCaddyDownload = $false
        Write-Log "Installed verified private Caddy at $($script:ResolvedCaddy)"
    } finally {
        Remove-Item -Recurse -Force $dlDir -ErrorAction SilentlyContinue
    }
}
Install-PrivateCaddyIfNeeded

# ---------------------------------------------------------------------------
# 4. Service helpers (hikari-owned services only)
# ---------------------------------------------------------------------------
$StoppedForUpgrade = @()
function Stop-OwnedService([string]$Name) {
    if (-not $OwnedServices.ContainsKey($Name)) { return }
    $s = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if ($s -and $s.Status -ne "Stopped") {
        Write-Log "Stopping $Name before replacing its files"
        Stop-Service -Name $Name -Force
        $s.WaitForStatus("Stopped", [TimeSpan]::FromSeconds(30))
        $script:StoppedForUpgrade += $Name
    }
}

# Migrate WinSW-wrapped services from earlier hikari installs (config and state untouched).
foreach ($n in $LegacyServices) {
    $wrapper = Join-Path $PrivateBinDir "$n-service.exe"
    Stop-OwnedService $n
    if (Test-Path $wrapper) { & $wrapper uninstall | Out-Null } else { & sc.exe delete $n | Out-Null }
    foreach ($f in @("$n-service.exe", "$n-service.xml")) { Remove-Item -Force (Join-Path $PrivateBinDir $f) -ErrorAction SilentlyContinue }
    Remove-Item -Force (Join-Path $ConfigDir "$n-service.xml") -ErrorAction SilentlyContinue
    $OwnedServices.Remove($n)
    $StoppedForUpgrade = @($StoppedForUpgrade | Where-Object { $_ -ne $n })
    Write-Log "Removed legacy WinSW wrapper for $n"
}
if ($LegacyServices.Count -gt 0) { Remove-Item -Force (Join-Path $PrivateBinDir "winsw.exe") -ErrorAction SilentlyContinue }

# ---------------------------------------------------------------------------
# 5. Versioned release (never overwrite a running executable)
# ---------------------------------------------------------------------------
$RelDir = Join-Path $VersionsDir $AppVersion
$StageDir = Join-Path $VersionsDir ".install-tmp-$AppVersion"
if (Test-Path $StageDir) { Remove-Item -Recurse -Force $StageDir }
New-Item -ItemType Directory -Force -Path (Join-Path $StageDir "web"), (Join-Path $StageDir "caddy") | Out-Null

if ($BinarySource -like "*.zip") {
    $stagedVersion = Get-VerifiedRelease $StageDir
    if ($stagedVersion -ne $AppVersion) { throw "Release changed during installation; refusing activation." }
} else {
    Copy-Item -Path $BinarySource -Destination (Join-Path $StageDir "hikari.exe") -Force
    Copy-Item -Path (Join-Path $RepoRoot "web\index.html") -Destination (Join-Path $StageDir "web\index.html") -Force
    Copy-Item -Path (Join-Path $RepoRoot "caddy\Caddyfile.tmpl") -Destination (Join-Path $StageDir "caddy\Caddyfile.tmpl") -Force
    Copy-Item -Path (Join-Path $RepoRoot "caddy\snippet.caddy.tmpl") -Destination (Join-Path $StageDir "caddy\snippet.caddy.tmpl") -Force
    Copy-Item -Path (Join-Path $RepoRoot "VERSION") -Destination (Join-Path $StageDir "VERSION") -Force
}
if (-not (Test-Path (Join-Path $StageDir "hikari.exe"))) { throw "Release payload is missing hikari.exe" }

$unchanged = (Test-SameFile (Join-Path $StageDir "hikari.exe") (Join-Path $RelDir "hikari.exe")) -and
             (Test-SameFile (Join-Path $StageDir "web\index.html") (Join-Path $RelDir "web\index.html")) -and
             (Test-SameFile (Join-Path $StageDir "caddy\Caddyfile.tmpl") (Join-Path $RelDir "caddy\Caddyfile.tmpl"))
if ($unchanged) {
    Remove-Item -Recurse -Force $StageDir
    Write-Log "Release $AppVersion already installed and identical; leaving it in place"
} else {
    if (Test-Path $RelDir) {
        # Same version, different bits (developer rebuild): the running agent may be using it.
        Stop-OwnedService "hikari-caddy"
        Stop-OwnedService "hikari"
        Remove-Item -Recurse -Force $RelDir
    }
    Move-Item -Path $StageDir -Destination $RelDir
    Write-Log "Installed hikari $AppVersion to $RelDir"
}

function Set-VersionPointer([string]$Name, [string]$Version) {
    # Same swap protocol as update/activate.d: build aside, rename into place, pointer text last.
    $link = Join-Path $VersionsDir $Name
    $tmp = "$link.new"; $old = "$link.old"
    foreach ($p in @($tmp, $old)) { if (Test-Path $p) { cmd /c rmdir /q "$p" 2>$null | Out-Null } }
    cmd /c mklink /J "$tmp" (Join-Path $VersionsDir $Version) | Out-Null
    if (-not (Test-Path $tmp)) { throw "Failed to create junction $tmp" }
    if (Test-Path $link) {
        Rename-Item -Path $link -NewName (Split-Path -Leaf $old)
        try { Rename-Item -Path $tmp -NewName (Split-Path -Leaf $link) }
        catch { Rename-Item -Path $old -NewName (Split-Path -Leaf $link); throw }
        cmd /c rmdir /q "$old" 2>$null | Out-Null  # removes the junction only, never its target
    } else {
        Rename-Item -Path $tmp -NewName (Split-Path -Leaf $link)
    }
    Set-Content -Path "$link.txt" -Value $Version
}

$CurTxt = Join-Path $VersionsDir "current.txt"
$oldVer = if (Test-Path $CurTxt) { (Get-Content -Raw $CurTxt).Trim() } else { "" }
if ($oldVer -ne $AppVersion -or -not (Test-Path $CurrentJunction)) {
    if ($oldVer -and $oldVer -ne $AppVersion -and (Test-Path (Join-Path $VersionsDir $oldVer))) {
        Set-VersionPointer "previous" $oldVer
    }
    Set-VersionPointer "current" $AppVersion
    Write-Log "Activated versions\current -> $AppVersion"
}

# ---------------------------------------------------------------------------
# 6. Configuration (created once, never overwritten)
# ---------------------------------------------------------------------------
if (-not (Test-Path $ConfigPath)) {
    if ($PubKey) {
        # Persist the key bytes, not a bootstrap temporary path that will disappear.
        $PubKey = Get-Content -Raw -LiteralPath $PubKey
    }
    $cfgObj = @{
        schema_version = 1
        listen = @{
            tailnet_port = $TailnetPort
            loopback_port = $LoopbackPort
            loopback_bind = "127.0.0.1"
            base_path = $BasePath
        }
        collection = @{
            ttl_seconds = @{ fast = 10; processes = 20; device_dynamic = 60; filesystems = 120; tailnet = 300; maintenance = 43200; hardware = 604800 }
            max_stale_seconds = @{ fast = 60; processes = 120; device_dynamic = 600; filesystems = 1200; tailnet = 3600; maintenance = 604800; hardware = 2592000 }
            cold_wait_ms = 2000
            probe_timeout_ms = 5000
        }
        discovery = @{ enabled_on_dashboard_open = $true; max_concurrent_probes = 4; probe_timeout_ms = 3000 }
        updates = @{ repo = $Repo; mode = "on_dashboard_open"; auto_install_verified = $true; check_interval_hours = 24; public_key = $PubKey; channel = "stable" }
        privacy = @{ expose_serials = $false; expose_mac_addresses = $false }
        caddy = @{ mode = $EffectiveCaddyMode; reload = [bool]$EffectiveReload }
        paths = @{
            state_dir = $StateDir
            config_dir = $ConfigDir
            versions_dir = $VersionsDir
            web_dir = (Join-Path $CurrentJunction "web")
        }
    }
    # UTF-8 without BOM (Windows PowerShell's -Encoding UTF8 writes a BOM).
    Write-Utf8NoBom $ConfigPath ($cfgObj | ConvertTo-Json -Depth 6)
    Write-Log "Created initial configuration at $ConfigPath"
} else {
    Write-Log "Preserved existing operator configuration at $ConfigPath"
}

# Seed the agent's last-known MagicDNS name (hikari-owned state). The agent uses it
# for Host validation whenever it cannot read `tailscale status` itself, e.g. as
# NT SERVICE\hikari without Tailscale's "Run unattended"; it refreshes it on its own.
if ($TsFqdn -match '^[A-Za-z0-9.-]+$') {
    Write-Utf8NoBom (Join-Path $StateDir "local_fqdn") ($TsFqdn + "`n")
}

# ---------------------------------------------------------------------------
# 7. Generated Caddy config (hikari-owned files only)
# ---------------------------------------------------------------------------
$InstalledExe = Join-Path $CurrentJunction "hikari.exe"
$CaddyfileChanged = $false
$Integrated = $false
$ReloadHint = ""

function Invoke-HikariJson([string[]]$HArgs) {
    $r = Invoke-Native $InstalledExe $HArgs
    $start = $r.Out.IndexOf("{")
    if ($start -lt 0) { throw "hikari $($HArgs -join ' ') returned no JSON: $($r.Out)" }
    return ($r.Out.Substring($start) | ConvertFrom-Json)
}

if (-not $SnippetOnly -and $CaddyDecision -eq "integrate") {
    $intArgs = @("caddy", "integrate", "--config", $ConfigPath, "--state-dir", $StateDir, "--port", "$TailnetPort", "--json")
    if ($TsFqdn) { $intArgs += @("--fqdn", $TsFqdn) }
    if ($TsIp) { $intArgs += @("--tailscale-ip", $TsIp) }
    if ($IntegrateCaddyfile) { $intArgs += @("--caddyfile", $IntegrateCaddyfile) }
    if ($ExistingCaddyBin) { $intArgs += @("--caddy", $ExistingCaddyBin) }
    $res = Invoke-HikariJson $intArgs
    if ($res.ok) {
        $Integrated = $true
        $ReloadHint = [string]$res.reload
        Write-Log "Joined existing Caddy: $($res.message)$(if ($res.backup) { "; backup $($res.backup)" })"
    } elseif ($EffectiveCaddyMode -eq "integrate") {
        throw "Could not join the existing Caddy: $($res.message) $(@($res.problems) -join '; ')"
    } else {
        Write-Log "Not joining the existing Caddy ($($res.message)); using the isolated hikari-caddy instead"
        $CaddyDecision = "isolated"
        Resolve-IsolatedCaddy
        Install-PrivateCaddyIfNeeded
    }
}

if (-not $SnippetOnly -and $CaddyDecision -eq "isolated" -and $WasIntegrated) {
    # Switching back to isolated: remove hikari's block from the previously joined Caddy first.
    $unArgs = @("caddy", "unintegrate", "--config", $ConfigPath, "--state-dir", $StateDir, "--json")
    if ($EffectiveReload) { $unArgs += "--reload" }
    $un = Invoke-HikariJson $unArgs
    if (-not $un.ok) { throw "Could not remove hikari from the previously joined Caddy: $($un.message)" }
    Write-Log "Removed hikari from the previously joined Caddy ($($un.message)). $($un.reload)"
}

if ($SnippetOnly) {
    $SnippetPath = Join-Path $ConfigDir "hikari-snippet.caddy"
    & $InstalledExe caddy snippet --config $ConfigPath --template (Join-Path $RelDir "caddy\snippet.caddy.tmpl") --out $SnippetPath
    if ($LASTEXITCODE -ne 0) { throw "Snippet generation failed" }
    Write-Log "Generated Caddy snippet at $SnippetPath (not imported anywhere; include it deliberately)"
} elseif ($Integrated) {
    # The existing Caddy serves hikari; no isolated Caddyfile is needed.
} elseif ($TsFqdn -and $TsIp) {
    $newCaddyfile = "$CaddyfilePath.new"
    & $InstalledExe caddy render --config $ConfigPath --template (Join-Path $RelDir "caddy\Caddyfile.tmpl") --fqdn $TsFqdn --tailscale-ip $TsIp --out $newCaddyfile
    if ($LASTEXITCODE -ne 0) { throw "Caddyfile rendering failed" }
    if ($ResolvedCaddy -and (Test-Path $ResolvedCaddy)) {
        & $ResolvedCaddy validate --adapter caddyfile --config $newCaddyfile | Out-Null
        if ($LASTEXITCODE -ne 0) { Remove-Item -Force $newCaddyfile; throw "Generated Caddyfile failed 'caddy validate'; existing config left untouched." }
    }
    if (Test-SameFile $newCaddyfile $CaddyfilePath) {
        Remove-Item -Force $newCaddyfile
    } else {
        if (Test-Path $CaddyfilePath) { Copy-Item $CaddyfilePath "$CaddyfilePath.bak" -Force }
        Move-Item -Force $newCaddyfile $CaddyfilePath
        $CaddyfileChanged = $true
        Write-Log "Wrote validated isolated Caddyfile at $CaddyfilePath"
    }
} else {
    Write-Log "Tailscale FQDN/IP unavailable: Caddyfile not generated. Enable MagicDNS + HTTPS, then re-run with -Repair."
}

# ---------------------------------------------------------------------------
# 8. Native services (hikari.exe registers them with typed SCM APIs)
# ---------------------------------------------------------------------------
function Invoke-HikariService([string[]]$ServiceArgs) {
    # Windows PowerShell turns native stderr into terminating errors under "Stop"; read it as text.
    $ErrorActionPreference = "Continue"
    $out = (& $InstalledExe service @ServiceArgs 2>&1 | ForEach-Object { "$_" }) -join "`n"
    if ($LASTEXITCODE -ne 0) { throw "hikari service $($ServiceArgs -join ' ') failed: $out" }
    Write-Log $out
    return $out
}

if ($ManageServices) {
    $acct = if ($AgentAccount -eq "Virtual") { "virtual" } else { "localsystem" }
    $agentResult = Invoke-HikariService @("install", "--name", "hikari", "--kind", "agent", "--config", $ConfigPath, "--exe", $InstalledExe, "--account", $acct)
    $script:OwnedServices["hikari"] = $true

    # Service SID now exists: grant the agent exactly what it needs.
    $agentPrincipal = if ($AgentAccount -eq "Virtual") { "NT SERVICE\hikari" } else { $null }
    if ($agentPrincipal) {
        & icacls.exe $ConfigDir /grant:r "${agentPrincipal}:(OI)(CI)R" | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "icacls failed granting $agentPrincipal read on $ConfigDir" }
        foreach ($d in @($StateDir, $LogsDir)) {
            & icacls.exe $d /grant:r "${agentPrincipal}:(OI)(CI)M" | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "icacls failed granting $agentPrincipal modify on $d" }
        }
    }

    $caddyResult = ""
    if ($Integrated -and $OwnedServices.ContainsKey("hikari-caddy")) {
        # The existing Caddy now serves the tailnet port; free it before any reload.
        Invoke-HikariService @("uninstall", "--name", "hikari-caddy", "--kind", "caddy", "--caddyfile", $CaddyfilePath) | Out-Null
        $OwnedServices.Remove("hikari-caddy")
        Write-Log "Removed the isolated hikari-caddy service (switched to the existing Caddy)"
    }
    if (-not $SnippetOnly -and -not $Integrated -and $ResolvedCaddy -and (Test-Path $CaddyfilePath)) {
        $caddyResult = Invoke-HikariService @("install", "--name", "hikari-caddy", "--kind", "caddy", "--caddy", $ResolvedCaddy, "--caddyfile", $CaddyfilePath)
        $script:OwnedServices["hikari-caddy"] = $true
    }

    # Restart only what changed; start anything not running.
    $restartAgent = $agentResult -match ": updated" -and -not ($StoppedForUpgrade -contains "hikari")
    if ($restartAgent) { Invoke-HikariService @("stop", "--name", "hikari") | Out-Null }
    Invoke-HikariService @("start", "--name", "hikari") | Out-Null
    if ($caddyResult) {
        $restartCaddy = ($caddyResult -match ": updated" -or $CaddyfileChanged) -and -not ($StoppedForUpgrade -contains "hikari-caddy")
        if ($restartCaddy) { Invoke-HikariService @("stop", "--name", "hikari-caddy") | Out-Null }
        try {
            Invoke-HikariService @("start", "--name", "hikari-caddy") | Out-Null
        } catch {
            # Expected before Tailscale is up; SCM recovery keeps retrying with backoff.
            Write-Log "WARNING: hikari-caddy did not start yet ($($_.Exception.Message)). It retries automatically; check $LogsDir\caddy.log."
        }
    }
} elseif ($StoppedForUpgrade.Count -gt 0) {
    foreach ($n in $StoppedForUpgrade) { Start-Service -Name $n -ErrorAction SilentlyContinue }
}

if ($Integrated) {
    if ($EffectiveReload) {
        $rl = Invoke-Native $InstalledExe @("caddy", "reload", "--config", $ConfigPath, "--state-dir", $StateDir)
        if ($rl.Code -eq 1) {
            # The reload was attempted and failed: put the existing Caddy's files back.
            $un = Invoke-HikariJson @("caddy", "unintegrate", "--config", $ConfigPath, "--state-dir", $StateDir, "--reload", "--json")
            throw "Reloading the existing Caddy failed ($($rl.Out)); hikari's change was removed again ($($un.message)). Re-run with -CaddyMode isolated to use hikari's own Caddy."
        }
        Write-Log $rl.Out
    } elseif ($ReloadHint) {
        Write-Log $ReloadHint
    }
}

# ---------------------------------------------------------------------------
# Short-lived privileged job: the restricted agent only writes an activity timestamp.
if ($ManageServices) {
    $existingTask = Get-ScheduledTask -TaskName "hikari-maintenance" -ErrorAction SilentlyContinue
    $maintenanceArguments = "update maintain --config `"$ConfigPath`""
    if ($existingTask -and ($existingTask.Description -ne "hikari-owned maintenance" -or
            @($existingTask.Actions).Count -ne 1 -or $existingTask.Actions[0].Execute -ne $InstalledExe -or
            $existingTask.Actions[0].Arguments -ne $maintenanceArguments)) {
        throw "Refusing to replace a foreign hikari-maintenance task"
    }
    $action = New-ScheduledTaskAction -Execute $InstalledExe -Argument $maintenanceArguments
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(5) -RepetitionInterval (New-TimeSpan -Minutes 5)
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 15) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName "hikari-maintenance" -Description "hikari-owned maintenance" -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    if ($AgentAccount -eq "Virtual") {
        $agentSid = ([System.Security.Principal.NTAccount]"NT SERVICE\hikari").Translate([System.Security.Principal.SecurityIdentifier]).Value
        $scheduler = New-Object -ComObject "Schedule.Service"
        $scheduler.Connect()
        # Read/execute only: agent can trigger this fixed action, never change it.
        $scheduler.GetFolder("\").GetTask("hikari-maintenance").SetSecurityDescriptor("D:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;GRGX;;;$agentSid)", 0)
    }
}

# 10. Separate installed files from end-to-end readiness.
Write-Host "`n=== hikari files and services installed ==="
Write-Host "  Version:       $AppVersion"
Write-Host "  Config:        $ConfigPath"
Write-Host "  Logs:          $LogsDir (hikari.log, caddy.log, install.log)"
if ($SnippetOnly) {
    Write-Host "  Caddy:         snippet generated; import and reload remain operator actions"
} elseif ($Integrated) {
    Write-Host "  Caddy:         reused existing service ($IntegrateCaddyfile)"
} else {
    Write-Host "  Caddy:         isolated hikari-caddy"
}
$readinessArgs = @((Join-Path $ScriptDir "readiness.py"), "--config", $ConfigPath,
    "--version", $AppVersion, "--fqdn", "$TsFqdn")
if ($Integrated -and -not $EffectiveReload) { $readinessArgs += "--pending-reload" }
if (-not $ManageServices -or $SnippetOnly) { $readinessArgs += "--skip" }
& python @readinessArgs
exit $LASTEXITCODE
