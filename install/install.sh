#!/usr/bin/env bash
set -euo pipefail
INSTALL_ARGS=("$@")

# hikari Unix system installer (Linux systemd & macOS LaunchDaemons)
# Linux: Fedora/dnf, Arch/CachyOS/pacman, Ubuntu/Mint/Armbian/Debian/apt
# macOS: Intel x86_64 & Apple Silicon arm64 system-domain LaunchDaemons
# Guarantees: non-destructive, idempotent, preserves Tailscale and every other service.
# Caddy modes (--caddy-mode, default from config.json caddy.mode, else auto):
#   auto       join an existing Caddy service when every safety check passes (one marked import
#              line + a hikari-owned site file, verified with `caddy adapt`), else isolated
#   integrate  join an existing Caddy or fail before changing anything
#   isolated   run hikari's own isolated hikari-caddy; never touch an existing Caddy
#   snippet    only write an importable snippet (same as --snippet-only)
# An existing Caddy is reloaded only with --reload; otherwise the reload command is printed.

CADDY_PINNED_VERSION="2.9.1"
CADDY_SHA512_LINUX_AMD64="0412057ba591c33bdb66034d7f32209619ce635147dac3084c79abcbc118a761145e695199f57c6798d88fab077f2b0d9cb999f52ded904c6d464a4eba202932"
CADDY_SHA512_LINUX_ARM64="80b917c2bd8aa0892f1386ff97af9e776067dd8cdc4793238869aca7e13f7280f89d1799a1fef08b49af92dbd86684c3ba7a38b9d44afc55ef2eeb33b49e1cbd"
CADDY_SHA512_MAC_AMD64="41198e1ddd19ce6266395f740c2332d9bc29a9ad31670bf5692a92f17b4c04c4b90fce21b87e7f206c2c404b90542d58944b50d504d555bf530274f42009c32a"
CADDY_SHA512_MAC_ARM64="246b4ab9755b584f81db37b640af806161da9e292277b17f4fa4f3da987da8f959d9b4cd763e0721e15f3680f530b445feac5f9ecfbefd33dc41b911eb5c8c45"

DRY_RUN=0
REPAIR=0
SNIPPET_ONLY=0
CADDY_MODE=""          # auto | integrate | isolated | snippet (empty: config.json, else auto)
RELOAD_CADDY=0
EXISTING_CADDYFILE=""  # test/override: use this Caddyfile instead of detecting the Caddy service
EXISTING_CADDY_BIN=""
CADDY_SOURCE="auto" # auto | private | system-package | existing
TAILNET_PORT="9100"
LOOPBACK_PORT="19100"
BASE_PATH="/"
ROOT_PREFIX=""
OS_RELEASE_PATH=""
BINARY_SOURCE=""
CADDY_BIN_OVERRIDE=""
TAILSCALE_FIXTURE=""
SYSTEMD_MODE="auto"
TARGET_OS="auto" # auto | linux | macos
SERVICE_USER="hikari"
TRUST_REPO=""
TRUST_PUBKEY=""
MANIFEST=""
SIGNATURE=""
ALLOW_ROOT_USER_SKIP=0

usage() {
  cat <<'EOF'
Usage: install/install.sh [options]

Options:
  --dry-run                         Show planned changes without modifying files or services
  --repair                          Reconcile generated units and Caddyfile; preserve user config/state
  --snippet-only                    Write hikari-snippet.caddy only (same as --caddy-mode=snippet)
  --caddy-mode=<mode>               auto (default) | integrate | isolated | snippet
  --reload                          Reload an existing Caddy after joining it (else print the command)
  --existing-caddyfile <path>       Use this existing Caddyfile instead of detecting the Caddy service
  --existing-caddy-bin <path>       caddy binary used to verify changes to the existing Caddyfile
  --caddy-source=<mode>             auto (default) | private | system-package | existing
  --target-os=<auto|linux|macos>    Target OS layout (default: auto via uname -s)
  --tailnet-port <port>             Tailnet HTTPS port (default: 9100)
  --loopback-port <port>            Local D agent loopback port (default: 19100)
  --base-path <path>                URL base path (default: /)
  --binary-source <path>            Local hikari binary or .tar.gz release path
  --caddy-bin <path>                Explicit Caddy executable path
  --root <dir>                      Install under target root directory (for container/staging tests)
  --os-release <path>               Alternate os-release file path (Linux testing)
  --tailscale-fixture <path>        Tailscale status --json fixture (for offline tests)
  --systemd-mode=<auto|skip>        Manage systemd/launchd services or skip activation (default: auto)
  --service-mode=<auto|skip>        Alias for --systemd-mode
  --repo <owner/repo>               Pinned GitHub release repository for signed updates
  --manifest <path>                 Signed release manifest (required for archive install)
  --sig <path>                      Detached Ed25519 manifest signature
  --pubkey <path>                   Trusted Ed25519 public key PEM path
  -h, --help                        Show help
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --repair) REPAIR=1; shift ;;
    --snippet-only) SNIPPET_ONLY=1; shift ;;
    --caddy-mode=*) CADDY_MODE="${1#*=}"; shift ;;
    --caddy-mode) CADDY_MODE="${2:?}"; shift 2 ;;
    --reload) RELOAD_CADDY=1; shift ;;
    --existing-caddyfile=*) EXISTING_CADDYFILE="${1#*=}"; shift ;;
    --existing-caddyfile) EXISTING_CADDYFILE="${2:?}"; shift 2 ;;
    --existing-caddy-bin=*) EXISTING_CADDY_BIN="${1#*=}"; shift ;;
    --existing-caddy-bin) EXISTING_CADDY_BIN="${2:?}"; shift 2 ;;
    --caddy-source=*) CADDY_SOURCE="${1#*=}"; shift ;;
    --caddy-source) CADDY_SOURCE="${2:?}"; shift 2 ;;
    --target-os=*) TARGET_OS="${1#*=}"; shift ;;
    --target-os) TARGET_OS="${2:?}"; shift 2 ;;
    --tailnet-port=*) TAILNET_PORT="${1#*=}"; shift ;;
    --tailnet-port) TAILNET_PORT="${2:?}"; shift 2 ;;
    --loopback-port=*) LOOPBACK_PORT="${1#*=}"; shift ;;
    --loopback-port) LOOPBACK_PORT="${2:?}"; shift 2 ;;
    --base-path=*) BASE_PATH="${1#*=}"; shift ;;
    --base-path) BASE_PATH="${2:?}"; shift 2 ;;
    --binary-source=*) BINARY_SOURCE="${1#*=}"; shift ;;
    --binary-source) BINARY_SOURCE="${2:?}"; shift 2 ;;
    --caddy-bin=*) CADDY_BIN_OVERRIDE="${1#*=}"; shift ;;
    --caddy-bin) CADDY_BIN_OVERRIDE="${2:?}"; shift 2 ;;
    --root=*) ROOT_PREFIX="${1#*=}"; shift ;;
    --root) ROOT_PREFIX="${2:?}"; shift 2 ;;
    --os-release=*) OS_RELEASE_PATH="${1#*=}"; shift ;;
    --os-release) OS_RELEASE_PATH="${2:?}"; shift 2 ;;
    --tailscale-fixture=*) TAILSCALE_FIXTURE="${1#*=}"; shift ;;
    --tailscale-fixture) TAILSCALE_FIXTURE="${2:?}"; shift 2 ;;
    --systemd-mode=*|--service-mode=*) SYSTEMD_MODE="${1#*=}"; shift ;;
    --systemd-mode|--service-mode) SYSTEMD_MODE="${2:?}"; shift 2 ;;
    --repo=*) TRUST_REPO="${1#*=}"; shift ;;
    --repo) TRUST_REPO="${2:?}"; shift 2 ;;
    --manifest) MANIFEST="${2:?}"; shift 2 ;;
    --sig) SIGNATURE="${2:?}"; shift 2 ;;
    --pubkey=*) TRUST_PUBKEY="${1#*=}"; shift ;;
    --pubkey) TRUST_PUBKEY="${2:?}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ "$TARGET_OS" = "auto" ]; then
  case "$(uname -s)" in
    Darwin) TARGET_OS="macos" ;;
    *) TARGET_OS="linux" ;;
  esac
fi

case "$TARGET_OS" in
  linux|macos) ;;
  *) echo "Invalid --target-os: $TARGET_OS" >&2; exit 2 ;;
esac

case "$CADDY_MODE" in
  ""|auto|integrate|isolated|snippet) ;;
  *) echo "Invalid --caddy-mode: $CADDY_MODE" >&2; exit 2 ;;
esac

case "$CADDY_SOURCE" in
  auto|private|system-package|existing) ;;
  *) echo "Invalid --caddy-source: $CADDY_SOURCE" >&2; exit 2 ;;
esac

if ! [[ "$TAILNET_PORT" =~ ^[0-9]+$ ]] || [ "$TAILNET_PORT" -lt 1 ] || [ "$TAILNET_PORT" -gt 65535 ]; then
  echo "Invalid --tailnet-port: $TAILNET_PORT" >&2; exit 2
fi
if ! [[ "$LOOPBACK_PORT" =~ ^[0-9]+$ ]] || [ "$LOOPBACK_PORT" -lt 1 ] || [ "$LOOPBACK_PORT" -gt 65535 ]; then
  echo "Invalid --loopback-port: $LOOPBACK_PORT" >&2; exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ -n "$ROOT_PREFIX" ]; then
  ALLOW_ROOT_USER_SKIP=1
fi

UNAME_ARCH="$(uname -m)"
case "$UNAME_ARCH" in
  x86_64|amd64) ARCH="x86_64" ;;
  aarch64|arm64) ARCH=$([ "$TARGET_OS" = "macos" ] && echo "arm64" || echo "aarch64") ;;
  *) echo "Unsupported architecture: $UNAME_ARCH" >&2; exit 1 ;;
esac

# 1. OS & package manager detection
DISTRO_ID="unknown"
DISTRO_ID_LIKE=""
PKG_FAMILY="unknown"
BREW_BIN=""

if [ "$TARGET_OS" = "macos" ]; then
  DISTRO_ID="macos"
  SERVICE_USER="_hikari"
  CADDY_SERVICE_USER="_hikari_caddy"
  if [ -x /opt/homebrew/bin/brew ]; then
    BREW_BIN="/opt/homebrew/bin/brew"
  elif [ -x /usr/local/bin/brew ]; then
    BREW_BIN="/usr/local/bin/brew"
  elif command -v brew >/dev/null 2>&1; then
    BREW_BIN="$(command -v brew)"
  fi
  PKG_FAMILY=$([ -n "$BREW_BIN" ] && echo "homebrew" || echo "none")

  OPT_HIKARI="${ROOT_PREFIX}/opt/hikari"
  VERSIONS_DIR="${OPT_HIKARI}/versions"
  PRIVATE_BIN_DIR="${OPT_HIKARI}/bin"
  ETC_HIKARI="${ROOT_PREFIX}/Library/Application Support/hikari"
  VAR_HIKARI="${ROOT_PREFIX}/Library/Application Support/hikari/state"
  REAL_ETC_HIKARI="/Library/Application Support/hikari"
  REAL_VAR_HIKARI="/Library/Application Support/hikari/state"
  UNIT_DIR="${ROOT_PREFIX}/Library/LaunchDaemons"
  LOG_DIR="${ROOT_PREFIX}/var/log/hikari"
  LOG_FILE="${LOG_DIR}/install.log"
else
  if [ -z "$OS_RELEASE_PATH" ]; then
    if [ -n "$ROOT_PREFIX" ] && [ -f "$ROOT_PREFIX/etc/os-release" ]; then
      OS_RELEASE_PATH="$ROOT_PREFIX/etc/os-release"
    else
      OS_RELEASE_PATH="/etc/os-release"
    fi
  fi

  if [ -f "$OS_RELEASE_PATH" ]; then
    DISTRO_ID=$(grep -E '^ID=' "$OS_RELEASE_PATH" | head -n1 | cut -d= -f2- | tr -d '"' | tr '[:upper:]' '[:lower:]' || true)
    DISTRO_ID_LIKE=$(grep -E '^ID_LIKE=' "$OS_RELEASE_PATH" | head -n1 | cut -d= -f2- | tr -d '"' | tr '[:upper:]' '[:lower:]' || true)
  fi

  case " $DISTRO_ID $DISTRO_ID_LIKE " in
    *" fedora "*|*" rhel "*|*" centos "*|*" rocky "*|*" almalinux "*) PKG_FAMILY="dnf" ;;
    *" cachyos "*|*" arch "*|*" archlinux "*) PKG_FAMILY="pacman" ;;
    *" ubuntu "*|*" debian "*|*" linuxmint "*|*" armbian "*|*" raspbian "*) PKG_FAMILY="apt" ;;
    *) PKG_FAMILY="unknown" ;;
  esac

  OPT_HIKARI="${ROOT_PREFIX}/opt/hikari"
  VERSIONS_DIR="${OPT_HIKARI}/versions"
  PRIVATE_BIN_DIR="${OPT_HIKARI}/bin"
  ETC_HIKARI="${ROOT_PREFIX}/etc/hikari"
  VAR_HIKARI="${ROOT_PREFIX}/var/lib/hikari"
  REAL_ETC_HIKARI="/etc/hikari"
  REAL_VAR_HIKARI="/var/lib/hikari"
  UNIT_DIR="${ROOT_PREFIX}/etc/systemd/system"
  LOG_DIR="${ROOT_PREFIX}/var/log"
  LOG_FILE="${LOG_DIR}/hikari-install.log"
fi

log() {
  local msg
  msg="[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"
  echo "$msg"
  if [ "$DRY_RUN" -eq 0 ]; then
    mkdir -p "$(dirname "$LOG_FILE")"
    echo "$msg" >> "$LOG_FILE"
  fi
}

compute_sha512() {
  local file="$1"
  if command -v sha512sum >/dev/null 2>&1; then
    sha512sum "$file" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 512 "$file" | awk '{print $1}'
  else
    echo "Neither sha512sum nor shasum found" >&2
    return 1
  fi
}

# 2. Elevation & preflight checks BEFORE modifying the host
if ! command -v python3 >/dev/null 2>&1; then
  echo "Python 3 is required for installer locking and release verification; install it separately before continuing." >&2
  exit 1
fi
if [ -z "$ROOT_PREFIX" ] && [ "$DRY_RUN" -eq 0 ] && [ "$(id -u)" -ne 0 ]; then
  echo "System installation requires root privileges. Re-run with sudo or use --dry-run / --root <dir>." >&2
  exit 1
fi

if [ -z "$BINARY_SOURCE" ]; then
  if [ -x "$REPO_ROOT/bin/hikari" ]; then
    BINARY_SOURCE="$REPO_ROOT/bin/hikari"
  else
    echo "No hikari binary found (pass --binary-source <path> or build with dub build --compiler=ldc2)." >&2
    exit 1
  fi
fi

if [ ! -e "$BINARY_SOURCE" ]; then
  echo "Binary source not found: $BINARY_SOURCE" >&2
  exit 1
fi

# Snippet export is deliberately isolated from installation and service management.
if [ "$SNIPPET_ONLY" -eq 1 ]; then
  if [[ "$BINARY_SOURCE" == *.tar.gz ]] || [[ "$BINARY_SOURCE" == *.tgz ]]; then
    echo "Snippet export requires a trusted local executable, not an archive." >&2; exit 1
  fi
  if [ "$BASE_PATH" = "/" ]; then BASE_PATH="/hikari"; fi
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "[dry-run] Would write only $ETC_HIKARI/hikari-snippet.caddy"
    exit 0
  fi
  mkdir -p "$ETC_HIKARI"
  "$BINARY_SOURCE" caddy snippet --config "$ETC_HIKARI/config.json" \
    --template "$REPO_ROOT/caddy/snippet.caddy.tmpl" --base-path "$BASE_PATH" \
    --web-dir "/opt/hikari/versions/current/web" --out "$ETC_HIKARI/hikari-snippet.caddy"
  echo "Wrote $ETC_HIKARI/hikari-snippet.caddy; import and reload remain operator actions."
  exit 0
fi

# Keep a single private copy of the chosen trust key throughout a real install.
if [ "${HIKARI_INSTALL_LOCKED:-0}" = 1 ] && [ -n "$TRUST_PUBKEY" ]; then
  INSTALL_TRUST_DIR=$(mktemp -d /tmp/hikari-install-trust-XXXXXX)
  trap 'rm -rf "$INSTALL_TRUST_DIR"' EXIT
  cp "$TRUST_PUBKEY" "$INSTALL_TRUST_DIR/key.pem"
  TRUST_PUBKEY="$INSTALL_TRUST_DIR/key.pem"
fi

# Verify archives against an operator-pinned trust root before any host mutation.
APP_VERSION=$(cat "$REPO_ROOT/VERSION" 2>/dev/null || echo "0.1.0")
if [[ "$BINARY_SOURCE" == *.tar.gz ]] || [[ "$BINARY_SOURCE" == *.tgz ]]; then
  if [ -z "$MANIFEST" ] || [ -z "$SIGNATURE" ] || [ -z "$TRUST_REPO" ] || [ -z "$TRUST_PUBKEY" ]; then
    echo "Archive installation requires --manifest, --sig, --repo and --pubkey." >&2
    exit 1
  fi
  RELEASE_OS="$TARGET_OS"
  if [ "$RELEASE_OS" = "macos" ]; then RELEASE_OS="darwin"; fi
  APP_VERSION=$(python3 "$REPO_ROOT/install/verify-release.py" --archive "$BINARY_SOURCE" \
    --manifest "$MANIFEST" --signature "$SIGNATURE" --repo "$TRUST_REPO" \
    --public-key "$TRUST_PUBKEY" --os "$RELEASE_OS" --arch "$ARCH")
fi

# Persisted operator endpoints take precedence over defaults on rerun/repair.
if [ -f "$ETC_HIKARI/config.json" ]; then
  read -r TAILNET_PORT LOOPBACK_PORT BASE_PATH < <(python3 -c '
import json, sys
c=json.load(open(sys.argv[1])).get("listen", {})
print(c.get("tailnet_port",9100), c.get("loopback_port",19100), c.get("base_path","/"))
' "$ETC_HIKARI/config.json")
fi

if [ -f "$VERSIONS_DIR/.activation-previous" ]; then
  echo "Interrupted activation pending; run hikari update recover before installing or repairing." >&2
  exit 1
fi

# 3. Port collision preflight
check_port_free_or_hikari() {
  local port="$1"
  local label="$2"
  if [ "$TARGET_OS" = "linux" ] && command -v ss >/dev/null 2>&1; then
    local listeners
    listeners=$(ss -H -ltn "sport = :$port" 2>/dev/null || true)
    if [ -n "$listeners" ]; then
      if [ "$REPAIR" -eq 1 ] && [ -f "$ETC_HIKARI/config.json" ]; then
        return 0
      fi
      if [ -n "$ROOT_PREFIX" ] && [ "${HIKARI_TEST_CHECK_HOST_PORTS:-0}" = "1" ]; then
        echo "Port conflict: $label port $port is already occupied:" >&2
        echo "$listeners" >&2
        exit 1
      elif [ -z "$ROOT_PREFIX" ]; then
        if ! systemctl is-active --quiet hikari.service 2>/dev/null && ! systemctl is-active --quiet hikari-caddy.service 2>/dev/null; then
          echo "Port conflict: $label port $port is already in use by another process." >&2
          echo "$listeners" >&2
          exit 1
        fi
      fi
    fi
  elif [ "$TARGET_OS" = "macos" ] && [ -z "$ROOT_PREFIX" ] && command -v lsof >/dev/null 2>&1; then
    local owners job job_pid owner parent
    owners=$(lsof -nP -t -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | sort -u || true)
    if [ -n "$owners" ]; then
      job="io.hikari.agent"
      if [ "$label" = "tailnet" ]; then job="io.hikari.caddy"; fi
      job_pid=$(launchctl print "system/$job" 2>/dev/null | awk '/pid =/ {print $3; exit}' || true)
      for owner in $owners; do
        parent=$(ps -p "$owner" -o ppid= | tr -d ' ')
        if [ -z "$job_pid" ] || { [ "$owner" != "$job_pid" ] && { [ "$label" != "tailnet" ] || [ "$parent" != "$job_pid" ]; }; }; then
          echo "Port conflict: $label port $port belongs to another process (pid $owner)." >&2
          exit 1
        fi
      done
    fi
  fi
}

check_port_free_or_hikari "$LOOPBACK_PORT" "loopback"
if [ "$SNIPPET_ONLY" -eq 0 ]; then
  check_port_free_or_hikari "$TAILNET_PORT" "tailnet"
fi

# 4. Tailscale CLI & macOS variant preflight (read-only)
TAILSCALE_BIN=""
if [ -z "$TAILSCALE_FIXTURE" ]; then
  if command -v tailscale >/dev/null 2>&1; then
    TAILSCALE_BIN="$(command -v tailscale)"
  elif [ "$TARGET_OS" = "macos" ] && [ -x "/Applications/Tailscale.app/Contents/MacOS/Tailscale" ]; then
    TAILSCALE_BIN="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
  fi
fi

if [ -z "$TAILSCALE_FIXTURE" ] && [ -z "$TAILSCALE_BIN" ] && [ -z "$ROOT_PREFIX" ]; then
  echo "Tailscale CLI unavailable. Install/enroll Tailscale separately and expose its supported noninteractive CLI." >&2
  exit 1
fi
TS_JSON=""
if [ -n "$TAILSCALE_FIXTURE" ]; then
  if [ ! -f "$TAILSCALE_FIXTURE" ]; then
    echo "Tailscale fixture not found: $TAILSCALE_FIXTURE" >&2; exit 1
  fi
  TS_JSON=$(cat "$TAILSCALE_FIXTURE")
elif [ -n "$TAILSCALE_BIN" ]; then
  TS_JSON=$("$TAILSCALE_BIN" status --json 2>/dev/null || true)
fi

TS_FQDN=""
TS_IP=""
if [ -n "$TS_JSON" ] && command -v python3 >/dev/null 2>&1; then
  read -r TS_FQDN TS_IP < <(python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read())
    s = d.get("Self", {})
    fq = (s.get("DNSName") or "").rstrip(".")
    ips = s.get("TailscaleIPs") or []
    print(fq, ips[0] if ips else "")
except Exception:
    print("", "")
' <<< "$TS_JSON") || true
  TS_FQDN="${TS_FQDN//$'\r'/}"
  TS_IP="${TS_IP//$'\r'/}"
fi

# 4b. Caddy mode: explicit flag > operator config > auto. Then hikari's own read-only analysis
#     of any existing Caddy (nothing is changed here).
CONFIG_PATH="$ETC_HIKARI/config.json"
INTEGRATION_RECORD="$VAR_HIKARI/caddy-integration.json"
WAS_INTEGRATED=0
[ -f "$INTEGRATION_RECORD" ] && WAS_INTEGRATED=1
EFFECTIVE_CADDY_MODE="auto"
if [ -f "$CONFIG_PATH" ] && command -v python3 >/dev/null 2>&1; then
  read -r CFG_CADDY_MODE CFG_CADDY_RELOAD < <(python3 -c '
import json, sys
try:
    c = json.load(open(sys.argv[1])).get("caddy") or {}
    print(c.get("mode") or "auto", 1 if c.get("reload") else 0)
except Exception:
    print("auto", 0)
' "$CONFIG_PATH") || true
  EFFECTIVE_CADDY_MODE="${CFG_CADDY_MODE:-auto}"
  [ "${CFG_CADDY_RELOAD:-0}" = "1" ] && RELOAD_CADDY=1
fi
[ -n "$CADDY_MODE" ] && EFFECTIVE_CADDY_MODE="$CADDY_MODE"
[ "$SNIPPET_ONLY" -eq 1 ] && EFFECTIVE_CADDY_MODE="snippet"
[ "$EFFECTIVE_CADDY_MODE" = "snippet" ] && SNIPPET_ONLY=1

CADDY_DECISION="isolated"
CADDY_DECISION_REASON=""
INTEGRATE_CADDYFILE=""
if [ "$EFFECTIVE_CADDY_MODE" = "auto" ] || [ "$EFFECTIVE_CADDY_MODE" = "integrate" ]; then
  if [ -n "$ROOT_PREFIX" ] && [ -z "$EXISTING_CADDYFILE" ]; then
    CADDY_DECISION_REASON="existing-Caddy detection is disabled under --root (pass --existing-caddyfile to test integration)"
  else
    PROBE_BIN="$BINARY_SOURCE"
    PROBE_DIR=""
    if [[ "$BINARY_SOURCE" == *.tar.gz ]] || [[ "$BINARY_SOURCE" == *.tgz ]]; then
      PROBE_DIR=$(mktemp -d)
      tar -xzf "$BINARY_SOURCE" -C "$PROBE_DIR" hikari
      PROBE_BIN="$PROBE_DIR/hikari"
    fi
    INSPECT_ARGS=(caddy inspect --verdict --config "$CONFIG_PATH" --state-dir "$VAR_HIKARI" --port "$TAILNET_PORT")
    [ -n "$TS_FQDN" ] && INSPECT_ARGS+=(--fqdn "$TS_FQDN")
    [ -n "$TS_IP" ] && INSPECT_ARGS+=(--tailscale-ip "$TS_IP")
    [ -n "$EXISTING_CADDYFILE" ] && INSPECT_ARGS+=(--caddyfile "$EXISTING_CADDYFILE")
    [ -n "$EXISTING_CADDY_BIN" ] && INSPECT_ARGS+=(--caddy "$EXISTING_CADDY_BIN")
    VERDICT=$("$PROBE_BIN" "${INSPECT_ARGS[@]}" 2>&1 | grep -E '^(integrate |isolated:)' | head -n 1 || true)
    [ -n "$PROBE_DIR" ] && rm -rf "$PROBE_DIR"
    case "$VERDICT" in
      "integrate "*) CADDY_DECISION="integrate"; INTEGRATE_CADDYFILE="${VERDICT#integrate }" ;;
      "isolated:"*) CADDY_DECISION_REASON="${VERDICT#isolated: }" ;;
      *) CADDY_DECISION_REASON="inspection failed" ;;
    esac
  fi
  if [ "$EFFECTIVE_CADDY_MODE" = "integrate" ] && [ "$CADDY_DECISION" != "integrate" ]; then
    echo "--caddy-mode=integrate: cannot join the existing Caddy ($CADDY_DECISION_REASON). Nothing was changed." >&2
    exit 1
  fi
elif [ "$EFFECTIVE_CADDY_MODE" = "isolated" ]; then
  CADDY_DECISION_REASON="caddy mode is 'isolated'"
fi

# Refuse unsafe explicit integration before creating even the update lock directory.
# Re-execution repeats the read-only analysis under the lock before any mutation.
if [ "$DRY_RUN" -eq 0 ] && [ "${HIKARI_INSTALL_LOCKED:-0}" != 1 ]; then
  exec python3 "$REPO_ROOT/install/locked-run.py" "$VERSIONS_DIR" \
    bash "$SCRIPT_DIR/install.sh" "${INSTALL_ARGS[@]}"
fi

# 5. Caddy binary for the isolated instance (an existing Caddy binary is used read-only; its
#    service and config are never touched in isolated mode).
RESOLVED_CADDY_BIN=""
CADDY_ORIGIN="none"

detect_existing_caddy() {
  if [ -n "$CADDY_BIN_OVERRIDE" ] && [ -x "$CADDY_BIN_OVERRIDE" ]; then
    RESOLVED_CADDY_BIN="$CADDY_BIN_OVERRIDE"
    CADDY_ORIGIN="explicit"
    return 0
  fi
  if [ -x "$PRIVATE_BIN_DIR/caddy" ]; then
    RESOLVED_CADDY_BIN="$PRIVATE_BIN_DIR/caddy"
    CADDY_ORIGIN="private"
    return 0
  fi
  if [ "$TARGET_OS" = "macos" ]; then
    for cand in /opt/homebrew/bin/caddy /usr/local/bin/caddy; do
      if [ -x "$cand" ] && "$cand" version >/dev/null 2>&1; then
        RESOLVED_CADDY_BIN="$cand"
        CADDY_ORIGIN="existing_homebrew_readonly"
        return 0
      fi
    done
  fi
  if command -v caddy >/dev/null 2>&1; then
    local sys_caddy
    sys_caddy="$(command -v caddy)"
    if "$sys_caddy" version >/dev/null 2>&1; then
      RESOLVED_CADDY_BIN="$sys_caddy"
      CADDY_ORIGIN="existing_system_binary_readonly"
      return 0
    fi
  fi
  return 1
}

install_private_caddy() {
  local target="$PRIVATE_BIN_DIR/caddy"
  local url expected_sha carch cos
  if [ "$TARGET_OS" = "macos" ]; then
    cos="mac"
    if [ "$ARCH" = "x86_64" ]; then
      carch="amd64"
      expected_sha="$CADDY_SHA512_MAC_AMD64"
    else
      carch="arm64"
      expected_sha="$CADDY_SHA512_MAC_ARM64"
    fi
  else
    cos="linux"
    if [ "$ARCH" = "x86_64" ]; then
      carch="amd64"
      expected_sha="$CADDY_SHA512_LINUX_AMD64"
    else
      carch="arm64"
      expected_sha="$CADDY_SHA512_LINUX_ARM64"
    fi
  fi
  url="https://github.com/caddyserver/caddy/releases/download/v${CADDY_PINNED_VERSION}/caddy_${CADDY_PINNED_VERSION}_${cos}_${carch}.tar.gz"

  if [ "$DRY_RUN" -eq 1 ]; then
    echo "[dry-run] Would download and verify Caddy v${CADDY_PINNED_VERSION} (${cos}_${carch}) into $target"
    RESOLVED_CADDY_BIN="$target"
    CADDY_ORIGIN="private_planned"
    return 0
  fi

  mkdir -p "$PRIVATE_BIN_DIR"
  local tmp_tgz
  tmp_tgz=$(mktemp)
  trap 'rm -f "$tmp_tgz"' RETURN

  log "Downloading pinned Caddy v${CADDY_PINNED_VERSION} (${cos}_${carch}) to private directory..."
  curl -fsSL --proto '=https' --tlsv1.2 --max-time 60 "$url" -o "$tmp_tgz"
  local actual_sha
  actual_sha=$(compute_sha512 "$tmp_tgz")
  if [ "$actual_sha" != "$expected_sha" ]; then
    echo "Caddy checksum verification failed! expected=$expected_sha actual=$actual_sha" >&2
    exit 1
  fi
  tar -xzf "$tmp_tgz" -C "$PRIVATE_BIN_DIR" caddy
  chmod 0755 "$target"
  RESOLVED_CADDY_BIN="$target"
  CADDY_ORIGIN="private"
}

resolve_isolated_caddy() {
  case "$CADDY_SOURCE" in
    auto)
      if ! detect_existing_caddy; then
        install_private_caddy
      fi
      ;;
    existing)
      if ! detect_existing_caddy; then
        echo "No compatible existing Caddy executable found (--caddy-source=existing)." >&2
        exit 1
      fi
      ;;
    private)
      if [ -n "$CADDY_BIN_OVERRIDE" ] && [ -x "$CADDY_BIN_OVERRIDE" ]; then
        RESOLVED_CADDY_BIN="$CADDY_BIN_OVERRIDE"
        CADDY_ORIGIN="private_override"
      elif [ -x "$PRIVATE_BIN_DIR/caddy" ]; then
        RESOLVED_CADDY_BIN="$PRIVATE_BIN_DIR/caddy"
        CADDY_ORIGIN="private"
      else
        install_private_caddy
      fi
      ;;
    system-package)
      if [ "$DRY_RUN" -eq 1 ]; then
        echo "[dry-run] Would install caddy package via $PKG_FAMILY without enabling system caddy service"
        RESOLVED_CADDY_BIN=$([ "$TARGET_OS" = "macos" ] && echo "/opt/homebrew/bin/caddy" || echo "/usr/bin/caddy")
        CADDY_ORIGIN="system_package_planned"
      else
        case "$PKG_FAMILY" in
          dnf) dnf install -y caddy ;;
          pacman) pacman -S --noconfirm --needed caddy ;;
          apt) apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y caddy ;;
          homebrew)
            if [ -z "${SUDO_USER:-}" ] && [ "$(id -u)" -eq 0 ]; then
              echo "Refusing to run brew install as root without SUDO_USER." >&2; exit 1
            fi
            if [ -n "${SUDO_USER:-}" ]; then
              su - "$SUDO_USER" -c "$BREW_BIN install caddy"
            else
              "$BREW_BIN" install caddy
            fi
            ;;
          *) echo "Unsupported package manager ($PKG_FAMILY) for --caddy-source=system-package" >&2; exit 1 ;;
        esac
        detect_existing_caddy || true
        CADDY_ORIGIN="system_package"
      fi
      ;;
  esac
}

if [ "$SNIPPET_ONLY" -eq 0 ] && [ "$CADDY_DECISION" = "isolated" ]; then
  resolve_isolated_caddy
fi

# Maintenance is installer-owned too; reject foreign job names before any writes.
if [ "$TARGET_OS" = macos ]; then
  MAINTENANCE_JOBS=(io.hikari.maintenance.plist)
else
  MAINTENANCE_JOBS=(hikari-maintenance.service hikari-maintenance.timer hikari-maintenance.path)
fi
for maintenance_job in "${MAINTENANCE_JOBS[@]}"; do
  if [ -e "$UNIT_DIR/$maintenance_job" ] && ! grep -q 'hikari-owned maintenance' "$UNIT_DIR/$maintenance_job"; then
    echo "Refusing foreign maintenance job at $UNIT_DIR/$maintenance_job" >&2
    exit 1
  fi
done

echo "=== hikari ($TARGET_OS) Install Plan ==="
echo "  Install a short-lived privileged maintenance job: local eligibility every 5 min; network only when update policy permits."
echo "  Distro/OS:      id=$DISTRO_ID like='$DISTRO_ID_LIKE' pkg=$PKG_FAMILY arch=$ARCH"
echo "  Target root:    ${ROOT_PREFIX:-/}"
echo "  Release dir:    $VERSIONS_DIR"
echo "  Config dir:     $ETC_HIKARI (existing user config preserved)"
echo "  State dir:      $VAR_HIKARI (existing nodes/hardware/certs preserved)"
if [ "$SNIPPET_ONLY" -eq 1 ]; then
  echo "  Caddy:          snippet only (nothing imported or reloaded)"
elif [ "$CADDY_DECISION" = "integrate" ]; then
  echo "  Caddy:          join existing Caddy: one marked import line appended to $INTEGRATE_CADDYFILE + hikari-owned site file"
  echo "                  (verified with caddy adapt, backup kept; reload: $([ "$RELOAD_CADDY" -eq 1 ] && echo yes || echo 'no - command printed'))"
  if [ -f "$UNIT_DIR/hikari-caddy.service" ] || [ -f "$UNIT_DIR/io.hikari.caddy.plist" ]; then
    echo "                  the isolated hikari-caddy service will be removed (its port moves to the existing Caddy)"
  fi
else
  echo "  Caddy:          isolated hikari-caddy${CADDY_DECISION_REASON:+ ($CADDY_DECISION_REASON)}"
  [ "$WAS_INTEGRATED" -eq 1 ] && echo "                  hikari's block is first removed from the previously joined Caddy (restored byte for byte)"
fi
echo "  Ports:          tailnet=$TAILNET_PORT loopback=127.0.0.1:$LOOPBACK_PORT base_path=$BASE_PATH"
echo "  Caddy binary:   ${RESOLVED_CADDY_BIN:-none} ($CADDY_ORIGIN)"
echo "  Tailscale FQDN: ${TS_FQDN:-<not yet detected>} (IP: ${TS_IP:-<none>})"
echo "  Service mode:   $SYSTEMD_MODE"

if [ "$DRY_RUN" -eq 1 ]; then
  echo "[dry-run] Preflight succeeded; no changes written."
  exit 0
fi

# 6. Service account (Linux only unless already present) & directory tree
if [ "$TARGET_OS" = "linux" ] && [ "$ALLOW_ROOT_USER_SKIP" -eq 0 ] && ! id "$SERVICE_USER" >/dev/null 2>&1; then
  log "Creating restricted system service user '$SERVICE_USER'..."
  useradd --system --no-create-home --shell /usr/sbin/nologin "$SERVICE_USER" 2>/dev/null \
    || useradd --system --no-create-home --shell /sbin/nologin "$SERVICE_USER"
fi

if [ "$TARGET_OS" = "macos" ] && [ -z "$ROOT_PREFIX" ]; then
  # shellcheck source=install/macos-accounts.sh
  source "$REPO_ROOT/install/macos-accounts.sh"
  create_macos_account "$SERVICE_USER" "$REAL_VAR_HIKARI"
  create_macos_account "$CADDY_SERVICE_USER" "$REAL_VAR_HIKARI/caddy"
  create_macos_config_group
fi
mkdir -p "$VERSIONS_DIR" "$ETC_HIKARI" "$VAR_HIKARI/caddy" "$UNIT_DIR" "$LOG_DIR"

# 7. Install versioned release directory
REL_DIR="$VERSIONS_DIR/$APP_VERSION"
STAGING_DIR="$VERSIONS_DIR/.install-tmp-$APP_VERSION"
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR/web" "$STAGING_DIR/caddy" "$STAGING_DIR/install"

if [[ "$BINARY_SOURCE" == *.tar.gz ]] || [[ "$BINARY_SOURCE" == *.tgz ]]; then
  EXTRACTED_VERSION=$(python3 "$REPO_ROOT/install/verify-release.py" --archive "$BINARY_SOURCE" \
    --manifest "$MANIFEST" --signature "$SIGNATURE" --repo "$TRUST_REPO" \
    --public-key "$TRUST_PUBKEY" --os "$RELEASE_OS" --arch "$ARCH" \
    --extract-dir "$STAGING_DIR")
  if [ "$EXTRACTED_VERSION" != "$APP_VERSION" ]; then
    rm -rf "$STAGING_DIR"
    echo "Release changed during installation; refusing activation." >&2
    exit 1
  fi
else
  cp "$BINARY_SOURCE" "$STAGING_DIR/hikari"
  chmod 0755 "$STAGING_DIR/hikari"
  cp "$REPO_ROOT/web/index.html" "$STAGING_DIR/web/index.html"
  cp "$REPO_ROOT/caddy/Caddyfile.tmpl" "$STAGING_DIR/caddy/Caddyfile.tmpl"
  cp "$REPO_ROOT/caddy/snippet.caddy.tmpl" "$STAGING_DIR/caddy/snippet.caddy.tmpl"
  cp "$REPO_ROOT/VERSION" "$STAGING_DIR/VERSION"
  cp "$REPO_ROOT/install/"*.sh "$REPO_ROOT/install/"*.py "$STAGING_DIR/install/"
fi

if [ ! -x "$STAGING_DIR/hikari" ]; then
  echo "Installed binary missing or not executable in $STAGING_DIR/hikari" >&2
  rm -rf "$STAGING_DIR"
  exit 1
fi

if [ -d "$REL_DIR" ]; then
  # A live version is immutable; reinstall/repair must never unlink its binary.
  if ! python3 - "$STAGING_DIR" "$REL_DIR" <<'PY'
import filecmp, pathlib, sys
def identical(left, right):
    comparison = filecmp.dircmp(left, right)
    if comparison.left_only or comparison.right_only or comparison.common_funny:
        return False
    for name in comparison.common_files:
        a, b = pathlib.Path(left, name), pathlib.Path(right, name)
        if a.is_symlink() or b.is_symlink() or not filecmp.cmp(a, b, shallow=False):
            return False
    return all(not pathlib.Path(left, name).is_symlink()
               and not pathlib.Path(right, name).is_symlink()
               and identical(pathlib.Path(left, name), pathlib.Path(right, name))
               for name in comparison.common_dirs)
sys.exit(0 if identical(*sys.argv[1:]) else 1)
PY
  then
    rm -rf "$STAGING_DIR"
    echo "Release $APP_VERSION already exists with different content; use a new version." >&2
    exit 1
  fi
  rm -rf "$STAGING_DIR"
else
  mv "$STAGING_DIR" "$REL_DIR"
fi

log "Staged hikari $APP_VERSION at $REL_DIR; activation follows generated-config validation"
activate_install_release() {
  python3 "$REPO_ROOT/install/activate-release.py" begin "$VERSIONS_DIR" "$APP_VERSION"
}

# Seed the agent's last-known MagicDNS name (hikari-owned state, refreshed by the
# agent itself); used for Host validation while `tailscale status` is unreadable.
case "$TS_FQDN" in
  ''|*[!A-Za-z0-9.-]*) ;;
  *) mkdir -p "$VAR_HIKARI" && printf '%s
' "$TS_FQDN" > "$VAR_HIKARI/local_fqdn" ;;
esac

# 8. Write default config.json ONLY if missing
if [ ! -f "$CONFIG_PATH" ]; then
  if [ -n "$TRUST_PUBKEY" ]; then
    cp "$TRUST_PUBKEY" "$ETC_HIKARI/release-public-key.pem"
    chmod 0644 "$ETC_HIKARI/release-public-key.pem"
    TRUST_PUBKEY="$REAL_ETC_HIKARI/release-public-key.pem"
  fi
  cat > "$CONFIG_PATH" <<EOF
{
  "schema_version": 1,
  "listen": {
    "tailnet_port": ${TAILNET_PORT},
    "loopback_port": ${LOOPBACK_PORT},
    "loopback_bind": "127.0.0.1",
    "base_path": "${BASE_PATH}"
  },
  "collection": {
    "ttl_seconds": {
      "fast": 10,
      "processes": 20,
      "device_dynamic": 60,
      "filesystems": 120,
      "tailnet": 300,
      "maintenance": 43200,
      "hardware": 604800
    },
    "max_stale_seconds": {
      "fast": 60,
      "processes": 120,
      "device_dynamic": 600,
      "filesystems": 1200,
      "tailnet": 3600,
      "maintenance": 604800,
      "hardware": 2592000
    },
    "cold_wait_ms": 2000,
    "probe_timeout_ms": 5000
  },
  "discovery": {
    "enabled_on_dashboard_open": true,
    "max_concurrent_probes": 4,
    "probe_timeout_ms": 3000
  },
  "updates": {
    "repo": "${TRUST_REPO:-OWNER/REPO}",
    "mode": "on_dashboard_open",
    "auto_install_verified": true,
    "check_interval_hours": 24,
    "public_key": "${TRUST_PUBKEY}",
    "channel": "stable"
  },
  "privacy": {
    "expose_serials": false,
    "expose_mac_addresses": false
  },
  "caddy": {
    "mode": "${EFFECTIVE_CADDY_MODE}",
    "reload": $([ "$RELOAD_CADDY" -eq 1 ] && echo true || echo false)
  },
  "paths": {
    "state_dir": "${REAL_VAR_HIKARI}",
    "config_dir": "${REAL_ETC_HIKARI}",
    "versions_dir": "/opt/hikari/versions",
    "web_dir": "/opt/hikari/versions/current/web"
  }
}
EOF
  chmod 0644 "$CONFIG_PATH"
  log "Created initial configuration at $CONFIG_PATH"
else
  log "Preserved existing user configuration at $CONFIG_PATH"
fi

# 9. Join the existing Caddy, or render hikari-owned Caddy config or snippet
INTEGRATED=0
if [ "$SNIPPET_ONLY" -eq 0 ] && [ "$CADDY_DECISION" = "integrate" ]; then
  INT_ARGS=(caddy integrate --config "$CONFIG_PATH" --state-dir "$VAR_HIKARI" --port "$TAILNET_PORT")
  [ -n "$TS_FQDN" ] && INT_ARGS+=(--fqdn "$TS_FQDN")
  [ -n "$TS_IP" ] && INT_ARGS+=(--tailscale-ip "$TS_IP")
  [ -n "$INTEGRATE_CADDYFILE" ] && INT_ARGS+=(--caddyfile "$INTEGRATE_CADDYFILE")
  [ -n "$EXISTING_CADDY_BIN" ] && INT_ARGS+=(--caddy "$EXISTING_CADDY_BIN")
  if INT_OUT=$("$REL_DIR/hikari" "${INT_ARGS[@]}" 2>&1); then
    INTEGRATED=1
    log "Joined existing Caddy: $(echo "$INT_OUT" | tr '\n' ' ')"
  elif [ "$EFFECTIVE_CADDY_MODE" = "integrate" ]; then
    echo "Could not join the existing Caddy: $INT_OUT" >&2
    exit 1
  else
    log "Not joining the existing Caddy ($(echo "$INT_OUT" | tail -n 1)); using the isolated hikari-caddy instead"
    CADDY_DECISION="isolated"
    resolve_isolated_caddy
  fi
fi

if [ "$SNIPPET_ONLY" -eq 0 ] && [ "$CADDY_DECISION" = "isolated" ] && [ "$WAS_INTEGRATED" -eq 1 ]; then
  # Switching back to isolated: remove hikari's block from the previously joined Caddy first.
  UN_ARGS=(caddy unintegrate --config "$CONFIG_PATH" --state-dir "$VAR_HIKARI")
  [ "$RELOAD_CADDY" -eq 1 ] && UN_ARGS+=(--reload)
  if ! UN_OUT=$("$REL_DIR/hikari" "${UN_ARGS[@]}" 2>&1); then
    echo "Could not remove hikari from the previously joined Caddy: $UN_OUT" >&2
    exit 1
  fi
  log "Removed hikari from the previously joined Caddy: $(echo "$UN_OUT" | tr '\n' ' ')"
fi

if [ "$SNIPPET_ONLY" -eq 1 ]; then
  SNIPPET_PATH="$ETC_HIKARI/hikari-snippet.caddy"
  "$REL_DIR/hikari" caddy snippet \
    --config "$CONFIG_PATH" \
    --template "$REL_DIR/caddy/snippet.caddy.tmpl" \
    --out "$SNIPPET_PATH"
  log "Generated Caddy import snippet at $SNIPPET_PATH"
elif [ "$INTEGRATED" -eq 1 ]; then
  : # the existing Caddy serves hikari; no isolated Caddyfile needed
else
  if [ -n "$TS_FQDN" ] && [ -n "$TS_IP" ]; then
    CADDYFILE_PATH="$ETC_HIKARI/Caddyfile"
    if [ -f "$CADDYFILE_PATH" ]; then
      cp "$CADDYFILE_PATH" "${CADDYFILE_PATH}.bak"
    fi
    "$REL_DIR/hikari" caddy render \
      --config "$CONFIG_PATH" \
      --template "$REL_DIR/caddy/Caddyfile.tmpl" \
      --fqdn "$TS_FQDN" \
      --tailscale-ip "$TS_IP" \
      --out "$CADDYFILE_PATH"
    if [ -x "$RESOLVED_CADDY_BIN" ]; then
      if "$RESOLVED_CADDY_BIN" validate --adapter caddyfile --config "$CADDYFILE_PATH" >/dev/null 2>&1; then
        log "Validated isolated Caddyfile at $CADDYFILE_PATH"
      else
        echo "Generated Caddyfile failed validation with $RESOLVED_CADDY_BIN" >&2
        exit 1
      fi
    fi
  else
    log "Tailscale FQDN/IP unavailable during install; skipping Caddyfile bind until Tailscale is online."
  fi
fi

# 10. Generate system-domain service definitions (systemd on Linux, LaunchDaemons on macOS)
if [ "$TARGET_OS" = "macos" ]; then
  mkdir -p "$PRIVATE_BIN_DIR"
  cp "$REL_DIR/install/macos-recover.sh" "$PRIVATE_BIN_DIR/macos-recover.sh.next"
  chmod 0755 "$PRIVATE_BIN_DIR/macos-recover.sh.next"
  mv -f "$PRIVATE_BIN_DIR/macos-recover.sh.next" "$PRIVATE_BIN_DIR/macos-recover.sh"
  cat > "$UNIT_DIR/io.hikari.recover.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>io.hikari.recover</string>
  <key>UserName</key><string>root</string>
  <key>ProgramArguments</key><array>
    <string>/bin/bash</string><string>/opt/hikari/bin/macos-recover.sh</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ThrottleInterval</key><integer>30</integer>
  <key>Umask</key><integer>63</integer>
  <key>StandardErrorPath</key><string>/var/log/hikari/recovery.stderr.log</string>
</dict></plist>
EOF
  chmod 0644 "$UNIT_DIR/io.hikari.recover.plist"
  if [ ! -f "$ETC_HIKARI/network-reconcile-seconds" ]; then
    printf '60\n' > "$ETC_HIKARI/network-reconcile-seconds"
    chmod 0644 "$ETC_HIKARI/network-reconcile-seconds"
  fi
  cat > "$UNIT_DIR/io.hikari.agent.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>io.hikari.agent</string>
  <key>UserName</key>
  <string>${SERVICE_USER}</string>
  <key>GroupName</key>
  <string>${SERVICE_USER}</string>
  <key>InitGroups</key>
  <true/>
  <key>WorkingDirectory</key>
  <string>/opt/hikari/versions/current</string>
  <key>EnvironmentVariables</key>
  <dict><key>PATH</key><string>/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin</string></dict>
  <key>ProgramArguments</key>
  <array>
    <string>/opt/hikari/versions/current/hikari</string>
    <string>serve</string>
    <string>--config</string>
    <string>/Library/Application Support/hikari/config.json</string>
  </array>
  <key>Umask</key>
  <integer>63</integer>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key>
    <false/>
  </dict>
  <key>ThrottleInterval</key>
  <integer>5</integer>
  <key>StandardOutPath</key>
  <string>/var/log/hikari/agent.stdout.log</string>
  <key>StandardErrorPath</key>
  <string>/var/log/hikari/agent.stderr.log</string>
</dict>
</plist>
EOF
  chmod 0644 "$UNIT_DIR/io.hikari.agent.plist"

  if [ "$INTEGRATED" -eq 1 ] && [ -f "$UNIT_DIR/io.hikari.caddy.plist" ]; then
    # Switched to the existing Caddy: free the tailnet port before any reload.
    if [ "$SYSTEMD_MODE" = "auto" ] && [ -z "$ROOT_PREFIX" ] && command -v launchctl >/dev/null 2>&1; then
      launchctl bootout system/io.hikari.caddy 2>/dev/null || true
    fi
    rm -f "$UNIT_DIR/io.hikari.caddy.plist"
    log "Removed the isolated hikari-caddy LaunchDaemon (switched to the existing Caddy)"
  fi

  if [ "$SNIPPET_ONLY" -eq 0 ] && [ "$INTEGRATED" -eq 0 ]; then
    RESOLVED_CADDY_XML=$(printf '%s' "$RESOLVED_CADDY_BIN" | sed 's/\&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
    cat > "$UNIT_DIR/io.hikari.caddy.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>io.hikari.caddy</string>
  <key>UserName</key>
  <string>${CADDY_SERVICE_USER}</string>
  <key>GroupName</key>
  <string>${CADDY_SERVICE_USER}</string>
  <key>InitGroups</key>
  <true/>
  <key>WorkingDirectory</key>
  <string>/opt/hikari/versions/current</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin</string>
    <key>HOME</key><string>/Library/Application Support/hikari/state/caddy</string>
  </dict>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>/opt/hikari/versions/current/install/macos-caddy.sh</string>
    <string>/Library/Application Support/hikari/config.json</string>
    <string>${RESOLVED_CADDY_XML}</string>
    <string>/Library/Application Support/hikari/state/caddy</string>
  </array>
  <key>Umask</key>
  <integer>63</integer>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>ThrottleInterval</key>
  <integer>10</integer>
  <key>StandardOutPath</key>
  <string>/var/log/hikari/caddy.stdout.log</string>
  <key>StandardErrorPath</key>
  <string>/var/log/hikari/caddy.stderr.log</string>
</dict>
</plist>
EOF
    chmod 0644 "$UNIT_DIR/io.hikari.caddy.plist"
  fi

  if [ -z "$ROOT_PREFIX" ]; then
    find "$VAR_HIKARI" -path "$VAR_HIKARI/caddy" -prune -o -exec chown "${SERVICE_USER}:${SERVICE_USER}" {} \;
    find "$VAR_HIKARI" -path "$VAR_HIKARI/caddy" -prune -o -type f -exec chmod 0600 {} \;
    find "$VAR_HIKARI" -path "$VAR_HIKARI/caddy" -prune -o -type d -exec chmod 0700 {} \;
    # Root owns the sticky shared parent: neither daemon can replace the other
    # daemon's directory entry. Only the agent group may create state files.
    chown "root:${SERVICE_USER}" "$VAR_HIKARI"
    chmod 1771 "$VAR_HIKARI"
    chown root:_hikari_config "$ETC_HIKARI" "$CONFIG_PATH"
    chmod 0750 "$ETC_HIKARI"
    chmod 0640 "$CONFIG_PATH"
    chown -R "${CADDY_SERVICE_USER}:${CADDY_SERVICE_USER}" "$VAR_HIKARI/caddy"
    chmod 0700 "$VAR_HIKARI/caddy"
    touch "$LOG_DIR/agent.stdout.log" "$LOG_DIR/agent.stderr.log" "$LOG_DIR/caddy.stdout.log" "$LOG_DIR/caddy.stderr.log"
    chown "${SERVICE_USER}:${SERVICE_USER}" "$LOG_DIR/agent.stdout.log" "$LOG_DIR/agent.stderr.log"
    chown "${CADDY_SERVICE_USER}:${CADDY_SERVICE_USER}" "$LOG_DIR/caddy.stdout.log" "$LOG_DIR/caddy.stderr.log"
    chmod 0600 "$LOG_DIR/"*.log
    /usr/bin/plutil -lint "$UNIT_DIR/io.hikari.recover.plist"
    /usr/bin/plutil -lint "$UNIT_DIR/io.hikari.agent.plist"
    if [ "$SNIPPET_ONLY" -eq 0 ] && [ "$INTEGRATED" -eq 0 ]; then /usr/bin/plutil -lint "$UNIT_DIR/io.hikari.caddy.plist"; fi
  fi
  activate_install_release
  if [ "$SYSTEMD_MODE" = "auto" ] && [ -z "$ROOT_PREFIX" ] && command -v launchctl >/dev/null 2>&1; then
    launchctl bootout system/io.hikari.agent 2>/dev/null || true
    launchctl bootstrap system "$UNIT_DIR/io.hikari.agent.plist"
    if [ "$SNIPPET_ONLY" -eq 0 ] && [ "$INTEGRATED" -eq 0 ] && [ -f "$ETC_HIKARI/Caddyfile" ]; then
      launchctl bootout system/io.hikari.caddy 2>/dev/null || true
      launchctl bootstrap system "$UNIT_DIR/io.hikari.caddy.plist"
    fi
    launchctl bootout system/io.hikari.recover 2>/dev/null || true
    launchctl bootstrap system "$UNIT_DIR/io.hikari.recover.plist"
    log "Loaded system-domain LaunchDaemons via launchctl"
  else
    log "Skipped launchctl activation (service-mode=$SYSTEMD_MODE root='$ROOT_PREFIX')"
  fi
else
  cat > "$UNIT_DIR/hikari.service" <<EOF
[Unit]
Description=hikari tailnet telemetry and hardware inventory agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_USER}
ExecStart=/opt/hikari/versions/current/hikari serve --config /etc/hikari/config.json
Restart=on-failure
RestartSec=5s
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=read-only
PrivateTmp=true
ReadWritePaths=/var/lib/hikari
LimitNOFILE=4096

[Install]
WantedBy=multi-user.target
EOF

  if [ "$INTEGRATED" -eq 1 ] && [ -f "$UNIT_DIR/hikari-caddy.service" ]; then
    # Switched to the existing Caddy: free the tailnet port before any reload.
    if [ "$SYSTEMD_MODE" = "auto" ] && [ -z "$ROOT_PREFIX" ] && command -v systemctl >/dev/null 2>&1; then
      systemctl disable --now hikari-caddy.service 2>/dev/null || true
    fi
    rm -f "$UNIT_DIR/hikari-caddy.service"
    log "Removed the isolated hikari-caddy unit (switched to the existing Caddy)"
  fi

  if [ "$SNIPPET_ONLY" -eq 0 ] && [ "$INTEGRATED" -eq 0 ]; then
    cat > "$UNIT_DIR/hikari-caddy.service" <<EOF
[Unit]
Description=hikari isolated Tailscale HTTPS reverse proxy (Caddy)
After=network-online.target tailscaled.service hikari.service
Wants=network-online.target tailscaled.service hikari.service

[Service]
Type=simple
User=root
ExecStart=${RESOLVED_CADDY_BIN} run --config /etc/hikari/Caddyfile --adapter caddyfile
Restart=on-failure
RestartSec=10s
NoNewPrivileges=true
ProtectHome=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
  fi

  if [ "$ALLOW_ROOT_USER_SKIP" -eq 0 ]; then
    chown -R "${SERVICE_USER}:${SERVICE_USER}" "$VAR_HIKARI"
    chown root:"${SERVICE_USER}" "$CONFIG_PATH"
    chmod 0640 "$CONFIG_PATH"
  fi

  activate_install_release
  if [ "$SYSTEMD_MODE" = "auto" ] && [ -z "$ROOT_PREFIX" ] && [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload
    systemctl enable --now hikari.service
    if [ "$SNIPPET_ONLY" -eq 0 ] && [ "$INTEGRATED" -eq 0 ] && [ -f "$ETC_HIKARI/Caddyfile" ]; then
      systemctl enable --now hikari-caddy.service
    fi
    log "Enabled and started hikari systemd units"
  else
    log "Skipped systemctl activation (systemd-mode=$SYSTEMD_MODE root='$ROOT_PREFIX')"
  fi
fi

bash "$REPO_ROOT/install/maintenance-jobs.sh" "$TARGET_OS" "$ROOT_PREFIX" "$SYSTEMD_MODE" "$SERVICE_USER"

# Test roots deliberately have no live service. Real activation is confirmed only
# by the expected version responding on the configured loopback listener.
if [ -n "$ROOT_PREFIX" ]; then
  python3 "$REPO_ROOT/install/activate-release.py" confirm "$VERSIONS_DIR" "$APP_VERSION"
elif [ "$SYSTEMD_MODE" = "auto" ]; then
  python3 "$REPO_ROOT/install/activate-release.py" health-confirm "$VERSIONS_DIR" "$APP_VERSION" "$CONFIG_PATH"
fi

# 11. Reload the existing Caddy only when asked (after hikari-caddy released the port).
if [ "$INTEGRATED" -eq 1 ]; then
  if [ "$RELOAD_CADDY" -eq 1 ]; then
    set +e
    RL_OUT=$("$REL_DIR/hikari" caddy reload --config "$CONFIG_PATH" --state-dir "$VAR_HIKARI" 2>&1)
    RL_CODE=$?
    set -e
    if [ "$RL_CODE" -eq 1 ]; then
      "$REL_DIR/hikari" caddy unintegrate --config "$CONFIG_PATH" --state-dir "$VAR_HIKARI" --reload >/dev/null 2>&1 || true
      echo "Reloading the existing Caddy failed ($RL_OUT); hikari's change was removed again. Re-run with --caddy-mode=isolated to use hikari's own Caddy." >&2
      exit 1
    fi
    log "$RL_OUT"
  else
    log "$(echo "$INT_OUT" | grep -E '^not reloaded' || true)"
  fi
fi

# 12. Final operator report
echo ""
echo "=== hikari installation complete ($TARGET_OS) ==="
echo "  Version:          $APP_VERSION"
echo "  Loopback API:     http://127.0.0.1:${LOOPBACK_PORT}/healthz"
if [ "$SNIPPET_ONLY" -eq 1 ]; then
  echo "  Caddy snippet:    $ETC_HIKARI/hikari-snippet.caddy"
  echo "  Action needed:    Add 'import ${REAL_ETC_HIKARI}/hikari-snippet.caddy' inside your existing Caddy site block."
elif [ "$INTEGRATED" -eq 1 ]; then
  echo "  Caddy:            joined existing Caddy ($INTEGRATE_CADDYFILE); undo with uninstall.sh or 'hikari caddy unintegrate'"
  if [ -n "$TS_FQDN" ]; then
    echo "  Dashboard URL:    https://${TS_FQDN}:${TAILNET_PORT}${BASE_PATH%/}/"
  fi
else
  echo "  Caddy executable: $RESOLVED_CADDY_BIN ($CADDY_ORIGIN)"
  echo "  Caddy config:     $ETC_HIKARI/Caddyfile"
  if [ -n "$TS_FQDN" ]; then
    BP_CLEAN="${BASE_PATH%/}"
    echo "  Dashboard URL:    https://${TS_FQDN}:${TAILNET_PORT}${BP_CLEAN}/"
  else
    echo "  Dashboard URL:    Run 'hikari doctor' once Tailscale is logged in to render Caddyfile with your .ts.net FQDN."
  fi
fi
echo "  Install log:      $LOG_FILE"
echo "  Recovery/status:  /opt/hikari/versions/current/hikari doctor"

if [ "$TARGET_OS" = "macos" ] && [ -z "$ROOT_PREFIX" ] && [ "$SYSTEMD_MODE" = "auto" ]; then
  echo "Readiness report (service context and TLS are checked independently):"
  "$REL_DIR/hikari" doctor --config "$CONFIG_PATH" --caddy-bin "$RESOLVED_CADDY_BIN" || {
    echo "Installation files are in place; readiness checks need attention. See the report and $LOG_DIR." >&2
    exit 1
  }
fi
