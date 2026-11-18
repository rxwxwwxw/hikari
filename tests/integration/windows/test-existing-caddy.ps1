<#
.SYNOPSIS
Installer test for the "existing Caddy" path, against a throwaway user Caddyfile.

.DESCRIPTION
Runs install.ps1 / uninstall.ps1 in -Root mode (no services) with -ExistingCaddyfile pointing
at a scratch "user" Caddyfile, and a real caddy.exe for verification. Checks that:
  * auto mode joins the existing Caddy: the user file only gains the marked block, and the
    site file and state record are written; no isolated Caddyfile is generated;
  * a repeat install changes nothing;
  * switching to -CaddyMode isolated restores the user file byte for byte;
  * switching back and uninstalling restores it byte for byte again;
  * a conflicting Caddyfile makes auto fall back to isolated and stay untouched;
  * -CaddyMode integrate on a conflicting Caddyfile fails before writing anything.

.PARAMETER CaddyExe
Real caddy.exe (required: integration is refused without a binary to verify with).
#>
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$CaddyExe)

$ErrorActionPreference = "Stop"
$RepoRoot = Resolve-Path (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "..\..\..")
$BinExe = Join-Path $RepoRoot "bin\hikari.exe"
if (-not (Test-Path $BinExe)) { throw "Build bin\hikari.exe first" }
if (-not (Test-Path $CaddyExe)) { throw "caddy.exe not found: $CaddyExe" }
$CaddyExe = (Resolve-Path $CaddyExe).Path
$Fixture = Join-Path $RepoRoot "tests\fixtures\tailscale\online_fleet.json"
$Install = Join-Path $RepoRoot "install\install.ps1"
$Uninstall = Join-Path $RepoRoot "install\uninstall.ps1"

$Tmp = Join-Path $env:TEMP ("hikari-existing-caddy-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
$Root = Join-Path $Tmp "root"
$UserDir = Join-Path $Tmp "user-caddy"
$UserCaddyfile = Join-Path $UserDir "Caddyfile"
$State = Join-Path $Root "ProgramData\hikari\state"
$Record = Join-Path $State "caddy-integration.json"
$IsolatedCaddyfile = Join-Path $Root "ProgramData\hikari\config\Caddyfile"

function Fail([string]$m) { throw "FAILED: $m" }
function Hash([string]$p) { return (Get-FileHash -Algorithm SHA256 $p).Hash }
function Run-Install([hashtable]$Extra = @{}) {
    & $Install -Root $Root -BinarySource $BinExe -TailscaleFixture $Fixture -ServiceMode skip -CaddyBin $CaddyExe `
        -ExistingCaddyfile $UserCaddyfile -ExistingCaddyBin $CaddyExe @Extra | Out-Host
}

try {
    New-Item -ItemType Directory -Force -Path $UserDir | Out-Null
    # A realistic user config: CRLF, several sites, a snippet, and no final newline.
    $orig = "{`r`n`temail ops@example.com`r`n}`r`n`r`n(common) {`r`n`tencode gzip`r`n}`r`n`r`nexample.com {`r`n`timport common`r`n`treverse_proxy 127.0.0.1:8080`r`n}`r`n`r`nhttp://intranet.lan {`r`n`trespond `"intranet`"`r`n}"
    [IO.File]::WriteAllText($UserCaddyfile, $orig, (New-Object Text.UTF8Encoding($false)))
    $origHash = Hash $UserCaddyfile

    Write-Host "--- auto mode joins the existing Caddy"
    Run-Install
    $now = [IO.File]::ReadAllText($UserCaddyfile)
    if (-not $now.StartsWith($orig)) { Fail "user Caddyfile bytes before the hikari block changed" }
    if ($now -notmatch "# BEGIN hikari" -or $now -notmatch "import hikari.caddy") { Fail "marked import block missing" }
    if (-not (Test-Path (Join-Path $UserDir "hikari.caddy"))) { Fail "hikari.caddy site file missing" }
    if (-not (Test-Path $Record)) { Fail "integration record missing" }
    if (Test-Path $IsolatedCaddyfile) { Fail "isolated Caddyfile must not be generated when joined" }
    $cfg = Get-Content -Raw (Join-Path $Root "ProgramData\hikari\config\config.json") | ConvertFrom-Json
    if ($cfg.caddy.mode -ne "auto") { Fail "config.json should record caddy.mode=auto" }
    & $CaddyExe adapt --config $UserCaddyfile --adapter caddyfile | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail "joined user Caddyfile no longer adapts" }

    Write-Host "--- repeat install changes nothing"
    $joinedHash = Hash $UserCaddyfile
    Run-Install @{ Repair = $true }
    if ((Hash $UserCaddyfile) -ne $joinedHash) { Fail "repeat install modified the user Caddyfile" }
    if (@(Get-ChildItem $UserDir -Filter "*.hikari-backup-*").Count -ne 1) { Fail "repeat install should not create more backups" }

    Write-Host "--- switching to isolated restores the user Caddyfile"
    Run-Install @{ Repair = $true; CaddyMode = "isolated" }
    if ((Hash $UserCaddyfile) -ne $origHash) { Fail "isolated mode did not restore the original bytes" }
    if (Test-Path (Join-Path $UserDir "hikari.caddy")) { Fail "site file left behind after switching to isolated" }
    if (Test-Path $Record) { Fail "integration record left behind" }
    if (-not (Test-Path $IsolatedCaddyfile)) { Fail "isolated Caddyfile not generated" }

    Write-Host "--- back to auto, then uninstall restores the user Caddyfile"
    Run-Install @{ Repair = $true; CaddyMode = "auto" }
    if ((Hash $UserCaddyfile) -eq $origHash) { Fail "auto mode did not join again" }
    & $Uninstall -Root $Root -ServiceMode skip | Out-Host
    if ((Hash $UserCaddyfile) -ne $origHash) { Fail "uninstall did not restore the original bytes" }
    if (Test-Path (Join-Path $UserDir "hikari.caddy")) { Fail "uninstall left hikari.caddy behind" }
    & $Uninstall -Root $Root -ServiceMode skip -Purge | Out-Host

    Write-Host "--- a conflicting Caddyfile: auto falls back to isolated and is left untouched"
    $conflict = ":9100 {`n`trespond `"someone else`"`n}`n"
    [IO.File]::WriteAllText($UserCaddyfile, $conflict, (New-Object Text.UTF8Encoding($false)))
    $conflictHash = Hash $UserCaddyfile
    Run-Install
    if ((Hash $UserCaddyfile) -ne $conflictHash) { Fail "conflicting user Caddyfile was modified" }
    if (Test-Path $Record) { Fail "no integration record expected on fallback" }
    & $Uninstall -Root $Root -ServiceMode skip -Purge | Out-Host

    Write-Host "--- -CaddyMode integrate on a conflict fails before writing anything"
    $threw = $false
    try { Run-Install @{ CaddyMode = "integrate" } } catch { $threw = $true }
    if (-not $threw) { Fail "-CaddyMode integrate should fail on a conflicting Caddyfile" }
    if (Test-Path (Join-Path $Root "ProgramData\hikari")) { Fail "a failed -CaddyMode integrate must not write anything" }
    if ((Hash $UserCaddyfile) -ne $conflictHash) { Fail "conflicting user Caddyfile was modified" }

    Write-Host "Existing-Caddy installer test PASSED."
} finally {
    if (Test-Path $Tmp) { Remove-Item -Recurse -Force $Tmp -ErrorAction SilentlyContinue }
}
