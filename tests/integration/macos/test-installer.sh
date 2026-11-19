#!/usr/bin/env bash
set -euo pipefail

# macOS LaunchDaemon installer integration test (can run rootlessly on Linux or macOS via --target-os=macos --root)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
HIKARI_BIN="${HIKARI_BIN:-$REPO_ROOT/bin/hikari}"

if [ ! -x "$HIKARI_BIN" ]; then
  echo "hikari binary not found at $HIKARI_BIN" >&2
  exit 1
fi

TMP_ROOT=$(mktemp -d /tmp/hikari-macos-inst-XXXXXX)
cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

MOCK_BIN="$TMP_ROOT/mock-bin"
mkdir -p "$MOCK_BIN"
cat > "$MOCK_BIN/caddy" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "version" ]; then echo "v2.11.9 h1:mock"; exit 0; fi
if [ "$1" = "validate" ]; then exit 0; fi
exit 0
EOF
chmod +x "$MOCK_BIN/caddy"

TS_FIXTURE="$REPO_ROOT/tests/fixtures/tailscale/online_fleet.json"

echo "=== Testing macOS --dry-run ==="
PATH="$MOCK_BIN:$PATH" bash "$REPO_ROOT/install/install.sh" \
  --target-os=macos \
  --dry-run \
  --root "$TMP_ROOT/dry" \
  --binary-source "$HIKARI_BIN" \
  --tailscale-fixture "$TS_FIXTURE" \
  --service-mode=skip >/dev/null
test ! -e "$TMP_ROOT/dry/Library"
test ! -e "$TMP_ROOT/dry/opt"

echo "=== Testing macOS LaunchDaemon clean install & repair ==="
INST="$TMP_ROOT/mac-root"
mkdir -p "$INST"
PATH="$MOCK_BIN:$PATH" bash "$REPO_ROOT/install/install.sh" \
  --target-os=macos \
  --root "$INST" \
  --binary-source "$HIKARI_BIN" \
  --caddy-bin "$MOCK_BIN/caddy" \
  --tailscale-fixture "$TS_FIXTURE" \
  --service-mode=skip >/dev/null

test -x "$INST/opt/hikari/versions/current/hikari"
test -f "$INST/Library/Application Support/hikari/config.json"
test -f "$INST/Library/Application Support/hikari/Caddyfile"
test -f "$INST/Library/LaunchDaemons/io.hikari.recover.plist"
test -f "$INST/Library/LaunchDaemons/io.hikari.agent.plist"
test -f "$INST/Library/LaunchDaemons/io.hikari.maintenance.plist"
test -f "$INST/Library/LaunchDaemons/io.hikari.caddy.plist"
grep -q "<string>io.hikari.agent</string>" "$INST/Library/LaunchDaemons/io.hikari.agent.plist"
grep -q "<key>RunAtLoad</key>" "$INST/Library/LaunchDaemons/io.hikari.agent.plist"
python3 - "$INST" <<'PYTEST'
import pathlib, plistlib, sys
root = pathlib.Path(sys.argv[1])
agent = plistlib.loads((root / "Library/LaunchDaemons/io.hikari.agent.plist").read_bytes())
caddy = plistlib.loads((root / "Library/LaunchDaemons/io.hikari.caddy.plist").read_bytes())
maintenance = plistlib.loads((root / "Library/LaunchDaemons/io.hikari.maintenance.plist").read_bytes())
assert maintenance["StartInterval"] == 300
assert maintenance["WatchPaths"] == ["/Library/Application Support/hikari/state/update-request"]
assert maintenance["ProgramArguments"] == ["/opt/hikari/versions/current/hikari", "update", "maintain", "--config", "/Library/Application Support/hikari/config.json"]
assert "UserName" not in maintenance  # A short-lived root job, separate from telemetry.
assert agent["UserName"] == agent["GroupName"] == "_hikari"
assert caddy["UserName"] == caddy["GroupName"] == "_hikari_caddy"
assert caddy["ProgramArguments"][:2] == ["/bin/bash", "/opt/hikari/versions/current/install/macos-caddy.sh"]
assert agent["WorkingDirectory"] == "/opt/hikari/versions/current"
assert (root / "Library/Application Support/hikari/network-reconcile-seconds").read_text().strip() == "60"
assert agent["RunAtLoad"] and caddy["RunAtLoad"]
PYTEST
if command -v plutil >/dev/null 2>&1; then
  plutil -lint "$INST/Library/LaunchDaemons/io.hikari.agent.plist"
  plutil -lint "$INST/Library/LaunchDaemons/io.hikari.caddy.plist"
fi

# Verify --repair preserves config.json
echo '{"schema_version":1,"listen":{"tailnet_port":9100,"loopback_port":19100,"loopback_bind":"127.0.0.1","base_path":"/"},"mac_custom":"keep"}' > "$INST/Library/Application Support/hikari/config.json"
PATH="$MOCK_BIN:$PATH" bash "$REPO_ROOT/install/install.sh" \
  --target-os=macos \
  --repair \
  --root "$INST" \
  --binary-source "$HIKARI_BIN" \
  --caddy-bin "$MOCK_BIN/caddy" \
  --tailscale-fixture "$TS_FIXTURE" \
  --service-mode=skip >/dev/null
grep -q '"mac_custom":"keep"' "$INST/Library/Application Support/hikari/config.json"

echo "=== Testing standalone Tailscale certificate provider and native opt-out ==="
APP_INFO="$INST/Applications/Tailscale.app/Contents/Info.plist"
mkdir -p "$(dirname "$APP_INFO")"
python3 - "$APP_INFO" <<'PYAPP'
import plistlib, sys
with open(sys.argv[1], "wb") as stream:
    plistlib.dump({"CFBundleIdentifier": "io.tailscale.ipn.macsys"}, stream)
PYAPP
install_macos_fixture() {
  PATH="$MOCK_BIN:$PATH" bash "$REPO_ROOT/install/install.sh" \
    --target-os=macos --repair --root "$INST" --binary-source "$HIKARI_BIN" \
    --caddy-bin "$MOCK_BIN/caddy" --tailscale-fixture "$TS_FIXTURE" --service-mode=skip "$@"
}
install_macos_fixture --dry-run | grep 'Tailscale app CLI' >/dev/null
test ! -e "$INST/Library/LaunchDaemons/io.hikari.certificates.plist"
if install_macos_fixture --caddy-mode=integrate >/dev/null 2>&1; then
  echo 'Standalone app installation unexpectedly selected existing Caddy' >&2; exit 1
fi
install_macos_fixture >/dev/null
python3 - "$INST" <<'PYCERT'
import pathlib, plistlib, stat, sys
root = pathlib.Path(sys.argv[1])
units = root / "Library/LaunchDaemons"
job = plistlib.loads((units / "io.hikari.certificates.plist").read_bytes())
caddy = plistlib.loads((units / "io.hikari.caddy.plist").read_bytes())
store = "/Library/Application Support/hikari/certificates"
assert job["UserName"] == "root" and job["RunAtLoad"] and job["StartInterval"] == 900
assert job["ProgramArguments"][-2:] == [store, "_hikari_caddy"]
assert caddy["ProgramArguments"][-1] == store
assert stat.S_IMODE((root / store.lstrip("/")).stat().st_mode) == 0o750
PYCERT
python3 - "$INST/Library/Application Support/hikari/config.json" <<'PYOPT'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
config = json.loads(path.read_text())
config["caddy"] = {"macos_certificates": "native"}
path.write_text(json.dumps(config))
PYOPT
install_macos_fixture >/dev/null
test ! -e "$INST/Library/LaunchDaemons/io.hikari.certificates.plist"
grep -q '"mac_custom": "keep"' "$INST/Library/Application Support/hikari/config.json"

echo "=== Testing validation failure leaves activation unchanged ==="
cat > "$MOCK_BIN/reject-caddy" <<'REJECT'
#!/bin/bash
if [ "$1" = version ]; then echo 'v2.11.9'; exit 0; fi
exit 1
REJECT
chmod +x "$MOCK_BIN/reject-caddy"
BEFORE_TARGET=$(readlink "$INST/opt/hikari/versions/current")
if PATH="$MOCK_BIN:$PATH" bash "$REPO_ROOT/install/install.sh" \
  --target-os=macos --repair --root "$INST" --binary-source "$HIKARI_BIN" \
  --caddy-bin "$MOCK_BIN/reject-caddy" --tailscale-fixture "$TS_FIXTURE" \
  --service-mode=skip >/dev/null 2>&1; then
  echo 'Invalid Caddy configuration unexpectedly activated' >&2; exit 1
fi
test "$(readlink "$INST/opt/hikari/versions/current")" = "$BEFORE_TARGET"
test ! -e "$INST/opt/hikari/versions/.activation-previous"
grep -q '"mac_custom": "keep"' "$INST/Library/Application Support/hikari/config.json"

echo "=== Testing macOS --snippet-only ==="
SNIP="$TMP_ROOT/mac-snip"
bash "$REPO_ROOT/install/install.sh" \
  --target-os=macos \
  --snippet-only \
  --root "$SNIP" \
  --binary-source "$HIKARI_BIN" \
  --service-mode=skip >/dev/null
test -f "$SNIP/Library/Application Support/hikari/hikari-snippet.caddy"
test ! -e "$SNIP/Library/LaunchDaemons"
test ! -e "$SNIP/opt"
test ! -e "$SNIP/var"
test ! -e "$SNIP/Library/Application Support/hikari/config.json"
test ! -e "$SNIP/Library/Application Support/hikari/state"

echo "=== Testing macOS uninstall & --purge ==="
python3 - "$INST/Library/Application Support/hikari/config.json" <<'PYRESET'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
config = json.loads(path.read_text())
config["caddy"]["macos_certificates"] = "auto"
path.write_text(json.dumps(config))
PYRESET
install_macos_fixture >/dev/null
test -f "$INST/Library/LaunchDaemons/io.hikari.certificates.plist"
bash "$REPO_ROOT/install/uninstall.sh" --target-os=macos --root "$INST" --service-mode=skip >/dev/null
test ! -e "$INST/opt/hikari"
test ! -e "$INST/Library/LaunchDaemons/io.hikari.recover.plist"
test ! -e "$INST/Library/LaunchDaemons/io.hikari.agent.plist"
test ! -e "$INST/Library/LaunchDaemons/io.hikari.maintenance.plist"
test ! -e "$INST/Library/LaunchDaemons/io.hikari.certificates.plist"
test -d "$INST/Library/Application Support/hikari/certificates"
test -f "$INST/Library/Application Support/hikari/config.json"

bash "$REPO_ROOT/install/uninstall.sh" --target-os=macos --purge --root "$INST" --service-mode=skip >/dev/null
test ! -e "$INST/Library/Application Support/hikari"

echo "macOS installer integration tests PASSED."
