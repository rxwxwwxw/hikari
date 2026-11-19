#!/usr/bin/env bash
set -euo pipefail

# hikari Unix uninstaller (Linux systemd & macOS LaunchDaemons)
# Removes only hikari-owned binaries and system units/plists.
# Preserves Tailscale, existing system/Homebrew Caddy, and user config/state unless --purge is passed.
# If hikari was joined into an existing Caddy, its marked block and site file are removed first
# (the Caddyfile is restored byte for byte); that Caddy is reloaded only with --reload.

DRY_RUN=0
PURGE=0
RELOAD_CADDY=0
ROOT_PREFIX=""
SYSTEMD_MODE="auto"
TARGET_OS="auto"

usage() {
  cat <<'EOF'
Usage: install/uninstall.sh [options]

Options:
  --dry-run                        Print planned removals without changing files
  --purge                          Also delete config, nodes.json, and Caddy cert store
  --reload                         Reload the existing Caddy hikari was joined into after removing it
  --root <dir>                     Operate under target root directory (for staging tests)
  --target-os=<auto|linux|macos>   Target OS layout (default: auto via uname -s)
  --systemd-mode=<auto|skip>       Manage systemd/launchd or skip activation calls (default: auto)
  --service-mode=<auto|skip>       Alias for --systemd-mode
  -h, --help                       Show help
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --purge) PURGE=1; shift ;;
    --reload) RELOAD_CADDY=1; shift ;;
    --root=*) ROOT_PREFIX="${1#*=}"; shift ;;
    --root) ROOT_PREFIX="${2:?}"; shift 2 ;;
    --target-os=*) TARGET_OS="${1#*=}"; shift ;;
    --target-os) TARGET_OS="${2:?}"; shift 2 ;;
    --systemd-mode=*|--service-mode=*) SYSTEMD_MODE="${1#*=}"; shift ;;
    --systemd-mode|--service-mode) SYSTEMD_MODE="${2:?}"; shift 2 ;;
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

if [ -z "$ROOT_PREFIX" ] && [ "$DRY_RUN" -eq 0 ] && [ "$(id -u)" -ne 0 ]; then
  echo "System uninstall requires root privileges (or use --dry-run / --root)." >&2
  exit 1
fi

OPT_HIKARI="${ROOT_PREFIX}/opt/hikari"

remove_path() {
  local p="$1"
  if [ -e "$p" ] || [ -L "$p" ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
      echo "[dry-run] Would remove $p"
    else
      rm -rf "$p"
    fi
  fi
}

# Undo an integration into an existing Caddy before hikari's binary is removed.
if [ "$TARGET_OS" = "macos" ]; then
  U_ETC="${ROOT_PREFIX}/Library/Application Support/hikari"
  U_VAR="${ROOT_PREFIX}/Library/Application Support/hikari/state"
else
  U_ETC="${ROOT_PREFIX}/etc/hikari"
  U_VAR="${ROOT_PREFIX}/var/lib/hikari"
fi
if [ -f "$U_VAR/caddy-integration.json" ]; then
  HIKARI_BIN="$OPT_HIKARI/versions/current/hikari"
  if [ ! -x "$HIKARI_BIN" ]; then
    echo "hikari is joined into an existing Caddy but $HIKARI_BIN is missing; reinstall, or remove the '# BEGIN hikari' block by hand, then re-run." >&2
    exit 1
  fi
  UN_ARGS=(caddy unintegrate --config "$U_ETC/config.json" --state-dir "$U_VAR")
  [ "$DRY_RUN" -eq 1 ] && UN_ARGS+=(--dry-run)
  [ "$RELOAD_CADDY" -eq 1 ] && UN_ARGS+=(--reload)
  if ! UN_OUT=$("$HIKARI_BIN" "${UN_ARGS[@]}" 2>&1); then
    echo "Could not remove hikari from the existing Caddy; nothing was uninstalled. $UN_OUT" >&2
    exit 1
  fi
  echo "$UN_OUT"
fi

if [ "$TARGET_OS" = "macos" ]; then
  ETC_HIKARI="${ROOT_PREFIX}/Library/Application Support/hikari"
  VAR_HIKARI="${ROOT_PREFIX}/Library/Application Support/hikari/state"
  UNIT_DIR="${ROOT_PREFIX}/Library/LaunchDaemons"

  if [ "$SYSTEMD_MODE" = "auto" ] && [ -z "$ROOT_PREFIX" ] && command -v launchctl >/dev/null 2>&1; then
    if [ "$DRY_RUN" -eq 1 ]; then
      echo "[dry-run] Would bootout system/io.hikari.caddy and system/io.hikari.agent"
    else
      launchctl bootout system/io.hikari.recover 2>/dev/null || true
      launchctl bootout system/io.hikari.caddy 2>/dev/null || true
      launchctl bootout system/io.hikari.agent 2>/dev/null || true
    fi
  fi

  remove_path "$UNIT_DIR/io.hikari.recover.plist"
  remove_path "$UNIT_DIR/io.hikari.agent.plist"
  if [ -f "$UNIT_DIR/io.hikari.maintenance.plist" ] && grep -q 'hikari-owned maintenance' "$UNIT_DIR/io.hikari.maintenance.plist"; then
    if [ "$DRY_RUN" -eq 0 ] && [ -z "$ROOT_PREFIX" ] && [ "$SYSTEMD_MODE" = auto ]; then
      launchctl bootout system/io.hikari.maintenance 2>/dev/null || true
    fi
    remove_path "$UNIT_DIR/io.hikari.maintenance.plist"
  fi
  if [ -f "$UNIT_DIR/io.hikari.certificates.plist" ] && [ ! -L "$UNIT_DIR/io.hikari.certificates.plist" ] &&
    grep -q 'hikari-owned maintenance' "$UNIT_DIR/io.hikari.certificates.plist"; then
    if [ "$DRY_RUN" -eq 0 ] && [ -z "$ROOT_PREFIX" ] && [ "$SYSTEMD_MODE" = auto ]; then
      launchctl bootout system/io.hikari.certificates 2>/dev/null || true
    fi
    remove_path "$UNIT_DIR/io.hikari.certificates.plist"
  fi
  remove_path "$UNIT_DIR/io.hikari.caddy.plist"
  remove_path "$OPT_HIKARI"
  remove_path "$ETC_HIKARI/Caddyfile"
  remove_path "$ETC_HIKARI/Caddyfile.bak"
  remove_path "$ETC_HIKARI/hikari-snippet.caddy"

  if [ "$PURGE" -eq 1 ]; then
    remove_path "$ETC_HIKARI"
    echo "Uninstalled hikari and purged user configuration and state."
  else
    echo "Uninstalled hikari binaries and LaunchDaemons. Preserved $ETC_HIKARI (use --purge to remove)."
  fi
else
  ETC_HIKARI="${ROOT_PREFIX}/etc/hikari"
  VAR_HIKARI="${ROOT_PREFIX}/var/lib/hikari"
  UNIT_DIR="${ROOT_PREFIX}/etc/systemd/system"

  if [ "$SYSTEMD_MODE" = "auto" ] && [ -z "$ROOT_PREFIX" ] && [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
    if [ "$DRY_RUN" -eq 1 ]; then
      echo "[dry-run] Would stop and disable hikari.service and hikari-caddy.service"
    else
      if grep -q 'hikari-owned maintenance' "$UNIT_DIR/hikari-maintenance.path" 2>/dev/null; then
        systemctl disable --now hikari-maintenance.path 2>/dev/null || true
      fi
      if grep -q 'hikari-owned maintenance' "$UNIT_DIR/hikari-maintenance.timer" 2>/dev/null; then
        systemctl disable --now hikari-maintenance.timer 2>/dev/null || true
      fi
      if grep -q 'hikari-owned maintenance' "$UNIT_DIR/hikari-maintenance.service" 2>/dev/null; then
        systemctl stop hikari-maintenance.service 2>/dev/null || true
      fi
      systemctl disable --now hikari-caddy.service 2>/dev/null || true
      systemctl disable --now hikari.service 2>/dev/null || true
    fi
  fi

  for maintenance in hikari-maintenance.timer hikari-maintenance.service hikari-maintenance.path; do
    if grep -q 'hikari-owned maintenance' "$UNIT_DIR/$maintenance" 2>/dev/null; then
      remove_path "$UNIT_DIR/$maintenance"
    fi
  done
  remove_path "$UNIT_DIR/hikari.service"
  remove_path "$UNIT_DIR/hikari-caddy.service"
  remove_path "$OPT_HIKARI"
  remove_path "$ETC_HIKARI/Caddyfile"
  remove_path "$ETC_HIKARI/Caddyfile.bak"
  remove_path "$ETC_HIKARI/hikari-snippet.caddy"

  if [ "$PURGE" -eq 1 ]; then
    remove_path "$ETC_HIKARI"
    remove_path "$VAR_HIKARI"
    echo "Uninstalled hikari and purged user configuration and state."
  else
    echo "Uninstalled hikari binaries and units. Preserved $ETC_HIKARI and $VAR_HIKARI (use --purge to remove)."
  fi

  if [ "$DRY_RUN" -eq 0 ] && [ "$SYSTEMD_MODE" = "auto" ] && [ -z "$ROOT_PREFIX" ] && [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload
  fi
fi
