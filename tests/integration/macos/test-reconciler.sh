#!/bin/bash
set -euo pipefail
REPO_ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
ROOT=$(mktemp -d /tmp/hikari-reconcile-XXXXXX)
PID=""
cleanup() {
  if [ -n "$PID" ]; then kill "$PID" 2>/dev/null || true; wait "$PID" 2>/dev/null || true; fi
  rm -rf "$ROOT"
}
trap cleanup EXIT
mkdir -p "$ROOT/release/caddy" "$ROOT/runtime"
cat > "$ROOT/release/hikari" <<'MOCK'
#!/bin/bash
if [ "${2:-}" = validate ]; then exit 0; fi
while [ "$#" -gt 0 ]; do
  if [ "$1" = '--out' ]; then printf 'tailnet-only-config\n'; exit 0; fi
  shift
done
exit 1
MOCK
cat > "$ROOT/caddy" <<'MOCK'
#!/bin/bash
set -eu
if [ "$1" = validate ]; then exit 0; fi
if [ "$1" = run ]; then
  echo $$ > "$HIKARI_TEST_RUNTIME/child.pid"
  trap 'exit 0' TERM INT
  while :; do sleep 1 & wait $! || true; done
fi
MOCK
chmod +x "$ROOT/release/hikari" "$ROOT/caddy"
HIKARI_TEST_RUNTIME="$ROOT/runtime" HIKARI_NETWORK_RECONCILE_S=15 \
  bash "$REPO_ROOT/install/macos-caddy.sh" "$ROOT/config.json" "$ROOT/caddy" "$ROOT/runtime" "$ROOT/release" &
PID=$!
for _ in {1..50}; do
  if [ -f "$ROOT/runtime/child.pid" ]; then break; fi
  sleep 0.1
done
test -f "$ROOT/runtime/child.pid"
CHILD=$(cat "$ROOT/runtime/child.pid")
kill -0 "$CHILD"
kill "$PID"
wait "$PID"
PID=""
if kill -0 "$CHILD" 2>/dev/null; then echo 'Caddy child survived wrapper shutdown' >&2; exit 1; fi
# Invalid intervals fail before spawning any process.
if HIKARI_NETWORK_RECONCILE_S=1 bash "$REPO_ROOT/install/macos-caddy.sh" x y z 2>/dev/null; then exit 1; fi
echo 'macOS network reconciler tests PASSED.'
