<#
.SYNOPSIS
Live Service Control Manager test for hikari's native Windows service support.

.DESCRIPTION
Requires an elevated session (GitHub's Windows runners are elevated). Registers throwaway
services named hikari-citest / hikari-caddy-citest from a temporary directory, exercises
start, health, restricted-token hardware scan, crash recovery, idempotent reinstall, foreign
service refusal, clean stop, Caddy as a native service, and uninstall. Everything it creates
is removed in `finally`, even on failure.

.PARAMETER CaddyExe
Path to a caddy.exe for the native Caddy service gate. Omit to skip that part
(use -RequireCaddy in CI so a missing binary fails the run).
#>
[CmdletBinding()]
param(
    [string]$CaddyExe = "",
    [switch]$RequireCaddy
)

$ErrorActionPreference = "Stop"
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "test-service.ps1 must run elevated (it creates and removes real services)."
}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Resolve-Path (Join-Path $ScriptDir "..\..\..")
$BuiltExe = Join-Path $RepoRoot "bin\hikari.exe"
if (-not (Test-Path $BuiltExe)) { throw "Build bin\hikari.exe first (dub build --compiler=ldc2)" }

$Svc = "hikari-citest"
$CaddySvc = "hikari-caddy-citest"
$ForeignSvc = "hikari-citest-foreign"
$AgentPort = 19650
$CaddyPort = 19652
$UserCaddySvc = "hikari-usercaddy-citest"
$UserSitePort = 19661
$UserAdminPort = 19662
$JoinPort = 19663

# Under ProgramData (not the user profile) so the virtual service account can read the exe.
$Root = Join-Path $env:ProgramData ("hikari-citest-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
$BinDir = Join-Path $Root "bin"
$ConfigDir = Join-Path $Root "config"
$StateDir = Join-Path $Root "state"
$LogsDir = Join-Path $Root "logs"
$Exe = Join-Path $BinDir "hikari.exe"
$Cfg = Join-Path $ConfigDir "config.json"
$Caddyfile = Join-Path $ConfigDir "Caddyfile"

function Step([string]$m) { Write-Host "--- $m" }
function Fail([string]$m) { throw "FAILED: $m" }

function Invoke-Hikari([string[]]$HArgs) {
    $ErrorActionPreference = "Continue"
    $out = (& $Exe @HArgs 2>&1 | ForEach-Object { "$_" }) -join "`n"
    return @{ Code = $LASTEXITCODE; Out = $out }
}

function Wait-Until([scriptblock]$Cond, [int]$Seconds, [string]$What) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        try { if (& $Cond) { return } } catch {}
        Start-Sleep -Milliseconds 500
    }
    Fail "timed out after ${Seconds}s waiting for: $What"
}

function Get-Http([string]$Url) {
    $ErrorActionPreference = "Continue"
    $body = & curl.exe -k -s --max-time 5 -w "`n%{http_code}" $Url 2>$null
    $text = ($body -join "`n")
    $idx = $text.LastIndexOf("`n")
    return @{ Code = $text.Substring($idx + 1); Body = $text.Substring(0, [Math]::Max(0, $idx)) }
}

function Remove-TestService([string]$Name) {
    $s = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if ($s) {
        if ($s.Status -ne "Stopped") { Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue }
        & sc.exe delete $Name | Out-Null
    }
}

try {
    New-Item -ItemType Directory -Force -Path $BinDir, $ConfigDir, $StateDir, $LogsDir | Out-Null
    Copy-Item $BuiltExe $Exe
    $cfgObj = @{
        schema_version = 1
        listen = @{ loopback_port = $AgentPort; loopback_bind = "127.0.0.1"; tailnet_port = 19651; base_path = "/" }
        paths = @{ state_dir = $StateDir; config_dir = $ConfigDir; versions_dir = (Join-Path $Root "versions"); web_dir = (Join-Path $Root "web") }
    }
    [System.IO.File]::WriteAllText($Cfg, ($cfgObj | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding($false)))

    Step "console invocation of --service is rejected with exit 2"
    $r = Invoke-Hikari @("serve", "--service", "--config", $Cfg)
    if ($r.Code -ne 2) { Fail "expected exit 2, got $($r.Code): $($r.Out)" }

    Step "install agent service (virtual account)"
    $r = Invoke-Hikari @("service", "install", "--name", $Svc, "--kind", "agent", "--config", $Cfg, "--exe", $Exe)
    if ($r.Code -ne 0 -or $r.Out -notmatch ": created") { Fail "install: $($r.Out)" }
    & icacls.exe $ConfigDir /grant:r "NT SERVICE\${Svc}:(OI)(CI)R" | Out-Null
    & icacls.exe $StateDir /grant:r "NT SERVICE\${Svc}:(OI)(CI)M" | Out-Null
    & icacls.exe $LogsDir /grant:r "NT SERVICE\${Svc}:(OI)(CI)M" | Out-Null

    Step "reinstall with identical arguments is a no-op"
    $r = Invoke-Hikari @("service", "install", "--name", $Svc, "--kind", "agent", "--config", $Cfg, "--exe", $Exe)
    if ($r.Code -ne 0 -or $r.Out -notmatch ": unchanged") { Fail "idempotent install: $($r.Out)" }

    Step "SCM configuration: account, start type, recovery, privileges, SID type"
    $qc = (& sc.exe qc $Svc) -join "`n"
    if ($qc -notmatch [regex]::Escape("NT SERVICE\$Svc")) { Fail "account not virtual:`n$qc" }
    if ($qc -notmatch "AUTO_START") { Fail "not auto start:`n$qc" }
    if ($qc -notmatch [regex]::Escape("`"$Exe`" serve --service --config")) { Fail "unexpected command line:`n$qc" }
    $qf = (& sc.exe qfailure $Svc) -join "`n"
    if ($qf -notmatch "RESET_PERIOD \(in seconds\)\s*:\s*3600" -or $qf -notmatch "RESTART -- Delay = 5000") { Fail "recovery actions:`n$qf" }
    $qff = (& sc.exe qfailureflag $Svc) -join "`n"
    if ($qff -notmatch "TRUE") { Fail "failure-actions flag not set:`n$qff" }
    $qp = (& sc.exe qprivs $Svc) -join "`n"
    if ($qp -notmatch "SeChangeNotifyPrivilege" -or ($qp -split "`n" | Where-Object { $_ -match "Se[A-Za-z]+Privilege" }).Count -ne 1) { Fail "privileges not minimal:`n$qp" }
    $qs = (& sc.exe qsidtype $Svc) -join "`n"
    if ($qs -notmatch "UNRESTRICTED") { Fail "service SID type:`n$qs" }

    Step "start: RUNNING, /healthz, startup line in service log"
    $r = Invoke-Hikari @("service", "start", "--name", $Svc)
    if ($r.Code -ne 0) { Fail "start: $($r.Out)" }
    Wait-Until { (Get-Http "http://127.0.0.1:$AgentPort/healthz").Code -eq "200" } 20 "agent /healthz"
    $logFile = Join-Path $LogsDir "hikari.log"
    Wait-Until { (Test-Path $logFile) -and ((Get-Content -Raw $logFile) -match "listening on http://127.0.0.1:$AgentPort") } 10 "startup line in $logFile"

    Step "hardware scan works under the restricted service token"
    Wait-Until {
        $h = Get-Http "http://127.0.0.1:$AgentPort/api/v1/hardware"
        $h.Code -eq "200" -and $h.Body -match '"display_name"' -and $h.Body -match '"capabilities"'
    } 30 "/api/v1/hardware 200"
    $st = Get-Http "http://127.0.0.1:$AgentPort/api/v1/status"
    if ($st.Code -ne "200" -and $st.Code -ne "202") { Fail "/api/v1/status returned $($st.Code)" }

    if ($CaddyExe -or $RequireCaddy) {
        if (-not $CaddyExe -or -not (Test-Path $CaddyExe)) { Fail "-RequireCaddy set but caddy.exe not found: '$CaddyExe'" }
        Step "Caddy runs as a native service (gate for dropping any wrapper)"
        $caddyStore = ($StateDir -replace '\\', '/') + "/caddy"
        $caddyLog = ($LogsDir -replace '\\', '/') + "/caddy.log"
        $cf = @"
{
	admin off
	auto_https disable_redirects
	skip_install_trust
	storage file_system $caddyStore
	log {
		output file $caddyLog
	}
}

https://localhost:$CaddyPort {
	bind 127.0.0.1
	tls internal
	reverse_proxy 127.0.0.1:$AgentPort
}
"@
        [System.IO.File]::WriteAllText($Caddyfile, $cf, (New-Object System.Text.UTF8Encoding($false)))
        $r = Invoke-Hikari @("service", "install", "--name", $CaddySvc, "--kind", "caddy", "--caddy", (Resolve-Path $CaddyExe).Path, "--caddyfile", $Caddyfile)
        if ($r.Code -ne 0 -or $r.Out -notmatch ": created") { Fail "caddy install: $($r.Out)" }
        $qc2 = (& sc.exe qc $CaddySvc) -join "`n"
        if ($qc2 -notmatch "DELAYED") { Fail "caddy service not delayed auto-start:`n$qc2" }
        $r = Invoke-Hikari @("service", "start", "--name", $CaddySvc)
        if ($r.Code -ne 0) { Fail "Caddy did not reach RUNNING as a native service: $($r.Out)" }
        Wait-Until { (Get-Http "https://localhost:$CaddyPort/healthz").Body -match '"app":"hikari"' } 30 "HTTPS via Caddy service to the agent"
        $r = Invoke-Hikari @("service", "stop", "--name", $CaddySvc)
        if ($r.Code -ne 0) { Fail "caddy stop: $($r.Out)" }
        $r = Invoke-Hikari @("service", "uninstall", "--name", $CaddySvc, "--kind", "caddy", "--caddyfile", $Caddyfile)
        if ($r.Code -ne 0) { Fail "caddy uninstall: $($r.Out)" }

        Step "joining a running user Caddy service: reload, rollback on failed reload, unjoin"
        # A "user" Caddy that hikari did not install, running as its own Windows service.
        $UserDir = Join-Path $Root "user-caddy"
        New-Item -ItemType Directory -Force -Path $UserDir | Out-Null
        $UserCf = Join-Path $UserDir "Caddyfile"
        $userStore = ($UserDir -replace '\\', '/') + "/storage"
        # Keep this disposable service on its allocated ports: adding an HTTPS
        # site must not make the fixture attempt the runner's reserved port 80.
        $userCfText = "{`n`tadmin localhost:$UserAdminPort`n`tauto_https disable_redirects`n`tstorage file_system $userStore`n`tskip_install_trust`n}`n`nhttp://:$UserSitePort {`n`tbind 127.0.0.1`n`trespond `"user site`"`n}`n"
        [System.IO.File]::WriteAllText($UserCf, $userCfText, (New-Object System.Text.UTF8Encoding($false)))
        $origUserHash = (Get-FileHash $UserCf).Hash
        & sc.exe create $UserCaddySvc binPath= "`"$((Resolve-Path $CaddyExe).Path)`" run --config `"$UserCf`" --adapter caddyfile" start= demand | Out-Null
        Start-Service $UserCaddySvc
        Wait-Until { (Get-Http "http://127.0.0.1:$UserSitePort/").Body -match "user site" } 30 "user Caddy serving its own site"
        $join = @("caddy", "integrate", "--caddyfile", $UserCf, "--caddy", (Resolve-Path $CaddyExe).Path, "--fqdn", "hikari-citest.localhost",
            "--tailscale-ip", "127.0.0.1", "--port", "$JoinPort", "--config", (Join-Path $Root "none.json"), "--state-dir", $StateDir, "--web-dir", $UserDir, "--json")

        # 1. A reload that fails (hikari's port is taken) restores the original file and keeps the user site up.
        $blocker = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Parse("127.0.0.1"), $JoinPort)
        $blocker.Start()
        try {
            $r = Invoke-Hikari ($join + @("--reload"))
            if ($r.Out -notmatch '"ok":\s*false' -or $r.Out -notmatch "restored original") { Fail "failed reload should roll back: $($r.Out)" }
        } finally { $blocker.Stop() }
        if ((Get-FileHash $UserCf).Hash -ne $origUserHash) { Fail "rollback after a failed reload did not restore the user Caddyfile" }
        if (Test-Path (Join-Path $UserDir "hikari.caddy")) { Fail "rollback left hikari.caddy behind" }
        if ((Get-Http "http://127.0.0.1:$UserSitePort/").Body -notmatch "user site") { Fail "user site down after rollback" }

        # 2. A successful join with reload: hikari's listener comes up inside the user's Caddy.
        $r = Invoke-Hikari ($join + @("--reload"))
        if ($r.Out -notmatch '"ok":\s*true' -or $r.Out -notmatch "reloaded") { Fail "join with reload failed: $($r.Out)" }
        Wait-Until { (Get-NetTCPConnection -State Listen -LocalPort $JoinPort -ErrorAction SilentlyContinue | Where-Object { $_.LocalAddress -eq "127.0.0.1" }) } 15 "hikari listener inside the user Caddy"
        if ((Get-Http "http://127.0.0.1:$UserSitePort/").Body -notmatch "user site") { Fail "user site broken after join" }
        $st = Invoke-Hikari @("caddy", "status", "--config", (Join-Path $Root "none.json"), "--state-dir", $StateDir, "--json")
        if ($st.Out -notmatch '"manager":\s*"scm"' -or $st.Out -notmatch [regex]::Escape($UserCaddySvc)) { Fail "integration record should name the user Caddy service: $($st.Out)" }

        # 3. Unjoin with reload: file byte-identical, hikari's listener gone, user site still up.
        $r = Invoke-Hikari @("caddy", "unintegrate", "--config", (Join-Path $Root "none.json"), "--state-dir", $StateDir, "--reload", "--json")
        if ($r.Out -notmatch '"ok":\s*true') { Fail "unjoin failed: $($r.Out)" }
        if ((Get-FileHash $UserCf).Hash -ne $origUserHash) { Fail "unjoin did not restore the user Caddyfile byte for byte" }
        Wait-Until { -not (Get-NetTCPConnection -State Listen -LocalPort $JoinPort -ErrorAction SilentlyContinue) } 15 "hikari listener removed from the user Caddy"
        if ((Get-Http "http://127.0.0.1:$UserSitePort/").Body -notmatch "user site") { Fail "user site broken after unjoin" }
        Stop-Service $UserCaddySvc
    } else {
        Write-Host "--- (skipping Caddy gate: pass -CaddyExe <caddy.exe>)"
    }

    Step "crash recovery: SCM restarts a killed agent"
    $pid1 = (Get-CimInstance Win32_Service -Filter "Name='$Svc'").ProcessId
    Stop-Process -Id $pid1 -Force
    Wait-Until {
        $s = Get-CimInstance Win32_Service -Filter "Name='$Svc'"
        $s.State -eq "Running" -and $s.ProcessId -ne 0 -and $s.ProcessId -ne $pid1
    } 30 "automatic restart after crash"
    Wait-Until { (Get-Http "http://127.0.0.1:$AgentPort/healthz").Code -eq "200" } 20 "agent healthy after restart"

    Step "foreign service with a colliding name is refused and left intact"
    & sc.exe create $ForeignSvc binPath= "C:\Windows\System32\cmd.exe /c exit 0" start= demand | Out-Null
    $r = Invoke-Hikari @("service", "install", "--name", $ForeignSvc, "--kind", "agent", "--config", $Cfg, "--exe", $Exe)
    if ($r.Code -eq 0 -or $r.Out -notmatch "not managed") { Fail "foreign service was not refused: $($r.Out)" }
    $r = Invoke-Hikari @("service", "uninstall", "--name", $ForeignSvc, "--kind", "agent", "--config", $Cfg)
    if ($r.Code -eq 0) { Fail "foreign service uninstall was not refused" }
    if ((Get-CimInstance Win32_Service -Filter "Name='$ForeignSvc'").PathName -notmatch "cmd.exe") { Fail "foreign service was modified" }

    Step "clean stop: STOPPED with exit code 0, stop line logged"
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-Hikari @("service", "stop", "--name", $Svc)
    if ($r.Code -ne 0) { Fail "stop: $($r.Out)" }
    if ($sw.Elapsed.TotalSeconds -gt 15) { Fail "stop took $($sw.Elapsed.TotalSeconds)s" }
    $svcInfo = Get-CimInstance Win32_Service -Filter "Name='$Svc'"
    if ($svcInfo.ExitCode -ne 0) { Fail "service exit code $($svcInfo.ExitCode) (specific $($svcInfo.ServiceSpecificExitCode))" }
    if ((Get-Content -Raw $logFile) -notmatch "hikari stopped") { Fail "no clean-stop line in log" }

    Step "uninstall removes the service"
    $r = Invoke-Hikari @("service", "uninstall", "--name", $Svc, "--kind", "agent", "--config", $Cfg)
    if ($r.Code -ne 0 -or $r.Out -notmatch ": removed") { Fail "uninstall: $($r.Out)" }
    $r = Invoke-Hikari @("service", "status", "--name", $Svc)
    if ($r.Out -notmatch "absent") { Fail "service still present after uninstall: $($r.Out)" }

    Write-Host "Windows native service test PASSED."
} finally {
    foreach ($n in @($UserCaddySvc, $CaddySvc, $Svc, $ForeignSvc)) { Remove-TestService $n }
    if (Test-Path $Root) { Remove-Item -Recurse -Force $Root -ErrorAction SilentlyContinue }
}
