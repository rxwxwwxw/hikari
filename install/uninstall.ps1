<#
.SYNOPSIS
Uninstaller for hikari on Windows.
Stops and removes only hikari and hikari-caddy services and binaries.
Preserves config and state unless -Purge is specified. Never modifies Tailscale or unrelated Caddy installations.
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

if (-not $Root -and -not $DryRun -and $ServiceMode -eq "auto") {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "System uninstall requires Administrator privileges (or pass -DryRun / -Root)."
    }
}

if ($ServiceMode -eq "auto") {
    foreach ($svcExe in @("hikari-caddy-service.exe", "hikari-service.exe")) {
        $p = Join-Path $PrivateBinDir $svcExe
        if (Test-Path $p) {
            if ($DryRun) {
                Write-Host "[dry-run] Would stop and uninstall service via $p"
            } else {
                & $p stop 2>$null | Out-Null
                & $p uninstall 2>$null | Out-Null
            }
        }
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

Remove-SafePath (Join-Path $VersionsDir "current")
Remove-SafePath $VersionsDir
Remove-SafePath $PrivateBinDir
Remove-SafePath (Join-Path $ConfigDir "Caddyfile")
Remove-SafePath (Join-Path $ConfigDir "Caddyfile.bak")
Remove-SafePath (Join-Path $ConfigDir "hikari-snippet.caddy")
Remove-SafePath (Join-Path $ConfigDir "hikari-service.xml")
Remove-SafePath (Join-Path $ConfigDir "hikari-caddy-service.xml")

if ($Purge) {
    Remove-SafePath $ProgramDataBase
    Write-Host "Uninstalled hikari and purged configuration/state under $ProgramDataBase."
} else {
    Write-Host "Uninstalled hikari services and binaries. Preserved $ConfigDir\config.json and $StateDir (pass -Purge to remove)."
}
