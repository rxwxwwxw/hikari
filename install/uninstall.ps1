<#
.SYNOPSIS
Uninstaller for hikari on Windows.

.DESCRIPTION
Stops and removes only the hikari-owned `hikari` and `hikari-caddy` services and binaries.
Preserves config.json and state (node registry, hardware cache, Caddy certificates) unless
-Purge is given. Never touches Tailscale, a shared/system Caddy, the firewall, or any service
that hikari did not install.
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$Purge,
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
$ManageServices = ($ServiceMode -eq "auto") -and (-not $Root)

if ($ManageServices -and -not $DryRun) {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "System uninstall requires Administrator privileges (or pass -DryRun / -Root)."
    }
}

if ($ManageServices) {
    foreach ($svcName in @("hikari-caddy", "hikari")) {
        $svc = Get-CimInstance Win32_Service -Filter "Name='$svcName'" -ErrorAction SilentlyContinue
        if (-not $svc) { continue }
        $wrapper = Join-Path $PrivateBinDir "$svcName-service.exe"
        if ($svc.PathName -notlike "*$wrapper*") {
            Write-Warning "Service '$svcName' is not managed by hikari ($($svc.PathName)); leaving it untouched."
            continue
        }
        if ($DryRun) {
            Write-Host "[dry-run] Would stop and remove service $svcName"
            continue
        }
        $s = Get-Service -Name $svcName
        if ($s.Status -ne "Stopped") {
            Stop-Service -Name $svcName -Force
            $s.WaitForStatus("Stopped", [TimeSpan]::FromSeconds(30))
        }
        if (Test-Path $wrapper) { & $wrapper uninstall | Out-Null } else { & sc.exe delete $svcName | Out-Null }
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
Remove-SafePath (Join-Path $ConfigDir "Caddyfile")
Remove-SafePath (Join-Path $ConfigDir "Caddyfile.bak")
Remove-SafePath (Join-Path $ConfigDir "Caddyfile.new")
Remove-SafePath (Join-Path $ConfigDir "hikari-snippet.caddy")
Remove-SafePath (Join-Path $ConfigDir "hikari-service.xml")
Remove-SafePath (Join-Path $ConfigDir "hikari-caddy-service.xml")

if ($Purge) {
    Remove-SafePath $ProgramDataBase
    Write-Host "Uninstalled hikari and purged configuration/state under $ProgramDataBase."
} else {
    Write-Host "Uninstalled hikari services and binaries. Preserved $ConfigDir\config.json and $StateDir (pass -Purge to remove)."
}
