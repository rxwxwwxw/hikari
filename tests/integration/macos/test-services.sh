#!/bin/bash
# Real system-domain launchd smoke test. Uses only a temporary, unique job label.
# Does not install hikari, create accounts, contact peers, or touch other jobs.
set -euo pipefail
if [ "$(uname -s)" != Darwin ]; then echo 'Requires a native Mac' >&2; exit 2; fi
if [ "${1:-}" != --system-test ] || [ "$(id -u)" -ne 0 ]; then
  echo 'Run sudo bash tests/integration/macos/test-services.sh --system-test' >&2
  exit 2
fi
REPO_ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
ROOT=$(mktemp -d /private/tmp/hikari-launchd-XXXXXX)
LABEL="io.hikari.test.$$.${RANDOM}"
cleanup() {
  launchctl bootout "system/$LABEL" 2>/dev/null || true
  rm -rf "$ROOT"
}
trap cleanup EXIT
chmod 0755 "$ROOT"
mkdir "$ROOT/state" "$ROOT/web"
touch "$ROOT/state/stderr.log" "$ROOT/state/stdout.log"
cp "$REPO_ROOT/bin/hikari" "$ROOT/hikari"
cp "$REPO_ROOT/web/index.html" "$ROOT/web/index.html"
chmod 0755 "$ROOT/hikari"
chown -R nobody:nobody "$ROOT/state"
chmod 0700 "$ROOT/state"
chmod 0600 "$ROOT/state/"*.log
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
python3 - "$ROOT" "$LABEL" "$PORT" <<'PY'
import json, pathlib, plistlib, sys
root=pathlib.Path(sys.argv[1]); label=sys.argv[2]; port=int(sys.argv[3])
config={"schema_version":1,"listen":{"loopback_bind":"127.0.0.1","loopback_port":port},
        "discovery":{"enabled_on_dashboard_open":False},
        "paths":{"state_dir":str(root/"state"),"web_dir":str(root/"web")}}
(root/"config.json").write_text(json.dumps(config))
plist={"Label":label,"UserName":"nobody","GroupName":"nobody", "RunAtLoad":True,
       "KeepAlive":True,"ThrottleInterval":1,"Umask":63,
       "ProgramArguments":[str(root/"hikari"),"serve","--config",str(root/"config.json")],
       "StandardErrorPath":str(root/"state/stderr.log"),
       "StandardOutPath":str(root/"state/stdout.log")}
(root/"job.plist").write_bytes(plistlib.dumps(plist))
PY
chmod 0644 "$ROOT/job.plist" "$ROOT/config.json"
plutil -lint "$ROOT/job.plist"
launchctl bootstrap system "$ROOT/job.plist"
wait_health() {
  for _ in {1..150}; do
    if curl -fsS --max-time 1 "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1; then return; fi
    sleep 0.1
  done
  launchctl print "system/$LABEL" 2>/dev/null | awk '/state =|pid =|last exit code =|last terminating signal =|last spawn error =|program =|runs =/ {print}' >&2 || true
  cat "$ROOT/state/stderr.log" >&2 || true
  cat "$ROOT/state/stdout.log" >&2 || true
  echo 'Test LaunchDaemon failed to become healthy' >&2; exit 1
}
wait_health
OLD_PID=$(launchctl print "system/$LABEL" | awk '/pid =/ {print $3; exit}')
test -n "$OLD_PID"
ACTUAL_USER=$(ps -p "$OLD_PID" -o user= | tr -d ' ')
test "$ACTUAL_USER" = nobody
launchctl kill SIGKILL "system/$LABEL"
for _ in {1..50}; do
  NEW_PID=$(launchctl print "system/$LABEL" | awk '/pid =/ {print $3; exit}')
  if [ -n "$NEW_PID" ] && [ "$NEW_PID" != "$OLD_PID" ]; then break; fi
  sleep 0.1
done
test -n "$NEW_PID" && test "$NEW_PID" != "$OLD_PID"
wait_health
curl -fsS --max-time 5 "http://127.0.0.1:$PORT/api/v1/info" > "$ROOT/info.json"
python3 - "$ROOT/info.json" <<'PY'
import json, sys
j=json.load(open(sys.argv[1])); assert j["app"]=="hikari" and j["schema_version"]==1
assert j.get("hardware_summary") is None, "info must not trigger hardware collection"
PY
echo 'Native system LaunchDaemon, low-privilege execution and crash recovery PASSED.'
