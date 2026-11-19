#!/usr/bin/env bash
# hikari-owned short-lived maintenance jobs. No telemetry or peer discovery.
set -euo pipefail
os=$1
root=$2
mode=$3
service_user=$4
if [ "$os" = macos ]; then
  config="$root/Library/Application Support/hikari/config.json"
else
  config="$root/etc/hikari/config.json"
fi
request=$(python3 - "$config" "$os" <<'PYCONFIG'
import json, sys
with open(sys.argv[1]) as stream:
    default = "/Library/Application Support/hikari/state" if sys.argv[2] == "macos" else "/var/lib/hikari"
    print(json.load(stream).get("paths", {}).get("state_dir", default) + "/update-request")
PYCONFIG
)
# Create only a missing regular file, without following an agent-planted symlink
# or racing a pathname-based chown in the writable state directory.
python3 - "$root$request" "$root" "$service_user" <<'PYREQUEST'
import os, pwd, sys
try:
    fd = os.open(sys.argv[1], os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
except FileExistsError:
    pass
else:
    try:
        if not sys.argv[2]:
            account = pwd.getpwnam(sys.argv[3])
            os.fchown(fd, account.pw_uid, account.pw_gid)
    finally:
        os.close(fd)
PYREQUEST
if [ "$os" = macos ]; then
  destination="$root/Library/LaunchDaemons/io.hikari.maintenance.plist"
else
  destination="$root/etc/systemd/system/hikari-maintenance.service"
fi
if [ -e "$destination" ] && ! grep -q 'hikari-owned maintenance' "$destination"; then
  echo "Refusing foreign maintenance job at $destination" >&2
  exit 1
fi
if [ "$os" = macos ]; then
  cat > "$destination" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<!-- hikari-owned maintenance -->
<plist version="1.0"><dict>
<key>Label</key><string>io.hikari.maintenance</string>
<key>ProgramArguments</key><array>
<string>/opt/hikari/versions/current/hikari</string><string>update</string><string>maintain</string>
<string>--config</string><string>/Library/Application Support/hikari/config.json</string>
</array>
<key>EnvironmentVariables</key><dict><key>PATH</key><string>/opt/homebrew/opt/openssl@3/bin:/usr/local/opt/openssl@3/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string></dict>
<key>StartInterval</key><integer>300</integer>
<key>ProcessType</key><string>Background</string>
</dict></plist>
PLIST
  python3 - "$destination" "$request" <<'PYPATCH'
import plistlib, sys
with open(sys.argv[1], "rb") as stream:
    job = plistlib.load(stream)
job["WatchPaths"] = [sys.argv[2]]
with open(sys.argv[1], "wb") as stream:
    # Keep the ownership marker used by repair and uninstall.
    stream.write(plistlib.dumps(job).replace(b"<!DOCTYPE", b"<!-- hikari-owned maintenance -->\n<!DOCTYPE"))
PYPATCH
  chmod 0644 "$destination"
  if [ -z "$root" ] && [ "$mode" = auto ]; then
    chown root:wheel "$destination"
    launchctl bootout system/io.hikari.maintenance 2>/dev/null || true
    for ((i = 0; i < 50; i++)); do
      if ! launchctl print system/io.hikari.maintenance >/dev/null 2>&1; then break; fi
      sleep 0.1
    done
    bootstrapped=0
    for ((i = 0; i < 15; i++)); do
      if launchctl bootstrap system "$destination" 2>/dev/null; then
        bootstrapped=1
        break
      fi
      sleep 0.2
    done
    if [ "$bootstrapped" -eq 0 ]; then
      launchctl bootstrap system "$destination"
    fi
  fi
else
  timer="$root/etc/systemd/system/hikari-maintenance.timer"
  if [ -e "$timer" ] && ! grep -q 'hikari-owned maintenance' "$timer"; then
    echo "Refusing foreign maintenance timer at $timer" >&2
    exit 1
  fi
  cat > "$destination" <<'UNIT'
# hikari-owned maintenance
[Unit]
Description=hikari signed release maintenance
After=network-online.target
[Service]
Type=oneshot
ExecStart=/opt/hikari/versions/current/hikari update maintain --config /etc/hikari/config.json
TimeoutStartSec=15min
UMask=0077
UNIT
  cat > "$timer" <<'UNIT'
# hikari-owned maintenance
[Unit]
Description=hikari maintenance eligibility check (local state only until due)
[Timer]
OnBootSec=5min
OnUnitInactiveSec=5min
Unit=hikari-maintenance.service
[Install]
WantedBy=timers.target
UNIT
  watcher="$root/etc/systemd/system/hikari-maintenance.path"
  if [ -e "$watcher" ] && ! grep -q 'hikari-owned maintenance' "$watcher"; then
    echo "Refusing foreign maintenance path at $watcher" >&2
    exit 1
  fi
  cat > "$watcher" <<UNIT
# hikari-owned maintenance
[Unit]
Description=hikari on-demand signed update request
[Path]
PathChanged=$request
Unit=hikari-maintenance.service
[Install]
WantedBy=multi-user.target
UNIT
  if [ -z "$root" ] && [ "$mode" = auto ] && [ -d /run/systemd/system ]; then
    systemctl daemon-reload
    systemctl enable --now hikari-maintenance.timer hikari-maintenance.path
  fi
fi
