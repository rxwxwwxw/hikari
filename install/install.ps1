<#
.SYNOPSIS
Idempotent machine-wide Windows installer for hikari (Stage 2).
Registers hikari and hikari-caddy under the Windows Service Control Manager (via WinSW or sc.exe)
without modifying Tailscale, IIS, or any pre-existing Caddy service.
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
    [string]$TailscaleFixture = "",
    [ValidateSet("auto", "skip")]
    [string]$ServiceMode = "auto",
    [string]$Repo = "OWNER/REPO",
    [string]$PubKey = ""
)

$ErrorActionPreference = "Stop"

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

function Write-Log([string]$Message) {
    $line = "[{0}] {1}" -f (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ"), $Message
    Write-Host $line
    if (-not $DryRun) {
        if (-not (Test-Path $LogsDir)) { New-Item -ItemType Directory -Force -Path $LogsDir | Out-Null }
        Add-Content -Path $LogFile -Value $line
    }
}

# 1. Elevation check for real system installation
if (-not $Root -and -not $DryRun -and $ServiceMode -eq "auto") {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "System service installation requires an elevated Administrator PowerShell session (or pass -DryRun / -Root)."
    }
}

# 2. Validate ports
if ($TailnetPort -lt 1 -or $TailnetPort -gt 65535) { throw "Invalid TailnetPort: $TailnetPort" }
if ($LoopbackPort -lt 1 -or $LoopbackPort -gt 65535) { throw "Invalid LoopbackPort: $LoopbackPort" }

# 3. Locate hikari.exe binary source
if (-not $BinarySource) {
    $cand = Join-Path $RepoRoot "bin\hikari.exe"
    if (Test-Path $cand) { $BinarySource = $cand }
}
if (-not $BinarySource -or -not (Test-Path $BinarySource)) {
    throw "hikari.exe binary not found. Pass -BinarySource <path> or build with dub build --compiler=ldc2."
}

# 4. Read-only Tailscale status check
$TsJsonText = ""
if ($TailscaleFixture) {
    if (-not (Test-Path $TailscaleFixture)) { throw "Tailscale fixture not found: $TailscaleFixture" }
    $TsJsonText = Get-Content -Raw -Path $TailscaleFixture
} elseif (Get-Command tailscale -ErrorAction SilentlyContinue) {
    try { $TsJsonText = (& tailscale status --json 2>$null) -join "`n" } catch {}
}

$TsFqdn = ""
$TsIp = ""
if ($TsJsonText) {
    try {
        $tsObj = $TsJsonText | ConvertFrom-Json
        if ($tsObj.Self) {
            if ($tsObj.Self.DNSName) { $TsFqdn = ($tsObj.Self.DNSName).TrimEnd('.') }
            if ($tsObj.Self.TailscaleIPs -and $tsObj.Self.TailscaleIPs.Count -gt 0) {
                $TsIp = $tsObj.Self.TailscaleIPs[0]
            }
        }
    } catch {}
}

# 5. Port collision check before write
function Test-TcpPortInUse([int]$Port) {
    try {
        $listeners = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners()
        return ($listeners | Where-Object { $_.Port -eq $Port }).Count -gt 0
    } catch {
        return $false
    }
}

if (-not $Repair) {
    if (Test-TcpPortInUse $LoopbackPort) { throw "Port conflict: loopback port $LoopbackPort is already occupied." }
    if (-not $SnippetOnly -and (Test-TcpPortInUse $TailnetPort)) { throw "Port conflict: tailnet port $TailnetPort is already occupied." }
}

# 6. Caddy binary resolution (preserve any pre-existing Caddy service!)
$ResolvedCaddy = ""
$CaddyOrigin = "none"

if (-not $SnippetOnly) {
    if ($CaddyBin -and (Test-Path $CaddyBin)) {
        $ResolvedCaddy = $CaddyBin
        $CaddyOrigin = "explicit"
    } elseif ($CaddySource -ne "private" -and (Get-Command caddy.exe -ErrorAction SilentlyContinue)) {
        $ResolvedCaddy = (Get-Command caddy.exe).Source
        $CaddyOrigin = "existing_readonly"
    } elseif ($CaddySource -eq "existing") {
        throw "No existing caddy.exe found on PATH (-CaddySource existing)."
    } else {
        $ResolvedCaddy = Join-Path $PrivateBinDir "caddy.exe"
        $CaddyOrigin = "private"
        if (-not (Test-Path $ResolvedCaddy)) {
            if ($DryRun) {
                Write-Host "[dry-run] Would download and verify Caddy v$CaddyPinnedVersion to $ResolvedCaddy"
            } else {
                New-Item -ItemType Directory -Force -Path $PrivateBinDir | Out-Null
                $url = "https://github.com/caddyserver/caddy/releases/download/v$CaddyPinnedVersion/caddy_${CaddyPinnedVersion}_windows_amd64.zip"
                $tmpZip = Join-Path $env:TEMP "hikari-caddy-$CaddyPinnedVersion.zip"
                Write-Log "Downloading pinned Caddy v$CaddyPinnedVersion to private dir..."
                Invoke-WebRequest -Uri $url -OutFile $tmpZip -UseBasicParsing
                $hash = (Get-FileHash -Path $tmpZip -Algorithm SHA512).Hash.ToLower()
                if ($hash -ne $CaddySha512WinAmd64) {
                    Remove-Item -Force $tmpZip -ErrorAction SilentlyContinue
                    throw "Caddy checksum mismatch! expected=$CaddySha512WinAmd64 actual=$hash"
                }
                Expand-Archive -Path $tmpZip -DestinationPath $PrivateBinDir -Force
                Remove-Item -Force $tmpZip -ErrorAction SilentlyContinue
            }
        }
    }
}

Write-Host "=== hikari Windows Install Plan ==="
Write-Host "  Base dir:       $ProgramDataBase"
Write-Host "  Versions dir:   $VersionsDir"
Write-Host "  Config dir:     $ConfigDir"
Write-Host "  State dir:      $StateDir"
Write-Host "  Ports:          tailnet=$TailnetPort loopback=127.0.0.1:$LoopbackPort base_path=$BasePath"
Write-Host "  Caddy binary:   $ResolvedCaddy ($CaddyOrigin)"
Write-Host "  Tailscale FQDN: $(if ($TsFqdn) { $TsFqdn } else { '<unavailable>' }) (IP: $(if ($TsIp) { $TsIp } else { '<none>' }))"
Write-Host "  Service mode:   $ServiceMode"

if ($DryRun) {
    Write-Host "[dry-run] Preflight succeeded; no changes written."
    exit 0
}

# 7. Create directories and install versioned release
New-Item -ItemType Directory -Force -Path $VersionsDir, $PrivateBinDir, $ConfigDir, (Join-Path $StateDir "caddy"), $LogsDir | Out-Null

$AppVersion = if (Test-Path (Join-Path $RepoRoot "VERSION")) { (Get-Content -Raw (Join-Path $RepoRoot "VERSION")).Trim() } else { "0.1.0" }
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

if (Test-Path $RelDir) { Remove-Item -Recurse -Force $RelDir }
Move-Item -Path $StageDir -Destination $RelDir

$CurTxt = Join-Path $VersionsDir "current.txt"
$PrevTxt = Join-Path $VersionsDir "previous.txt"
if (Test-Path $CurTxt) {
    $oldVer = (Get-Content -Raw $CurTxt).Trim()
    if ($oldVer -and $oldVer -ne $AppVersion) {
        Set-Content -Path $PrevTxt -Value $oldVer
    }
}
Set-Content -Path $CurTxt -Value $AppVersion

$CurrentJunction = Join-Path $VersionsDir "current"
if (Test-Path $CurrentJunction) {
    cmd /c rmdir /q "$CurrentJunction" 2>$null | Out-Null
}
cmd /c mklink /J "$CurrentJunction" "$RelDir" | Out-Null
Write-Log "Installed hikari $AppVersion to $RelDir"

# 8. Write default config.json ONLY if missing (never overwrite operator settings)
$ConfigPath = Join-Path $ConfigDir "config.json"
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
    $cfgObj | ConvertTo-Json -Depth 6 | Set-Content -Path $ConfigPath -Encoding UTF8
    Write-Log "Created initial configuration at $ConfigPath"
} else {
    Write-Log "Preserved existing user configuration at $ConfigPath"
}

# 9. Render isolated Caddyfile or snippet
$InstalledExe = Join-Path $CurrentJunction "hikari.exe"
if ($SnippetOnly) {
    $SnippetPath = Join-Path $ConfigDir "hikari-snippet.caddy"
    & $InstalledExe caddy snippet --config $ConfigPath --template (Join-Path $RelDir "caddy\snippet.caddy.tmpl") --out $SnippetPath
    Write-Log "Generated Caddy snippet at $SnippetPath"
} elseif ($TsFqdn -and $TsIp) {
    $CaddyfilePath = Join-Path $ConfigDir "Caddyfile"
    if (Test-Path $CaddyfilePath) { Copy-Item $CaddyfilePath "$CaddyfilePath.bak" -Force }
    & $InstalledExe caddy render --config $ConfigPath --template (Join-Path $RelDir "caddy\Caddyfile.tmpl") --fqdn $TsFqdn --tailscale-ip $TsIp --out $CaddyfilePath
    if (Test-Path $ResolvedCaddy) {
        & $ResolvedCaddy validate --adapter caddyfile --config $CaddyfilePath | Out-Null
        Write-Log "Validated isolated Caddyfile at $CaddyfilePath"
    }
}

# 10. Generate WinSW service XML definitions for unattended boot-persistent operation (no login required)
$HikariXml = @"
<service>
  <id>hikari</id>
  <name>hikari Telemetry Agent</name>
  <description>Decentralized Tailscale fleet telemetry and hardware inventory agent</description>
  <executable>$InstalledExe</executable>
  <arguments>serve --config "$ConfigPath"</arguments>
  <startmode>Automatic</startmode>
  <onfailure action="restart" delay="5 sec"/>
  <logpath>$LogsDir</logpath>
  <log mode="roll-by-size"><sizeThreshold>10240</sizeThreshold><keepFiles>3</keepFiles></log>
</service>
"@
Set-Content -Path (Join-Path $ConfigDir "hikari-service.xml") -Value $HikariXml -Encoding UTF8

if (-not $SnippetOnly) {
    $CaddyXml = @"
<service>
  <id>hikari-caddy</id>
  <name>hikari Isolated Tailscale Caddy</name>
  <description>Isolated HTTPS reverse proxy bound to Tailscale interface for hikari</description>
  <executable>$ResolvedCaddy</executable>
  <arguments>run --config "$(Join-Path $ConfigDir 'Caddyfile')" --adapter caddyfile</arguments>
  <depend>Tailscale</depend>
  <depend>hikari</depend>
  <startmode>Automatic</startmode>
  <onfailure action="restart" delay="10 sec"/>
  <logpath>$LogsDir</logpath>
  <log mode="roll-by-size"><sizeThreshold>10240</sizeThreshold><keepFiles>3</keepFiles></log>
</service>
"@
    Set-Content -Path (Join-Path $ConfigDir "hikari-caddy-service.xml") -Value $CaddyXml -Encoding UTF8
}

# 11. Register services if ServiceMode == auto and WinSW is available
if ($ServiceMode -eq "auto") {
    $winsw = if ($WinSWBin -and (Test-Path $WinSWBin)) { $WinSWBin } else { Join-Path $PrivateBinDir "winsw.exe" }
    if (Test-Path $winsw) {
        Copy-Item $winsw (Join-Path $PrivateBinDir "hikari-service.exe") -Force
        Copy-Item (Join-Path $ConfigDir "hikari-service.xml") (Join-Path $PrivateBinDir "hikari-service.xml") -Force
        & (Join-Path $PrivateBinDir "hikari-service.exe") install | Out-Null
        & (Join-Path $PrivateBinDir "hikari-service.exe") start | Out-Null
        if (-not $SnippetOnly -and (Test-Path (Join-Path $ConfigDir "Caddyfile"))) {
            Copy-Item $winsw (Join-Path $PrivateBinDir "hikari-caddy-service.exe") -Force
            Copy-Item (Join-Path $ConfigDir "hikari-caddy-service.xml") (Join-Path $PrivateBinDir "hikari-caddy-service.xml") -Force
            & (Join-Path $PrivateBinDir "hikari-caddy-service.exe") install | Out-Null
            & (Join-Path $PrivateBinDir "hikari-caddy-service.exe") start | Out-Null
        }
        Write-Log "Registered and started machine-wide Windows services via WinSW"
    } else {
        Write-Log "WinSW wrapper not found at $winsw; generated WinSW XML descriptors in $ConfigDir. Place winsw.exe in $PrivateBinDir and re-run with -Repair to activate SCM services."
    }
}

Write-Host "`n=== hikari Windows installation complete ==="
Write-Host "  Version:       $AppVersion"
Write-Host "  Config:        $ConfigPath"
Write-Host "  Service XMLs:  $ConfigDir\hikari*-service.xml"
if ($TsFqdn -and -not $SnippetOnly) {
    Write-Host "  Dashboard URL: https://${TsFqdn}:${TailnetPort}$($BasePath.TrimEnd('/'))/"
}
