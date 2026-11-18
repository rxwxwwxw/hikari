#!/usr/bin/env bash
# Installer test for the "existing Caddy" path against a throwaway user Caddyfile.
#
# Runs install.sh / uninstall.sh with --root (no services) and --existing-caddyfile pointing at a
# scratch "user" Caddyfile, verifying with a real caddy binary:
#   * auto mode joins: the user file only gains the marked block; site file + record written;
#     no isolated Caddyfile or hikari-caddy unit;
#   * a repeat install changes nothing;
#   * --caddy-mode=isolated restores the user file byte for byte (and creates the isolated setup);
#   * back to auto, then uninstall restores it byte for byte again;
#   * a conflicting Caddyfile makes auto fall back to isolated and stay untouched;
#   * --caddy-mode=integrate on a conflict fails before writing anything.
#
# Usage: test-existing-caddy.sh /path/to/caddy   (or HIKARI_TEST_CADDY=/path/to/caddy)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
HIKARI_BIN="${HIKARI_BIN:-$REPO_ROOT/bin/hikari}"
CADDY="${1:-${HIKARI_TEST_CADDY:-}}"
[ -x "$HIKARI_BIN" ] || { echo "build bin/hikari first" >&2; exit 1; }
[ -n "$CADDY" ] && [ -x "$CADDY" ] || { echo "usage: $0 /path/to/caddy" >&2; exit 2; }

TS_FIXTURE="$REPO_ROOT/tests/fixtures/tailscale/online_fleet.json"
TMP=$(mktemp -d /tmp/hikari-existing-caddy-XXXXXX)
trap 'rm -rf "$TMP"' EXIT
ROOT="$TMP/root"
USER_DIR="$TMP/user-caddy"
USER_CF="$USER_DIR/Caddyfile"
RECORD="$ROOT/var/lib/hikari/caddy-integration.json"
mkdir -p "$USER_DIR"

fail() { echo "FAILED: $*" >&2; exit 1; }
sha() { sha256sum "$1" | awk '{print $1}'; }
run_install() {
  bash "$REPO_ROOT/install/install.sh" --root "$ROOT" --binary-source "$HIKARI_BIN" \
    --tailscale-fixture "$TS_FIXTURE" --systemd-mode=skip --caddy-bin "$CADDY" \
    --existing-caddyfile "$USER_CF" --existing-caddy-bin "$CADDY" "$@"
}

# A realistic user config: global options, a snippet, several sites, no final newline.
printf '{\n\temail ops@example.com\n}\n\n(common) {\n\tencode gzip\n}\n\nexample.com {\n\timport common\n\treverse_proxy 127.0.0.1:8080\n}\n\nhttp://intranet.lan {\n\trespond "intranet"\n}' > "$USER_CF"
ORIG_SHA=$(sha "$USER_CF")
ORIG_LEN=$(wc -c < "$USER_CF")

echo "--- auto mode joins the existing Caddy"
run_install >/dev/null
grep -q "^# BEGIN hikari" "$USER_CF" || fail "marked block missing"
grep -q "^import hikari.caddy" "$USER_CF" || fail "import line missing"
[ "$(head -c "$ORIG_LEN" "$USER_CF" | sha256sum | awk '{print $1}')" = "$ORIG_SHA" ] || fail "bytes before the hikari block changed"
[ -f "$USER_DIR/hikari.caddy" ] || fail "site file missing"
[ -f "$RECORD" ] || fail "integration record missing"
[ ! -e "$ROOT/etc/hikari/Caddyfile" ] || fail "isolated Caddyfile must not exist when joined"
[ ! -e "$ROOT/etc/systemd/system/hikari-caddy.service" ] || fail "hikari-caddy unit must not exist when joined"
"$CADDY" adapt --config "$USER_CF" --adapter caddyfile >/dev/null 2>&1 || fail "joined Caddyfile no longer adapts"
grep -q '"mode": "auto"' "$ROOT/etc/hikari/config.json" || fail "config.json should record caddy.mode=auto"

echo "--- repeat install changes nothing"
JOINED_SHA=$(sha "$USER_CF")
run_install --repair >/dev/null
[ "$(sha "$USER_CF")" = "$JOINED_SHA" ] || fail "repeat install modified the user Caddyfile"

echo "--- switching to isolated restores the user Caddyfile"
run_install --repair --caddy-mode=isolated >/dev/null
[ "$(sha "$USER_CF")" = "$ORIG_SHA" ] || fail "isolated mode did not restore the original bytes"
[ ! -e "$USER_DIR/hikari.caddy" ] || fail "site file left behind"
[ ! -e "$RECORD" ] || fail "record left behind"
[ -f "$ROOT/etc/hikari/Caddyfile" ] || fail "isolated Caddyfile missing"
[ -f "$ROOT/etc/systemd/system/hikari-caddy.service" ] || fail "hikari-caddy unit missing"

echo "--- back to auto removes the isolated unit; uninstall restores the user Caddyfile"
run_install --repair --caddy-mode=auto >/dev/null
[ "$(sha "$USER_CF")" != "$ORIG_SHA" ] || fail "auto did not join again"
[ ! -e "$ROOT/etc/systemd/system/hikari-caddy.service" ] || fail "isolated unit not removed after switching to the existing Caddy"
bash "$REPO_ROOT/install/uninstall.sh" --root "$ROOT" --systemd-mode=skip >/dev/null
[ "$(sha "$USER_CF")" = "$ORIG_SHA" ] || fail "uninstall did not restore the original bytes"
[ ! -e "$USER_DIR/hikari.caddy" ] || fail "uninstall left hikari.caddy behind"
bash "$REPO_ROOT/install/uninstall.sh" --root "$ROOT" --systemd-mode=skip --purge >/dev/null

echo "--- a conflicting Caddyfile: auto falls back to isolated and is left untouched"
printf ':9100 {\n\trespond "someone else"\n}\n' > "$USER_CF"
CONFLICT_SHA=$(sha "$USER_CF")
run_install >/dev/null
[ "$(sha "$USER_CF")" = "$CONFLICT_SHA" ] || fail "conflicting user Caddyfile was modified"
[ ! -e "$RECORD" ] || fail "no record expected on fallback"
bash "$REPO_ROOT/install/uninstall.sh" --root "$ROOT" --systemd-mode=skip --purge >/dev/null

echo "--- --caddy-mode=integrate on a conflict fails before writing anything"
if run_install --caddy-mode=integrate >/dev/null 2>&1; then fail "--caddy-mode=integrate should fail on a conflict"; fi
[ ! -e "$ROOT/opt/hikari" ] && [ ! -e "$ROOT/etc/hikari" ] || fail "a failed --caddy-mode=integrate must not write anything"
[ "$(sha "$USER_CF")" = "$CONFLICT_SHA" ] || fail "conflicting user Caddyfile was modified"

echo "Existing-Caddy installer test PASSED."
