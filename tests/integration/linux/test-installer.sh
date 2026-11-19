#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

HIKARI_BIN="${HIKARI_BIN:-$REPO_ROOT/bin/hikari}"
if [ ! -x "$HIKARI_BIN" ]; then
  echo "hikari binary not found at $HIKARI_BIN; build with dub build --compiler=ldc2 first." >&2
  exit 1
fi

TMP_BASE=$(mktemp -d /tmp/hikari-installer-test-XXXXXX)
cleanup() {
  rm -rf "$TMP_BASE"
}
trap cleanup EXIT

# Create mock Caddy binary that validates syntax check
MOCK_BIN_DIR="$TMP_BASE/mock-bin"
mkdir -p "$MOCK_BIN_DIR"
cat > "$MOCK_BIN_DIR/caddy" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "version" ]; then
  echo "v2.11.9 h1:mock-caddy"
  exit 0
fi
if [ "$1" = "validate" ]; then
  cfg=""
  while [ "$#" -gt 0 ]; do
    if [ "$1" = "--config" ]; then cfg="$2"; shift 2; else shift; fi
  done
  if [ -f "$cfg" ] && grep -q "admin off" "$cfg" && grep -q "reverse_proxy 127.0.0.1:" "$cfg"; then
    exit 0
  fi
  echo "invalid mock caddyfile" >&2
  exit 1
fi
exit 0
EOF
chmod +x "$MOCK_BIN_DIR/caddy"

# Rootless fixture portability: emulate only ss's listener output on non-Linux
# hosts, using a real connection to the test's temporary loopback listener.
if ! command -v ss >/dev/null 2>&1; then
  cat > "$MOCK_BIN_DIR/ss" <<'SS'
#!/usr/bin/env python3
import socket, sys
port = int(sys.argv[-1].split(":")[-1])
with socket.socket() as client:
    client.settimeout(0.1)
    if client.connect_ex(("127.0.0.1", port)) == 0:
        print(f"LISTEN 0 1 127.0.0.1:{port} 0.0.0.0:*")
SS
  chmod +x "$MOCK_BIN_DIR/ss"
fi

TS_FIXTURE="$REPO_ROOT/tests/fixtures/tailscale/online_fleet.json"

assert_eq() {
  local expected="$1" actual="$2" msg="$3"
  if [ "$expected" != "$actual" ]; then
    echo "ASSERT FAILED: $msg (expected='$expected', actual='$actual')" >&2
    exit 1
  fi
}

echo "=== 1. Testing os-release distro branch detection & --dry-run ==="
check_distro_dry_run() {
  local osrel="$1" expected_pkg="$2" label="$3"
  local test_root="$TMP_BASE/dry-$label"
  mkdir -p "$test_root"
  local out
  out=$(PATH="$MOCK_BIN_DIR:$PATH" bash "$REPO_ROOT/install/install.sh" --target-os=linux \
    --dry-run \
    --root "$test_root" \
    --os-release "$osrel" \
    --binary-source "$HIKARI_BIN" \
    --tailscale-fixture "$TS_FIXTURE" \
    --systemd-mode=skip)
  echo "$out" | grep -q "pkg=$expected_pkg" || {
    echo "Expected pkg=$expected_pkg for $label, got:" >&2
    echo "$out" >&2
    exit 1
  }
  if [ -e "$test_root/opt/hikari" ] || [ -e "$test_root/etc/hikari" ]; then
    echo "--dry-run modified filesystem in $test_root!" >&2
    exit 1
  fi
  echo "  [pass] $label -> pkg=$expected_pkg (zero files written on --dry-run)"
}

if [ "${1:-}" = "--os-release-only" ] && [ -n "${2:-}" ]; then
  # Running inside a real distro container
  echo "  Container os-release check on $2:"
  PATH="$MOCK_BIN_DIR:$PATH" bash "$REPO_ROOT/install/install.sh" --target-os=linux \
    --dry-run --root "$TMP_BASE/container-dry" --os-release "$2" \
    --binary-source "$HIKARI_BIN" --tailscale-fixture "$TS_FIXTURE" --systemd-mode=skip
else
  check_distro_dry_run "$REPO_ROOT/tests/fixtures/os-release/fedora" "dnf" "fedora"
  check_distro_dry_run "$REPO_ROOT/tests/fixtures/os-release/cachyos" "pacman" "cachyos"
  check_distro_dry_run "$REPO_ROOT/tests/fixtures/os-release/ubuntu" "apt" "ubuntu"
  check_distro_dry_run "$REPO_ROOT/tests/fixtures/os-release/armbian" "apt" "armbian"
  check_distro_dry_run "$REPO_ROOT/tests/fixtures/os-release/mint" "apt" "linuxmint"
  if [ -f /etc/os-release ]; then
    HOST_OUT=$(PATH="$MOCK_BIN_DIR:$PATH" bash "$REPO_ROOT/install/install.sh" --target-os=linux \
      --dry-run --root "$TMP_BASE/dry-host-osrel" --os-release /etc/os-release \
      --binary-source "$HIKARI_BIN" --tailscale-fixture "$TS_FIXTURE" --systemd-mode=skip)
    echo "$HOST_OUT" | grep -qE "pkg=(dnf|pacman|apt)" || {
      echo "Unexpected pkg detection on /etc/os-release:" >&2
      echo "$HOST_OUT" >&2
      exit 1
    }
    echo "  [pass] /etc/os-release detected valid package family"
  fi
fi

echo "=== 2. Testing clean install, existing Caddy & Tailscale non-interference, and idempotent repair ==="
INST_ROOT="$TMP_BASE/inst-root"
mkdir -p "$INST_ROOT/etc/caddy" "$INST_ROOT/etc/systemd/system" "$INST_ROOT/var/lib/tailscale"
echo "existing.example.com { respond \"untouched\" }" > "$INST_ROOT/etc/caddy/Caddyfile"
echo "[Unit]\nDescription=Existing System Caddy" > "$INST_ROOT/etc/systemd/system/caddy.service"
echo "tailscale-state-secret" > "$INST_ROOT/var/lib/tailscale/tailscaled.state"

CADDY_SHA_BEFORE=$(sha256sum "$INST_ROOT/etc/caddy/Caddyfile" | awk '{print $1}')
CADDY_SVC_SHA_BEFORE=$(sha256sum "$INST_ROOT/etc/systemd/system/caddy.service" | awk '{print $1}')
TS_SHA_BEFORE=$(sha256sum "$INST_ROOT/var/lib/tailscale/tailscaled.state" | awk '{print $1}')

PATH="$MOCK_BIN_DIR:$PATH" bash "$REPO_ROOT/install/install.sh" --target-os=linux \
  --root "$INST_ROOT" \
  --os-release "$REPO_ROOT/tests/fixtures/os-release/cachyos" \
  --binary-source "$HIKARI_BIN" \
  --caddy-source=existing \
  --tailscale-fixture "$TS_FIXTURE" \
  --systemd-mode=skip >/dev/null

test -x "$INST_ROOT/opt/hikari/versions/current/hikari"
test -f "$INST_ROOT/etc/hikari/config.json"
test -f "$INST_ROOT/etc/hikari/Caddyfile"
test -f "$INST_ROOT/etc/systemd/system/hikari.service"
test -f "$INST_ROOT/etc/systemd/system/hikari-maintenance.timer"
grep -q "PathChanged=/var/lib/hikari/update-request" "$INST_ROOT/etc/systemd/system/hikari-maintenance.path"
grep -q "update maintain --config" "$INST_ROOT/etc/systemd/system/hikari-maintenance.service"
test -f "$INST_ROOT/etc/systemd/system/hikari-caddy.service"
grep -q "admin off" "$INST_ROOT/etc/hikari/Caddyfile"
grep -q "bind 100.64.0.10" "$INST_ROOT/etc/hikari/Caddyfile"

# Add operator customization to config.json and nodes.json, then run --repair
python3 - <<PY
import json
p = "$INST_ROOT/etc/hikari/config.json"
d = json.load(open(p))
d["operator_custom_tag"] = "keep-me"
json.dump(d, open(p, "w"), indent=2)
open("$INST_ROOT/var/lib/hikari/nodes.json", "w").write('{"schema_version":1,"nodes":[{"node_id":"hikari:keep"}]}\n')
PY

PATH="$MOCK_BIN_DIR:$PATH" bash "$REPO_ROOT/install/install.sh" --target-os=linux \
  --repair \
  --root "$INST_ROOT" \
  --os-release "$REPO_ROOT/tests/fixtures/os-release/cachyos" \
  --binary-source "$HIKARI_BIN" \
  --caddy-source=existing \
  --tailscale-fixture "$TS_FIXTURE" \
  --systemd-mode=skip >/dev/null

grep -q '"operator_custom_tag": "keep-me"' "$INST_ROOT/etc/hikari/config.json"
grep -q 'hikari:keep' "$INST_ROOT/var/lib/hikari/nodes.json"

assert_eq "$CADDY_SHA_BEFORE" "$(sha256sum "$INST_ROOT/etc/caddy/Caddyfile" | awk '{print $1}')" "Existing system Caddyfile must be untouched"
assert_eq "$CADDY_SVC_SHA_BEFORE" "$(sha256sum "$INST_ROOT/etc/systemd/system/caddy.service" | awk '{print $1}')" "Existing caddy.service must be untouched"
assert_eq "$TS_SHA_BEFORE" "$(sha256sum "$INST_ROOT/var/lib/tailscale/tailscaled.state" | awk '{print $1}')" "Existing Tailscale state must be untouched"
echo "  [pass] clean install + repair preserved user config/state and left system Caddy/Tailscale untouched"

echo "=== 3. Testing --snippet-only mode ==="
SNIP_ROOT="$TMP_BASE/snip-root"
mkdir -p "$SNIP_ROOT"
bash "$REPO_ROOT/install/install.sh" --target-os=linux \
  --snippet-only \
  --root "$SNIP_ROOT" \
  --os-release "$REPO_ROOT/tests/fixtures/os-release/fedora" \
  --binary-source "$HIKARI_BIN" \
  --systemd-mode=skip >/dev/null

test -f "$SNIP_ROOT/etc/hikari/hikari-snippet.caddy"
test ! -f "$SNIP_ROOT/etc/systemd/system/hikari-caddy.service"
grep -q "handle_path /hikari/\*" "$SNIP_ROOT/etc/hikari/hikari-snippet.caddy"
echo "  [pass] --snippet-only generated prefixed snippet without hikari-caddy.service"

echo "=== 4. Testing occupied port collision fail-closed before write ==="
PORT_ROOT="$TMP_BASE/port-root"
mkdir -p "$PORT_ROOT"
python3 - <<'PY' &
import socket, time
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 29191))
s.listen(1)
time.sleep(5)
PY
OCC_PID=$!
sleep 0.2
set +e
HIKARI_TEST_CHECK_HOST_PORTS=1 PATH="$MOCK_BIN_DIR:$PATH" bash "$REPO_ROOT/install/install.sh" --target-os=linux \
  --root "$PORT_ROOT" \
  --loopback-port 29191 \
  --os-release "$REPO_ROOT/tests/fixtures/os-release/ubuntu" \
  --binary-source "$HIKARI_BIN" \
  --caddy-source=existing \
  --tailscale-fixture "$TS_FIXTURE" \
  --systemd-mode=skip >/dev/null 2>&1
PORT_EXIT=$?
set -e
kill "$OCC_PID" 2>/dev/null || true
wait "$OCC_PID" 2>/dev/null || true

if [ "$PORT_EXIT" -eq 0 ]; then
  echo "Expected occupied port install to fail before writing!" >&2
  exit 1
fi
if [ -e "$PORT_ROOT/opt/hikari" ] || [ -e "$PORT_ROOT/etc/hikari/config.json" ]; then
  echo "Fail-before-write violated on port conflict!" >&2
  exit 1
fi
echo "  [pass] occupied port failed closed before writing any files"

echo "=== 5. Testing uninstall (state preserved) and uninstall --purge ==="
bash "$REPO_ROOT/install/uninstall.sh" --target-os=linux --root "$INST_ROOT" --systemd-mode=skip >/dev/null
test ! -e "$INST_ROOT/opt/hikari"
test ! -e "$INST_ROOT/etc/systemd/system/hikari.service"
test ! -e "$INST_ROOT/etc/systemd/system/hikari-caddy.service"
test ! -e "$INST_ROOT/etc/hikari/Caddyfile"
test -f "$INST_ROOT/etc/hikari/config.json"
test -f "$INST_ROOT/var/lib/hikari/nodes.json"
assert_eq "$CADDY_SHA_BEFORE" "$(sha256sum "$INST_ROOT/etc/caddy/Caddyfile" | awk '{print $1}')" "Uninstall must leave system Caddy intact"

bash "$REPO_ROOT/install/uninstall.sh" --target-os=linux --purge --root "$INST_ROOT" --systemd-mode=skip >/dev/null
test ! -e "$INST_ROOT/etc/hikari"
test ! -e "$INST_ROOT/var/lib/hikari"
assert_eq "$CADDY_SHA_BEFORE" "$(sha256sum "$INST_ROOT/etc/caddy/Caddyfile" | awk '{print $1}')" "--purge must still leave system Caddy intact"
assert_eq "$TS_SHA_BEFORE" "$(sha256sum "$INST_ROOT/var/lib/tailscale/tailscaled.state" | awk '{print $1}')" "--purge must leave Tailscale state intact"
test ! -e "$INST_ROOT/etc/systemd/system/hikari-maintenance.path"
test ! -e "$INST_ROOT/etc/systemd/system/hikari-maintenance.timer"
test ! -e "$INST_ROOT/etc/systemd/system/hikari-maintenance.service"
echo "  [pass] uninstall and --purge behaved cleanly"

echo "=== 6. Testing package-manager Caddy version check & fallback ==="
build_no_caddy_path() {
  local out_dir="$1"
  local new_path="" d f
  local -a dirs
  IFS=':' read -ra dirs <<< "$PATH"
  for d in "${dirs[@]}"; do
    [ -d "$d" ] || continue
    if [ -e "$d/caddy" ]; then
      local mirror
      mirror="$out_dir/$(printf '%s' "$d" | tr '/' '_')"
      mkdir -p "$mirror"
      for f in "$d"/*; do
        [ -e "$f" ] || continue
        [ "${f##*/}" = "caddy" ] && continue
        ln -sf "$f" "$mirror/${f##*/}"
      done
      new_path="${new_path:+$new_path:}$mirror"
    else
      new_path="${new_path:+$new_path:}$d"
    fi
  done
  printf '%s\n' "$new_path"
}

CLEAN_HOST_PATH=$(build_no_caddy_path "$TMP_BASE/clean-sys-bin")

# 6a. apt offers Caddy < 2.10.0 -> skip apt install and fall back to private binary
APT_ROOT="$TMP_BASE/pkg-apt"
APT_BIN="$TMP_BASE/apt-bin"
mkdir -p "$APT_ROOT/opt/hikari/bin" "$APT_BIN"
cp "$MOCK_BIN_DIR/caddy" "$APT_ROOT/opt/hikari/bin/caddy"
chmod +x "$APT_ROOT/opt/hikari/bin/caddy"
cat > "$APT_BIN/apt-get" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "update" ]; then exit 0; fi
touch "$APT_ROOT/apt-install-called"
exit 1
EOF
cat > "$APT_BIN/apt-cache" <<'EOF'
#!/usr/bin/env bash
echo "caddy:"
echo "  Installed: (none)"
echo "  Candidate: 2.6.2-6"
EOF
chmod +x "$APT_BIN/apt-get" "$APT_BIN/apt-cache"
APT_OUT=$(HIKARI_TEST_ALLOW_PKG_INSTALL=1 HIKARI_NONINTERACTIVE=1 PATH="$APT_BIN:$CLEAN_HOST_PATH" \
  bash "$REPO_ROOT/install/install.sh" --target-os=linux \
  --root "$APT_ROOT" \
  --os-release "$REPO_ROOT/tests/fixtures/os-release/ubuntu" \
  --binary-source "$HIKARI_BIN" \
  --tailscale-fixture "$TS_FIXTURE" \
  --systemd-mode=skip)
echo "$APT_OUT" | grep -q "older than v2.10.0" || {
  echo "Expected old apt caddy version warning, got:" >&2
  echo "$APT_OUT" >&2
  exit 1
}
test ! -e "$APT_ROOT/apt-install-called"
grep -q "ExecStart=$APT_ROOT/opt/hikari/bin/caddy " "$APT_ROOT/etc/systemd/system/hikari-caddy.service"
echo "  [pass] old distro caddy (v2.6.2) skipped package install and fell back to private binary"

# 6b. pacman offers Caddy >= 2.10.0, user declines prompt -> fall back to private binary
PAC_DECLINE_ROOT="$TMP_BASE/pkg-pacman-decline"
PAC_DECLINE_BIN="$TMP_BASE/pacman-decline-bin"
mkdir -p "$PAC_DECLINE_ROOT/opt/hikari/bin" "$PAC_DECLINE_BIN"
cp "$MOCK_BIN_DIR/caddy" "$PAC_DECLINE_ROOT/opt/hikari/bin/caddy"
chmod +x "$PAC_DECLINE_ROOT/opt/hikari/bin/caddy"
cat > "$PAC_DECLINE_BIN/pacman" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  -Sy) exit 0 ;;
  -Si)
    echo "Name            : caddy"
    echo "Version         : 2.11.7-1.1"
    exit 0
    ;;
  -S)
    IFS= read -r ans || ans="n"
    case "$ans" in
      [Yy]*) exit 0 ;;
      *) exit 1 ;;
    esac
    ;;
esac
exit 1
EOF
chmod +x "$PAC_DECLINE_BIN/pacman"
PAC_DEC_OUT=$(printf 'n\n' | HIKARI_TEST_ALLOW_PKG_INSTALL=1 HIKARI_TEST_STDIN_PROMPT=1 PATH="$PAC_DECLINE_BIN:$CLEAN_HOST_PATH" \
  bash "$REPO_ROOT/install/install.sh" --target-os=linux \
  --root "$PAC_DECLINE_ROOT" \
  --os-release "$REPO_ROOT/tests/fixtures/os-release/cachyos" \
  --binary-source "$HIKARI_BIN" \
  --tailscale-fixture "$TS_FIXTURE" \
  --systemd-mode=skip)
echo "$PAC_DEC_OUT" | grep -q "declined or did not complete" || {
  echo "Expected declined pacman install fallback message, got:" >&2
  echo "$PAC_DEC_OUT" >&2
  exit 1
}
grep -q "ExecStart=$PAC_DECLINE_ROOT/opt/hikari/bin/caddy " "$PAC_DECLINE_ROOT/etc/systemd/system/hikari-caddy.service"
echo "  [pass] declined package manager install fell back to private binary"

# 6c. pacman offers Caddy >= 2.10.0 and installs it -> installer uses system_package caddy
PAC_OK_ROOT="$TMP_BASE/pkg-pacman-ok"
PAC_OK_BIN="$TMP_BASE/pacman-ok-bin"
mkdir -p "$PAC_OK_ROOT" "$PAC_OK_BIN"
cat > "$PAC_OK_BIN/pacman" <<EOF
#!/usr/bin/env bash
case "\${1:-}" in
  -Sy) exit 0 ;;
  -Si)
    echo "Name            : caddy"
    echo "Version         : 2.11.7-1.1"
    exit 0
    ;;
  -S)
    cat > "$PAC_OK_BIN/caddy" <<'MCADDY'
#!/usr/bin/env bash
if [ "\$1" = "version" ]; then echo "v2.11.7 h1:mock-pkg"; exit 0; fi
if [ "\$1" = "validate" ]; then exit 0; fi
exit 0
MCADDY
    chmod +x "$PAC_OK_BIN/caddy"
    exit 0
    ;;
esac
exit 1
EOF
chmod +x "$PAC_OK_BIN/pacman"
PAC_OK_OUT=$(HIKARI_TEST_ALLOW_PKG_INSTALL=1 HIKARI_NONINTERACTIVE=1 PATH="$PAC_OK_BIN:$CLEAN_HOST_PATH" \
  bash "$REPO_ROOT/install/install.sh" --target-os=linux \
  --root "$PAC_OK_ROOT" \
  --os-release "$REPO_ROOT/tests/fixtures/os-release/cachyos" \
  --binary-source "$HIKARI_BIN" \
  --tailscale-fixture "$TS_FIXTURE" \
  --systemd-mode=skip)
echo "$PAC_OK_OUT" | grep -q "(system_package)" || {
  echo "Expected system_package origin in output, got:" >&2
  echo "$PAC_OK_OUT" >&2
  exit 1
}
grep -q "ExecStart=$PAC_OK_BIN/caddy " "$PAC_OK_ROOT/etc/systemd/system/hikari-caddy.service"
echo "  [pass] compatible distro caddy (>= v2.10.0) installed via package manager"

echo "All Linux installer integration checks PASSED."
