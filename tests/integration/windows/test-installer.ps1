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

    $Ver = (Get-Content -Raw (Join-Path $RepoRoot "VERSION")).Trim()
    $Versions = Join-Path $TmpRoot "ProgramData\hikari\versions"
    if (-not (Test-Path (Join-Path $Versions "current\hikari.exe"))) { throw "versions\current junction does not resolve to hikari.exe" }
    if ((Get-Content -Raw (Join-Path $Versions "current.txt")).Trim() -ne $Ver) { throw "current.txt pointer mismatch" }
    $cfgRaw = [System.IO.File]::ReadAllBytes($CfgPath)
    if ($cfgRaw[0] -eq 0xEF) { throw "config.json must be written without a UTF-8 BOM" }
    & $BinExe version | Out-Null

    # Identical reinstall must not replace the release (never touch a possibly running .exe).
    $exeBefore = (Get-Item (Join-Path $Versions "$Ver\hikari.exe")).LastWriteTimeUtc.Ticks
    $dirBefore = (Get-Item (Join-Path $Versions $Ver)).CreationTimeUtc.Ticks
    & "$RepoRoot\install\install.ps1" -Repair -Root $TmpRoot -BinarySource $BinExe -CaddyBin $MockCaddy -TailscaleFixture $Fixture -ServiceMode skip
    if ((Get-Item (Join-Path $Versions $Ver)).CreationTimeUtc.Ticks -ne $dirBefore) { throw "Identical reinstall replaced the release directory" }
    if ((Get-Item (Join-Path $Versions "$Ver\hikari.exe")).LastWriteTimeUtc.Ticks -ne $exeBefore) { throw "Identical reinstall rewrote hikari.exe" }
    foreach ($stray in @("current.new", "current.old")) {
        if (Test-Path (Join-Path $Versions $stray)) { throw "Stray junction left behind: $stray" }
    }

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
