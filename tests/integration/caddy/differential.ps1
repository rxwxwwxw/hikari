<#
.SYNOPSIS
Replays the Caddyfile fixture corpus against a real Caddy binary.

.DESCRIPTION
For every fixture in tests/fixtures/caddyfiles/expectations.json:
  1. hikari's parser and `caddy adapt` must agree on success/failure and on the set of
     listener addresses.
  2. For every fixture hikari would integrate into: a verified `hikari caddy integrate`
     (which itself requires the original config to be preserved exactly), then
     `hikari caddy unintegrate`, which must restore the main Caddyfile byte for byte.
Works on a copy of the corpus; never touches a real Caddy installation.

.PARAMETER Caddy
caddy executable (required; the script fails if it is missing).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Caddy,
    [string]$Hikari = ""
)

$ErrorActionPreference = "Stop"
$RepoRoot = Resolve-Path (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "..\..\..")
if (-not $Hikari) { $Hikari = Join-Path $RepoRoot $(if ($IsWindows -or $env:OS -eq "Windows_NT") { "bin\hikari.exe" } else { "bin/hikari" }) }
if (-not (Test-Path $Caddy)) { throw "caddy binary not found: $Caddy" }
if (-not (Test-Path $Hikari)) { throw "hikari binary not found: $Hikari (build first)" }
$Caddy = (Resolve-Path $Caddy).Path

$Corpus = Join-Path $RepoRoot "tests/fixtures/caddyfiles"
$Ex = Get-Content -Raw (Join-Path $Corpus "expectations.json") | ConvertFrom-Json
$Work = Join-Path ([IO.Path]::GetTempPath()) ("hikari-caddy-diff-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
$NoConfig = Join-Path $Work "no-config.json"
$failures = @()

function Invoke-HikariJson([string[]]$HArgs) {
    $ErrorActionPreference = "Continue"
    $diagnostics = Join-Path $Work "stderr.txt"
    $out = (& $Hikari @HArgs 2> $diagnostics | ForEach-Object { "$_" }) -join "`n"
    $start = $out.IndexOf("{")
    if ($start -lt 0) { throw "no JSON from hikari $($HArgs -join ' '):`n$out" }
    return ($out.Substring($start) | ConvertFrom-Json)
}

function Get-Bytes([string]$p) { return [Convert]::ToBase64String([IO.File]::ReadAllBytes($p)) }

try {
    New-Item -ItemType Directory -Force -Path $Work | Out-Null
    $common = @("--caddy", $Caddy, "--fqdn", $Ex.fqdn, "--tailscale-ip", $Ex.tailscale_ip, "--port", "$($Ex.port)", "--config", $NoConfig, "--state-dir", (Join-Path $Work "state"), "--json")

    foreach ($f in $Ex.fixtures) {
        $mode = if ($f.PSObject.Properties.Name -contains "adapt") { $f.adapt } else { "compare" }
        if ($mode -eq "skip") { Write-Host "skip   $($f.file)"; continue }
        $path = Join-Path $Corpus $f.file
        $j = Invoke-HikariJson (@("caddy", "inspect", "--caddyfile", $path) + $common)

        if ($mode -eq "fail") {
            if ($j.caddy_adapt_ok) { $failures += "$($f.file): caddy adapt succeeded but hikari expects a broken config" }
            elseif ($j.verdict -ne "isolated") { $failures += "$($f.file): verdict should be isolated for a config Caddy rejects" }
            else { Write-Host "ok     $($f.file) (both reject)" }
            continue
        }
        if (-not $j.caddy_adapt_ok) { $failures += "$($f.file): caddy adapt failed: $($j.caddy_adapt_error)"; continue }
        if ($mode -ne "skip_listeners") {
            $mine = @($j.parser_listeners | Sort-Object) -join ","
            $theirs = @($j.caddy_listeners | Sort-Object -Unique) -join ","
            if ($mine -ne $theirs) { $failures += "$($f.file): listeners differ: hikari [$mine] vs caddy [$theirs]"; continue }
        }
        Write-Host "ok     $($f.file) listeners [$(@($j.caddy_listeners) -join ',')]"
    }

    # Integration round trip on a scratch copy of the corpus.
    $copy = Join-Path $Work "corpus"
    Copy-Item -Recurse $Corpus $copy
    $web = Join-Path $Work "web"
    New-Item -ItemType Directory -Force -Path $web | Out-Null
    foreach ($f in $Ex.fixtures) {
        if ($f.verdict -ne "integrate") { continue }
        $mode = if ($f.PSObject.Properties.Name -contains "adapt") { $f.adapt } else { "compare" }
        if ($mode -eq "skip" -or $mode -eq "fail") { continue }
        $main = Join-Path $copy $f.file
        $before = Get-Bytes $main
        $r = Invoke-HikariJson (@("caddy", "integrate", "--caddyfile", $main, "--web-dir", $web) + $common)
        if (-not $r.ok -or -not $r.verified) { $failures += "$($f.file): integrate failed: $($r.message) $(@($r.problems) -join '; ')"; continue }
        if ($r.mode -eq "drop_in" -and (Get-Bytes $main) -ne $before) { $failures += "$($f.file): drop-in mode modified the main Caddyfile"; continue }
        if (-not (Test-Path $r.site_file)) { $failures += "$($f.file): site file missing after integrate"; continue }
        $again = Invoke-HikariJson (@("caddy", "integrate", "--caddyfile", $main, "--web-dir", $web) + $common)
        if (-not $again.ok -or $again.changed) { $failures += "$($f.file): second integrate was not a no-op: $($again.message)"; continue }
        $u = Invoke-HikariJson (@("caddy", "unintegrate", "--caddyfile", $main) + $common)
        if (-not $u.ok) { $failures += "$($f.file): unintegrate failed: $($u.message)"; continue }
        $expectedOriginal = if ($f.PSObject.Properties.Name -contains "original") {
            [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($f.original))
        } else { $before }
        if ((Get-Bytes $main) -ne $expectedOriginal) { $failures += "$($f.file): unintegrate did not restore the original bytes"; continue }
        if (Test-Path $r.site_file) { $failures += "$($f.file): site file left behind after unintegrate"; continue }
        Write-Host "ok     $($f.file) integrate/unintegrate round trip ($($r.mode))"
    }
} finally {
    if (Test-Path $Work) { Remove-Item -Recurse -Force $Work -ErrorAction SilentlyContinue }
}

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Host "FAIL   $_" }
    throw "$($failures.Count) differential check(s) failed"
}
Write-Host "Caddy differential test PASSED."
