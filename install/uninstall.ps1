<#
.SYNOPSIS
Uninstaller for hikari on Windows.

.DESCRIPTION
Stops and removes only the hikari-owned `hikari` and `hikari-caddy` services and binaries.
Preserves config.json and state (node registry, hardware cache, Caddy certificates) unless
-Purge is given. Never touches Tailscale, a shared/system Caddy, the firewall, or any service
that hikari did not install. Also removes services left by earlier WinSW-based installs.

If hikari was joined into an existing Caddy, its marked block and site file are removed first
(the Caddyfile is restored byte for byte). That Caddy is reloaded only with -Reload.
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$Purge,
    [switch]$Reload,
    [string]$Root = "",
    [ValidateSet("auto", "skip")]
    [string]$ServiceMode = "auto"
)

$ErrorActionPreference = "Stop"

$ProgramDataBase = if ($Root) { Join-Path $Root "ProgramData\hikari" } else { "C:\ProgramData\hikari" }
$VersionsDir = Join-Path $ProgramDataBase "versions"
$PrivateBinDir = Join-Path $ProgramDataBase "bin"
$ConfigDir = Join-Path $ProgramDataBase "config"
$StateDir = Join-Path $ProgramDataBase "state"
$ConfigPath = Join-Path $ConfigDir "config.json"
$CaddyfilePath = Join-Path $ConfigDir "Caddyfile"
$InstalledExe = Join-Path $VersionsDir "current\hikari.exe"
$ManageServices = ($ServiceMode -eq "auto") -and (-not $Root)

if ($ManageServices -and -not $DryRun) {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "System uninstall requires Administrator privileges (or pass -DryRun / -Root)."
    }
}

# Undo an integration into an existing Caddy before removing hikari's binary.
$IntegrationRecord = Join-Path $StateDir "caddy-integration.json"
if (Test-Path $IntegrationRecord) {
    if (-not (Test-Path $InstalledExe)) {
        throw "hikari is joined into an existing Caddy ($IntegrationRecord) but $InstalledExe is missing; reinstall, or remove the '# BEGIN hikari' block by hand, then re-run."
    }
    $unArgs = @("caddy", "unintegrate", "--config", $ConfigPath, "--state-dir", $StateDir, "--json")
    if ($DryRun) { $unArgs += "--dry-run" }
    if ($Reload) { $unArgs += "--reload" }
    $ErrorActionPreference = "Continue"
    $raw = (& $InstalledExe @unArgs 2>&1 | ForEach-Object { "$_" }) -join "`n"
    $ErrorActionPreference = "Stop"
    $start = $raw.IndexOf("{")
    $un = if ($start -ge 0) { $raw.Substring($start) | ConvertFrom-Json } else { $null }
    if (-not $un -or -not $un.ok) {
        throw "Could not remove hikari from the existing Caddy; nothing was uninstalled. $(if ($un) { $un.message } else { $raw })"
    }
    Write-Host "$(if ($DryRun) { '[dry-run] ' })$($un.message). $($un.reload)"
}

function Get-ServiceOwnership([string]$Name) {
    $svc = Get-CimInstance Win32_Service -Filter "Name='$Name'" -ErrorAction SilentlyContinue
    if (-not $svc) { return "absent" }
    $p = [string]$svc.PathName
    if ($p -like "*$(Join-Path $PrivateBinDir "$Name-service.exe")*") { return "legacy" }
    if ($Name -eq "hikari" -and $p -like "*\hikari.exe*serve --service --config*" -and $p -like "*$ConfigPath*") { return "native" }
    if ($Name -eq "hikari-caddy" -and $p -like "* run --config *" -and $p -like "*$CaddyfilePath*") { return "native" }
    return "foreign"
}

if ($ManageServices) {
    foreach ($svcName in @("hikari-caddy", "hikari")) {
        $own = Get-ServiceOwnership $svcName
        if ($own -eq "absent") { continue }
        if ($own -eq "foreign") {
            Write-Warning "Service '$svcName' is not managed by hikari; leaving it untouched."
            continue
        }
        if ($DryRun) {
            Write-Host "[dry-run] Would stop and remove service $svcName ($own)"
            continue
        }
        if ($own -eq "native" -and (Test-Path $InstalledExe)) {
            $kindArgs = if ($svcName -eq "hikari") { @("--kind", "agent", "--config", $ConfigPath) } else { @("--kind", "caddy", "--caddyfile", $CaddyfilePath) }
            $ErrorActionPreference = "Continue"
            $out = (& $InstalledExe service uninstall --name $svcName @kindArgs 2>&1 | ForEach-Object { "$_" }) -join "`n"
            $code = $LASTEXITCODE
            $ErrorActionPreference = "Stop"
            if ($code -ne 0) { throw "Failed to remove ${svcName}: $out" }
        } else {
            # Legacy WinSW service, or our binary is already gone: ownership was verified above.
            $s = Get-Service -Name $svcName
            if ($s.Status -ne "Stopped") {
                Stop-Service -Name $svcName -Force
                $s.WaitForStatus("Stopped", [TimeSpan]::FromSeconds(30))
            }
            $wrapper = Join-Path $PrivateBinDir "$svcName-service.exe"
            if ($own -eq "legacy" -and (Test-Path $wrapper)) { & $wrapper uninstall | Out-Null } else { & sc.exe delete $svcName | Out-Null }
        }
        Write-Host "Removed service $svcName"
    }
}

function Remove-Junction([string]$PathToRemove) {
    # Never Remove-Item -Recurse a junction: Windows PowerShell 5.1 follows it and deletes the target.
    if (Test-Path $PathToRemove) {
        if ($DryRun) { Write-Host "[dry-run] Would remove junction $PathToRemove" }
        else { cmd /c rmdir /q "$PathToRemove" 2>$null | Out-Null }
    }
}

function Remove-SafePath([string]$PathToRemove) {
    if (Test-Path $PathToRemove) {
        if ($DryRun) {
            Write-Host "[dry-run] Would remove $PathToRemove"
        } else {
            Remove-Item -Recurse -Force $PathToRemove
        }
    }
}

foreach ($j in @("current", "previous", "current.new", "current.old", "previous.new", "previous.old")) {
    Remove-Junction (Join-Path $VersionsDir $j)
}
Remove-SafePath $VersionsDir
Remove-SafePath $PrivateBinDir
foreach ($f in @("Caddyfile", "Caddyfile.bak", "Caddyfile.new", "hikari-snippet.caddy", "hikari-service.xml", "hikari-caddy-service.xml")) {
    Remove-SafePath (Join-Path $ConfigDir $f)
}

if ($Purge) {
    Remove-SafePath $ProgramDataBase
    Write-Host "Uninstalled hikari and purged configuration/state under $ProgramDataBase."
} else {
    Write-Host "Uninstalled hikari services and binaries. Preserved $ConfigDir\config.json and $StateDir (pass -Purge to remove)."
}
