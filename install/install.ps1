<#
.SYNOPSIS
Idempotent machine-wide Windows installer for hikari (Stage 2).

.DESCRIPTION
Registers two Service Control Manager services, `hikari` (loopback telemetry agent) and
`hikari-caddy` (isolated HTTPS proxy bound to the Tailscale address), via WinSW. Services
start at boot and keep running with no user signed in, during Fast User Switching and
after every user signs out.

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
    [ValidateSet("auto", "private", "existing")]
    [string]$CaddySource = "auto",
    [int]$TailnetPort = 9100,
    [int]$LoopbackPort = 19100,
    [string]$BasePath = "/",
    [string]$Root = "",
    [string]$BinarySource = "",
    [string]$CaddyBin = "",
    [string]$WinSWBin = "",
    [string]$WinSWSha256 = "",
    [string]$TailscaleFixture = "",
    [ValidateSet("auto", "skip")]
    [string]$ServiceMode = "auto",
    # Restricted built-in account by default. LocalSystem gives full process visibility
    # (other users' games/apps in the Top Processes list) at the cost of least privilege.
    [ValidateSet("LocalService", "LocalSystem")]
    [string]$AgentAccount = "LocalService",
    [string]$Repo = "OWNER/REPO",
    [string]$PubKey = ""
)

$ErrorActionPreference = "Stop"

$CaddyPinnedVersion = "2.9.1"
# Official Caddy v2.9.1 windows_amd64.zip SHA-512 from caddy_2.9.1_checksums.txt
$CaddySha512WinAmd64 = "4f0f85b42015ff2276d08705751472e6a98bdc7fda5ec76dd41b7a0c16fee90af012f1a7beb226164408cfbe656bd3453ed5ccbb596f80c45d0fa1c749fc8da2"

# WinSW is downloaded only when its SHA-256 is pinned here (release maintainers) or passed via
# -WinSWSha256. Without a trusted hash the installer fails closed and asks for -WinSWBin.
$WinSWPinnedVersion = "2.12.0"
$WinSWPinnedSha256X64 = ""
$WinSWUrl = "https://github.com/winsw/winsw/releases/download/v$WinSWPinnedVersion/WinSW-x64.exe"

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

if (-not $BinarySource) {
    $cand = Join-Path $RepoRoot "bin\hikari.exe"
    if (Test-Path $cand) { $BinarySource = $cand }
}
if (-not $BinarySource -or -not (Test-Path $BinarySource)) {
    throw "hikari.exe binary not found. Pass -BinarySource <path> or build with dub build --compiler=ldc2 --build=release."
}

# A service with our name that runs something outside our bin dir is not ours: never touch it.
$OwnedServices = @{}
foreach ($svcName in $(if ($ManageServices) { @("hikari", "hikari-caddy") } else { @() })) {
    $svc = Get-CimInstance Win32_Service -Filter "Name='$svcName'" -ErrorAction SilentlyContinue
    if ($svc) {
        $expected = Join-Path $PrivateBinDir "$svcName-service.exe"
        if ($svc.PathName -notlike "*$expected*") {
            throw "A service named '$svcName' already exists and is not managed by hikari ($($svc.PathName)). Refusing to modify it."
        }
        $OwnedServices[$svcName] = $svc
    }
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
# Ports held by our own running services are expected on reinstall.
$OurAgentRunning = $OwnedServices.ContainsKey("hikari") -and $OwnedServices["hikari"].State -eq "Running"
$OurCaddyRunning = $OwnedServices.ContainsKey("hikari-caddy") -and $OwnedServices["hikari-caddy"].State -eq "Running"
if (-not $Repair) {
    if (-not $OurAgentRunning -and (Test-TcpPortInUse $LoopbackPort)) {
        throw "Port conflict: loopback port $LoopbackPort is already used by another program. Re-run with -LoopbackPort <free port>."
    }
    if (-not $SnippetOnly -and -not $OurCaddyRunning -and (Test-TcpPortInUse $TailnetPort)) {
        throw "Port conflict: tailnet port $TailnetPort is already used by another program. Re-run with -TailnetPort <free port>."
    }
}

# Caddy resolution (an existing Caddy is used read-only; its service is never touched).
$ResolvedCaddy = ""
$CaddyOrigin = "none"
$NeedCaddyDownload = $false
if (-not $SnippetOnly) {
    if ($CaddyBin -and (Test-Path $CaddyBin)) {
        $ResolvedCaddy = $CaddyBin; $CaddyOrigin = "explicit"
    } elseif ($CaddySource -ne "private" -and (Get-Command caddy.exe -ErrorAction SilentlyContinue)) {
        $ResolvedCaddy = (Get-Command caddy.exe).Source; $CaddyOrigin = "existing_readonly"
    } elseif ($CaddySource -eq "existing") {
        throw "No existing caddy.exe found on PATH (-CaddySource existing)."
    } else {
        $ResolvedCaddy = Join-Path $PrivateBinDir "caddy.exe"; $CaddyOrigin = "private"
        $NeedCaddyDownload = -not (Test-Path $ResolvedCaddy)
    }
}

# WinSW resolution.
$PrivateWinSW = Join-Path $PrivateBinDir "winsw.exe"
$WinSWPlan = "not needed"
$TrustedWinSWHash = if ($WinSWSha256) { $WinSWSha256.ToLower() } else { $WinSWPinnedSha256X64.ToLower() }
if ($ManageServices) {
    if ($WinSWBin) {
        if (-not (Test-Path $WinSWBin)) { throw "WinSW binary not found: $WinSWBin" }
        $WinSWPlan = "operator-supplied $WinSWBin"
    } elseif (Test-Path $PrivateWinSW) {
        $WinSWPlan = "existing $PrivateWinSW"
    } elseif ($TrustedWinSWHash) {
        $WinSWPlan = "download WinSW v$WinSWPinnedVersion and verify SHA-256"
    } else {
        $WinSWPlan = "UNAVAILABLE (pass -WinSWBin <WinSW-x64.exe> or -WinSWSha256 <hash>); service XML will be generated only"
    }
}

$AppVersion = if (Test-Path (Join-Path $RepoRoot "VERSION")) { (Get-Content -Raw (Join-Path $RepoRoot "VERSION")).Trim() } else { "0.1.0" }

Write-Host "=== hikari Windows install plan ==="
Write-Host "  Version:          $AppVersion -> $VersionsDir\$AppVersion (versions\current junction)"
Write-Host "  Config / state:   $ConfigDir (config.json preserved if present) / $StateDir"
Write-Host "  Ports:            tailnet=$TailnetPort loopback=127.0.0.1:$LoopbackPort base_path=$BasePath"
Write-Host "  Caddy binary:     $(if ($ResolvedCaddy) { $ResolvedCaddy } else { '<none>' }) ($CaddyOrigin$(if ($NeedCaddyDownload) { ', will download pinned v' + $CaddyPinnedVersion }))"
Write-Host "  Tailscale:        FQDN=$(if ($TsFqdn) { $TsFqdn } else { '<unavailable>' }) IP=$(if ($TsIp) { $TsIp } else { '<none>' }) service=$(if ($TsServicePresent) { 'present' } else { 'absent' })"
Write-Host "  Services:         $(if ($ManageServices) { "hikari ($AgentAccount), hikari-caddy (LocalSystem); WinSW: $WinSWPlan" } else { 'not managed (-Root or -ServiceMode skip)' })"
Write-Host "  ACLs:             $(if ($Root) { 'skipped (-Root)' } else { 'restrict ProgramData\hikari to SYSTEM/Administrators (+agent account where needed)' })"
Write-Host "  Not modified:     Tailscale, firewall, IIS, any other Caddy, any other service"
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

if (-not $Root) {
    # Well-known SIDs (locale independent).
    $S_SYSTEM = "*S-1-5-18"; $S_ADMINS = "*S-1-5-32-544"; $S_USERS = "*S-1-5-32-545"; $S_LOCALSERVICE = "*S-1-5-19"
    function Set-Acl-Strict([string]$Path, [string[]]$Grants) {
        $icaclsArgs = @($Path, "/inheritance:r", "/grant:r") + $Grants
        & icacls.exe @icaclsArgs | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "icacls failed for $Path" }
    }
    # Default ProgramData lets standard users create files; a child account must not be able
    # to plant or replace binaries that run as a service.
    $baseGrants = @("${S_SYSTEM}:(OI)(CI)F", "${S_ADMINS}:(OI)(CI)F", "${S_USERS}:(OI)(CI)RX")
    if ($AgentAccount -eq "LocalService") { $baseGrants += "${S_LOCALSERVICE}:(OI)(CI)RX" }
    Set-Acl-Strict $ProgramDataBase $baseGrants
    $privGrants = @("${S_SYSTEM}:(OI)(CI)F", "${S_ADMINS}:(OI)(CI)F")
    $cfgGrants = $privGrants + $(if ($AgentAccount -eq "LocalService") { @("${S_LOCALSERVICE}:(OI)(CI)R") } else { @() })
    $rwGrants = $privGrants + $(if ($AgentAccount -eq "LocalService") { @("${S_LOCALSERVICE}:(OI)(CI)M") } else { @() })
    Set-Acl-Strict $ConfigDir $cfgGrants
    Set-Acl-Strict $StateDir $rwGrants
    Set-Acl-Strict $LogsDir $rwGrants
    Write-Log "Applied restricted ACLs under $ProgramDataBase"
}

# ---------------------------------------------------------------------------
# 3. Helper downloads (verified before use)
# ---------------------------------------------------------------------------
if ($NeedCaddyDownload) {
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
        Copy-Item (Join-Path $dlDir "x\caddy.exe") $ResolvedCaddy -Force
        Write-Log "Installed verified private Caddy at $ResolvedCaddy"
    } finally {
        Remove-Item -Recurse -Force $dlDir -ErrorAction SilentlyContinue
    }
}

$WinSWSource = ""
if ($ManageServices) {
    if ($WinSWBin) {
        $WinSWSource = $WinSWBin
    } elseif (Test-Path $PrivateWinSW) {
        $WinSWSource = $PrivateWinSW
    } elseif ($TrustedWinSWHash) {
        $tmpExe = Join-Path $env:TEMP ("hikari-winsw-" + [guid]::NewGuid().ToString("N") + ".exe")
        try {
            Write-Log "Downloading WinSW v$WinSWPinnedVersion..."
            Invoke-WebRequest -Uri $WinSWUrl -OutFile $tmpExe -UseBasicParsing
            $h = (Get-FileHash -Path $tmpExe -Algorithm SHA256).Hash.ToLower()
            if ($h -ne $TrustedWinSWHash) { throw "WinSW checksum mismatch! expected=$TrustedWinSWHash actual=$h" }
            Copy-Item $tmpExe $PrivateWinSW -Force
            $WinSWSource = $PrivateWinSW
        } finally {
            Remove-Item -Force $tmpExe -ErrorAction SilentlyContinue
        }
    }
}

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

# ---------------------------------------------------------------------------
# 5. Versioned release (never overwrite a running executable)
# ---------------------------------------------------------------------------
$RelDir = Join-Path $VersionsDir $AppVersion
$StageDir = Join-Path $VersionsDir ".install-tmp-$AppVersion"
if (Test-Path $StageDir) { Remove-Item -Recurse -Force $StageDir }
New-Item -ItemType Directory -Force -Path (Join-Path $StageDir "web"), (Join-Path $StageDir "caddy") | Out-Null

if ($BinarySource -like "*.zip") {
    Expand-Archive -Path $BinarySource -DestinationPath $StageDir -Force
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

# ---------------------------------------------------------------------------
# 7. Generated Caddy config (hikari-owned files only)
# ---------------------------------------------------------------------------
$InstalledExe = Join-Path $CurrentJunction "hikari.exe"
$CaddyfilePath = Join-Path $ConfigDir "Caddyfile"
if ($SnippetOnly) {
    $SnippetPath = Join-Path $ConfigDir "hikari-snippet.caddy"
    & $InstalledExe caddy snippet --config $ConfigPath --template (Join-Path $RelDir "caddy\snippet.caddy.tmpl") --out $SnippetPath
    if ($LASTEXITCODE -ne 0) { throw "Snippet generation failed" }
    Write-Log "Generated Caddy snippet at $SnippetPath (not imported anywhere; include it deliberately)"
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
        Write-Log "Wrote validated isolated Caddyfile at $CaddyfilePath"
    }
} else {
    Write-Log "Tailscale FQDN/IP unavailable: Caddyfile not generated. Enable MagicDNS + HTTPS, then re-run with -Repair."
}

# ---------------------------------------------------------------------------
# 8. WinSW service descriptors
# ---------------------------------------------------------------------------
function ConvertTo-XmlText([string]$s) { return [System.Security.SecurityElement]::Escape($s) }
$xExe = ConvertTo-XmlText $InstalledExe
$xCfg = ConvertTo-XmlText $ConfigPath
$xLogs = ConvertTo-XmlText $LogsDir

# No <depend> on Tailscale or between our services: a dependency would make SCM refuse to
# stop/upgrade Tailscale (or hikari) while dependents run. Restart-with-backoff covers ordering.
$HikariXml = @"
<service>
  <id>hikari</id>
  <name>hikari Telemetry Agent</name>
  <description>On-demand Tailscale fleet telemetry and hardware inventory agent (loopback only)</description>
  <executable>$xExe</executable>
  <arguments>serve --config "$xCfg"</arguments>
  <startmode>Automatic</startmode>
  <stoptimeout>15 sec</stoptimeout>
  <onfailure action="restart" delay="5 sec"/>
  <onfailure action="restart" delay="30 sec"/>
  <onfailure action="restart" delay="2 min"/>
  <resetfailure>1 hour</resetfailure>
  <logpath>$xLogs</logpath>
  <log mode="roll-by-size"><sizeThreshold>10240</sizeThreshold><keepFiles>3</keepFiles></log>
</service>
"@
$CaddyXml = $null
if (-not $SnippetOnly) {
    $xCaddy = ConvertTo-XmlText $ResolvedCaddy
    $xCaddyfile = ConvertTo-XmlText $CaddyfilePath
    $CaddyXml = @"
<service>
  <id>hikari-caddy</id>
  <name>hikari Isolated Tailscale Caddy</name>
  <description>Isolated HTTPS proxy for hikari bound only to this machine's Tailscale address</description>
  <executable>$xCaddy</executable>
  <arguments>run --config "$xCaddyfile" --adapter caddyfile</arguments>
  <startmode>Automatic</startmode>
  <delayedAutoStart>true</delayedAutoStart>
  <stoptimeout>15 sec</stoptimeout>
  <onfailure action="restart" delay="10 sec"/>
  <onfailure action="restart" delay="30 sec"/>
  <onfailure action="restart" delay="2 min"/>
  <resetfailure>1 hour</resetfailure>
  <logpath>$xLogs</logpath>
  <log mode="roll-by-size"><sizeThreshold>10240</sizeThreshold><keepFiles>3</keepFiles></log>
</service>
"@
}
Write-Utf8NoBom (Join-Path $ConfigDir "hikari-service.xml") $HikariXml
if ($CaddyXml) { Write-Utf8NoBom (Join-Path $ConfigDir "hikari-caddy-service.xml") $CaddyXml }

# ---------------------------------------------------------------------------
# 9. Register / reconcile services
# ---------------------------------------------------------------------------
function Set-ServiceAccount([string]$Name, [string]$Account) {
    $startName = if ($Account -eq "LocalService") { "NT AUTHORITY\LocalService" } else { "LocalSystem" }
    $svc = Get-CimInstance Win32_Service -Filter "Name='$Name'"
    if ($svc.StartName -ne $startName) {
        $r = Invoke-CimMethod -InputObject $svc -MethodName Change -Arguments @{ StartName = $startName; StartPassword = "" }
        if ($r.ReturnValue -ne 0) { throw "Failed to set $Name service account to $startName (Win32_Service.Change=$($r.ReturnValue))" }
        Write-Log "Service $Name runs as $startName"
    }
}

function Sync-WinSWService([string]$Name, [string]$XmlText, [string]$Account) {
    $wrapper = Join-Path $PrivateBinDir "$Name-service.exe"
    $wrapperXml = Join-Path $PrivateBinDir "$Name-service.xml"
    $exists = [bool](Get-Service -Name $Name -ErrorAction SilentlyContinue)
    $xmlChanged = -not (Test-Path $wrapperXml) -or ([System.IO.File]::ReadAllText($wrapperXml) -ne $XmlText)
    $wrapperChanged = -not (Test-SameFile $WinSWSource $wrapper)

    if ($exists -and ($xmlChanged -or $wrapperChanged)) {
        Stop-OwnedService $Name
        & $wrapper uninstall | Out-Null
        $exists = $false
    }
    if ($wrapperChanged) { Copy-Item $WinSWSource $wrapper -Force }
    Write-Utf8NoBom $wrapperXml $XmlText
    if (-not $exists) {
        & $wrapper install | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "WinSW failed to install service $Name" }
        $script:OwnedServices[$Name] = $true
        Write-Log "Registered service $Name"
    }
    Set-ServiceAccount $Name $Account
    $s = Get-Service -Name $Name
    if ($s.Status -ne "Running") {
        Start-Service -Name $Name
        Write-Log "Started service $Name"
    }
}

if ($ManageServices) {
    if ($WinSWSource) {
        Sync-WinSWService "hikari" $HikariXml $AgentAccount
        if ($CaddyXml -and (Test-Path $CaddyfilePath)) {
            Sync-WinSWService "hikari-caddy" $CaddyXml "LocalSystem"
        }
        # Restart anything we stopped that the sync did not already bring back.
        foreach ($n in $StoppedForUpgrade) {
            $s = Get-Service -Name $n -ErrorAction SilentlyContinue
            if ($s -and $s.Status -ne "Running") { Start-Service -Name $n }
        }
    } else {
        Write-Log "WinSW unavailable; generated service XML in $ConfigDir. Re-run with -WinSWBin <WinSW-x64.exe> -Repair to register services."
    }
} elseif ($StoppedForUpgrade.Count -gt 0) {
    foreach ($n in $StoppedForUpgrade) { Start-Service -Name $n -ErrorAction SilentlyContinue }
}

# ---------------------------------------------------------------------------
# 10. Post-install verification from the real service identity
# ---------------------------------------------------------------------------
$ServiceTailscaleOk = $null
if ($ManageServices -and $WinSWSource) {
    $healthy = $false
    foreach ($i in 1..30) {
        try {
            $null = Invoke-WebRequest -UseBasicParsing -TimeoutSec 2 -Uri "http://127.0.0.1:$LoopbackPort/healthz"
            $healthy = $true; break
        } catch { Start-Sleep -Milliseconds 500 }
    }
    if (-not $healthy) {
        Write-Log "WARNING: hikari service did not answer /healthz on 127.0.0.1:$LoopbackPort; see $LogsDir"
    } else {
        try {
            $info = Invoke-RestMethod -TimeoutSec 5 -Uri "http://127.0.0.1:$LoopbackPort/api/v1/info"
            $ServiceTailscaleOk = [bool]$info.fqdn
        } catch { $ServiceTailscaleOk = $false }
        if ($ServiceTailscaleOk) {
            Write-Log "Verified: the hikari service account can read local Tailscale status ($($info.fqdn))"
        } else {
            Write-Log "WARNING: the hikari service ($AgentAccount) cannot read Tailscale status. Peer discovery and Host validation need it."
            Write-Log "         Enable Tailscale's 'Run unattended' option (so tailscaled is not tied to an interactive user),"
            Write-Log "         or re-run with -AgentAccount LocalSystem -Repair. hikari never changes Tailscale settings itself."
        }
    }
}

Write-Host "`n=== hikari Windows installation complete ==="
Write-Host "  Version:       $AppVersion"
Write-Host "  Config:        $ConfigPath"
Write-Host "  Service XMLs:  $ConfigDir\hikari*-service.xml"
if ($TsFqdn -and -not $SnippetOnly -and (Test-Path $CaddyfilePath)) {
    Write-Host "  Dashboard URL: https://${TsFqdn}:${TailnetPort}$($BasePath.TrimEnd('/'))/"
    Write-Host "  Note: restrict TCP $TailnetPort in your Tailscale ACLs; hikari does not change Windows Firewall or Tailscale policy."
}
