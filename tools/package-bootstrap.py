#!/usr/bin/env python3
"""Build standalone, reviewable bootstrap entry points with embedded trust/verifier."""
import base64
import json
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
out = Path(sys.argv[1] if len(sys.argv) > 1 else 'dist/bootstrap')
out.mkdir(parents=True, exist_ok=True)
source = (root / 'install/bootstrap.py').read_text()
start = source.index('HERE = ')
end = source.index('\n\nclass HttpsRedirect', start)
trust = json.loads((root / 'install/trust.json').read_text())
verifier = (root / 'install/verify-release.py').read_text()
source = source[:start] + ('import types\nverifier = types.ModuleType("release_verifier")\n'
    + f'exec({verifier!r}, verifier.__dict__)\nTRUST = {trust!r}\n') + source[end:]
source = source.replace("json.loads((HERE / 'trust.json').read_text())", 'TRUST')
(out / 'hikari-install.sh').write_text('''#!/usr/bin/env bash
set -euo pipefail
command -v python3 >/dev/null || { echo "Python 3.9+ is required; install it and rerun." >&2; exit 1; }
exec python3 - "$@" <<'HIKARI_BOOTSTRAP_PYTHON'
''' + source + '\nHIKARI_BOOTSTRAP_PYTHON\n')
(out / 'hikari-install.sh').chmod(0o755)
payload = base64.b64encode(source.encode()).decode()
(out / 'hikari-install.ps1').write_text('''# Standalone bootstrap: embedded pinned trust and verifier, no remote script execution.
[CmdletBinding()]
param(
    [string]$Version = "latest",
    [switch]$DryRun,
    [switch]$Repair,
    [switch]$Reload,
    [ValidateSet("", "auto", "integrate", "isolated", "snippet")]
    [string]$CaddyMode = "",
    [string[]]$InstallerArguments = @()
)
$ErrorActionPreference = "Stop"
if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
    throw "Python 3.9+ is required; install it and rerun."
}
$script = Join-Path ([System.IO.Path]::GetTempPath()) ("hikari-bootstrap-" + [guid]::NewGuid().ToString("N") + ".py")
try {
    [System.IO.File]::WriteAllBytes($script, [Convert]::FromBase64String("''' + payload + '''"))
    $bootstrapArgs = @($script, "--version", $Version)
    if ($DryRun) { $bootstrapArgs += "--dry-run" }
    if ($Repair) { $bootstrapArgs += "--repair" }
    if ($Reload) { $bootstrapArgs += "--reload" }
    if ($CaddyMode) { $bootstrapArgs += @("--caddy-mode", $CaddyMode) }
    if ($InstallerArguments.Count) { $bootstrapArgs += "--"; $bootstrapArgs += $InstallerArguments }
    & python @bootstrapArgs
    $result = $LASTEXITCODE
} finally {
    Remove-Item -LiteralPath $script -Force -ErrorAction SilentlyContinue
}
exit $result
''')
