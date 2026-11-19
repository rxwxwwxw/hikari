#!/bin/bash
# Disposable-host test of real directories, accounts and access boundaries.
# Never run against a machine that already contains a hikari installation.
set -euo pipefail
if [ "$(uname -s)" != Darwin ] || [ "$(id -u)" -ne 0 ] || [ "${1:-}" != --system-test ]; then
  echo 'Requires sudo on a disposable Mac: test-system-install.sh --system-test' >&2; exit 2
fi
REPO_ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
STATE='/Library/Application Support/hikari/state'
CONFIG='/Library/Application Support/hikari/config.json'
for path in /opt/hikari '/Library/Application Support/hikari' /var/log/hikari \
  /Library/LaunchDaemons/io.hikari.agent.plist /Library/LaunchDaemons/io.hikari.caddy.plist /Library/LaunchDaemons/io.hikari.recover.plist; do
  if [ -e "$path" ] || [ -L "$path" ]; then echo "Existing hikari path; refusing test: $path" >&2; exit 2; fi
done
for account in _hikari _hikari_caddy; do
  if id "$account" >/dev/null 2>&1; then echo "Existing service identity; refusing test: $account" >&2; exit 2; fi
done
for group in _hikari _hikari_caddy _hikari_config; do
  if dscl . -read "/Groups/$group" >/dev/null 2>&1; then echo "Existing service group; refusing test: $group" >&2; exit 2; fi
done
ROOT=$(mktemp -d /private/tmp/hikari-system-install-XXXXXX)
cleanup() {
  bash "$REPO_ROOT/install/uninstall.sh" --target-os=macos --service-mode=skip --purge >/dev/null 2>&1 || true
  rm -rf /var/log/hikari "$ROOT"
  for account in _hikari _hikari_caddy; do dscl . -delete "/Users/$account" 2>/dev/null || true; done
  for group in _hikari _hikari_caddy _hikari_config; do dscl . -delete "/Groups/$group" 2>/dev/null || true; done
}
trap cleanup EXIT
chmod 0755 "$ROOT"
cat > "$ROOT/caddy" <<'MOCK'
#!/bin/bash
if [ "$1" = version ]; then echo 'v2.11.9'; fi
exit 0
MOCK
chmod 0755 "$ROOT/caddy"
install_test() {
  bash "$REPO_ROOT/install/install.sh" --target-os=macos --service-mode=skip \
    --binary-source "$REPO_ROOT/bin/hikari" --caddy-bin "$ROOT/caddy" \
    --tailscale-fixture "$REPO_ROOT/tests/fixtures/tailscale/online_fleet.json" "$@" >/dev/null
}
install_test
sudo -n -u _hikari /bin/test -r "$CONFIG"
sudo -n -u _hikari_caddy /bin/test -r "$CONFIG"
# Match the LaunchDaemon's 077 umask for files created by its account.
# Capture output as the root test runner; only the agent runs as _hikari.
# shellcheck disable=SC2024
sudo -n -u _hikari /bin/bash -c 'cd /; umask 077; exec "$@"' _ \
  /opt/hikari/versions/current/hikari hardware --fixture macos-arm64 --state-dir "$STATE" > "$ROOT/hardware.json"
test -f "$STATE/hardware_cache.json"
if sudo -n -u _hikari_caddy /bin/test -r "$STATE/hardware_cache.json"; then echo 'Caddy can read private agent state' >&2; exit 1; fi
sudo -n -u _hikari_caddy /usr/bin/touch "$STATE/caddy/test-certificate"
if sudo -n -u _hikari /bin/test -r "$STATE/caddy/test-certificate"; then echo 'Agent can read certificate store' >&2; exit 1; fi
if sudo -n -u _hikari /bin/mv "$STATE/caddy" "$STATE/stolen-certificates" 2>/dev/null; then echo 'Agent can replace certificate directory' >&2; exit 1; fi
printf '120\n' > '/Library/Application Support/hikari/network-reconcile-seconds'
install_test --repair
sudo -n -u _hikari /bin/test -r "$STATE/hardware_cache.json"
sudo -n -u _hikari_caddy /bin/test -f "$STATE/caddy/test-certificate"
test "$(cat '/Library/Application Support/hikari/network-reconcile-seconds')" = 120
bash "$REPO_ROOT/install/uninstall.sh" --target-os=macos --service-mode=skip >/dev/null
test -f "$CONFIG" && test -f "$STATE/hardware_cache.json"
test -f "$STATE/caddy/test-certificate"
echo 'Native installer accounts, access boundaries, repair and retained-state uninstall PASSED.'
