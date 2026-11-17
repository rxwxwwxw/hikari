# Windows installer smoke test (run in PowerShell on Windows runner or physical host)
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Resolve-Path (Join-Path $ScriptDir "..\..\..")
$BinExe = Join-Path $RepoRoot "bin\hikari.exe"

if (-not (Test-Path $BinExe)) {
    throw "Build bin\hikari.exe first using dub build --compiler=ldc2"
}

$TmpRoot = Join-Path $env:TEMP ("hikari-win-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $TmpRoot | Out-Null

try {
    $Fixture = Join-Path $RepoRoot "tests\fixtures\tailscale\online_fleet.json"

    # 1. Dry-run creates zero files
    & "$RepoRoot\install\install.ps1" -DryRun -Root $TmpRoot -BinarySource $BinExe -TailscaleFixture $Fixture -ServiceMode skip
    if (Test-Path (Join-Path $TmpRoot "ProgramData\hikari")) {
        throw "DryRun must not write files"
    }

    # 2. Isolated clean install + config preservation on -Repair
    $MockCaddy = Join-Path $TmpRoot "mock-caddy.cmd"
    Set-Content -Path $MockCaddy -Value "@echo off`r`nexit /b 0`r`n"
    & "$RepoRoot\install\install.ps1" -Root $TmpRoot -BinarySource $BinExe -CaddyBin $MockCaddy -TailscaleFixture $Fixture -ServiceMode skip

    $CfgPath = Join-Path $TmpRoot "ProgramData\hikari\config\config.json"
    if (-not (Test-Path $CfgPath)) { throw "Missing config.json" }
    if (-not (Test-Path (Join-Path $TmpRoot "ProgramData\hikari\config\Caddyfile"))) { throw "Missing Caddyfile" }
    if (-not (Test-Path (Join-Path $TmpRoot "ProgramData\hikari\config\hikari-service.xml"))) { throw "Missing WinSW XML" }

    $cfg = Get-Content -Raw $CfgPath | ConvertFrom-Json
    $cfg | Add-Member -NotePropertyName "operator_keep" -NotePropertyValue "yes"
    $cfg | ConvertTo-Json -Depth 6 | Set-Content -Path $CfgPath

    & "$RepoRoot\install\install.ps1" -Repair -Root $TmpRoot -BinarySource $BinExe -CaddyBin $MockCaddy -TailscaleFixture $Fixture -ServiceMode skip
    $cfgAfter = Get-Content -Raw $CfgPath | ConvertFrom-Json
    if ($cfgAfter.operator_keep -ne "yes") { throw "Repair must preserve operator config" }

    # 3. Uninstall preserves config, -Purge removes all
    & "$RepoRoot\install\uninstall.ps1" -Root $TmpRoot -ServiceMode skip
    if (-not (Test-Path $CfgPath)) { throw "Uninstall must preserve config.json" }
    & "$RepoRoot\install\uninstall.ps1" -Purge -Root $TmpRoot -ServiceMode skip
    if (Test-Path (Join-Path $TmpRoot "ProgramData\hikari")) { throw "Purge must remove ProgramData\hikari" }

    Write-Host "Windows installer smoke test PASSED."
} finally {
    if (Test-Path $TmpRoot) { Remove-Item -Recurse -Force $TmpRoot }
}
