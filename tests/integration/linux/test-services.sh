#!/usr/bin/env bash
set -euo pipefail

# End-to-end live loopback agent verification (no live Tailscale or root systemd required)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
HIKARI_BIN="${HIKARI_BIN:-$REPO_ROOT/bin/hikari}"

if [ ! -x "$HIKARI_BIN" ]; then
  echo "hikari binary not found at $HIKARI_BIN" >&2
  exit 1
fi

TMP_STATE=$(mktemp -d /tmp/hikari-service-smoke-XXXXXX)
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
SERVER_PID=""
cleanup() {
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP_STATE"
}
trap cleanup EXIT

cat > "$TMP_STATE/config.json" <<EOF
{
  "schema_version": 1,
  "listen": {
    "tailnet_port": 9100,
    "loopback_port": $PORT,
    "loopback_bind": "127.0.0.1",
    "base_path": "/"
  },
  "paths": {
    "state_dir": "$TMP_STATE/state",
    "config_dir": "$TMP_STATE",
    "versions_dir": "$TMP_STATE/versions",
    "web_dir": "$REPO_ROOT/web"
  }
}
EOF
mkdir -p "$TMP_STATE/state"

echo "=== Starting hikari serve on 127.0.0.1:$PORT ==="
"$HIKARI_BIN" serve \
  --config "$TMP_STATE/config.json" \
  --state-dir "$TMP_STATE/state" \
  --tailscale-fixture "$REPO_ROOT/tests/fixtures/tailscale/online_fleet.json" \
  --serve-web > "$TMP_STATE/server.log" 2>&1 &
SERVER_PID=$!

# Wait for /healthz
for _ in $(seq 1 30); do
  if curl -fsS "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done

python3 - <<PY
import json, urllib.request

base = "http://127.0.0.1:$PORT"

def get_json(path):
    with urllib.request.urlopen(base + path, timeout=5) as r:
        assert r.status == 200, f"{path} status {r.status}"
        assert r.headers.get("Cache-Control") == "no-store"
        return json.loads(r.read().decode())

health = get_json("/healthz")
assert health["status"] == "ok"

info = get_json("/api/v1/info")
assert info["app"] == "hikari"
assert info["schema_version"] == 1
assert info["hardware_summary"] is None, "/info must NOT trigger a hardware scan!"

st = get_json("/api/v1/status")
assert st["groups"]["fast"]["status"] == "fresh"
assert st["hardware_summary"] is None, "/status must NOT trigger a hardware scan!"
assert isinstance(st["gpus"], list)
assert isinstance(st["batteries"], list)

hw = get_json("/api/v1/hardware")
assert hw["collection"]["status"] == "fresh"
assert len(hw["cpu"]["isa"]["usable"]) > 0

info2 = get_json("/api/v1/info")
assert info2["hardware_summary"] is not None, "/info should expose cached summary once hardware was scanned"

nodes = get_json("/api/v1/nodes?probe=0")
assert len(nodes["nodes"]) >= 1
assert nodes["nodes"][0]["is_self"] is True

with urllib.request.urlopen(base + "/", timeout=5) as r:
    html = r.read().decode()
    assert "hikari — Tailnet Fleet Monitor" in html

print("Live HTTP endpoint contract checks PASSED.")
PY

# Run doctor against fixture + live loopback server
"$HIKARI_BIN" doctor \
  --config "$TMP_STATE/config.json" \
  --tailscale-fixture "$REPO_ROOT/tests/fixtures/tailscale/online_fleet.json" \
  --json | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["app"]=="hikari"; print("hikari doctor JSON check PASSED.")'

echo "Linux service smoke test PASSED."
