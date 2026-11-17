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
if [ "$1" = "version" ]; then echo "v2.9.1 h1:mock"; exit 0; fi
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
test -f "$INST/Library/LaunchDaemons/io.hikari.agent.plist"
test -f "$INST/Library/LaunchDaemons/io.hikari.caddy.plist"
grep -q "<string>io.hikari.agent</string>" "$INST/Library/LaunchDaemons/io.hikari.agent.plist"
grep -q "<key>RunAtLoad</key>" "$INST/Library/LaunchDaemons/io.hikari.agent.plist"
grep -q "<string>/Library/Application Support/hikari/Caddyfile</string>" "$INST/Library/LaunchDaemons/io.hikari.caddy.plist"

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

echo "=== Testing macOS --snippet-only ==="
SNIP="$TMP_ROOT/mac-snip"
bash "$REPO_ROOT/install/install.sh" \
  --target-os=macos \
  --snippet-only \
  --root "$SNIP" \
  --binary-source "$HIKARI_BIN" \
  --service-mode=skip >/dev/null
test -f "$SNIP/Library/Application Support/hikari/hikari-snippet.caddy"
test ! -f "$SNIP/Library/LaunchDaemons/io.hikari.caddy.plist"

echo "=== Testing macOS uninstall & --purge ==="
bash "$REPO_ROOT/install/uninstall.sh" --target-os=macos --root "$INST" --service-mode=skip >/dev/null
test ! -e "$INST/opt/hikari"
test ! -e "$INST/Library/LaunchDaemons/io.hikari.agent.plist"
test -f "$INST/Library/Application Support/hikari/config.json"

bash "$REPO_ROOT/install/uninstall.sh" --target-os=macos --purge --root "$INST" --service-mode=skip >/dev/null
test ! -e "$INST/Library/Application Support/hikari"

echo "macOS installer integration tests PASSED."
