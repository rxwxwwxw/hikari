#!/bin/bash
# hikari-owned network boundary reconciler. No telemetry or peer HTTP requests.
set -euo pipefail
CONFIG=${1:?config path required}
CADDY=${2:?Caddy executable required}
RUNTIME=${3:?runtime directory required}
INTERVAL=${HIKARI_NETWORK_RECONCILE_S:-$(cat "$(dirname "$CONFIG")/network-reconcile-seconds" 2>/dev/null || printf 60)}
case "$INTERVAL" in *[!0-9]*|'') echo 'Invalid reconciliation interval' >&2; exit 2;; esac
if [ "$INTERVAL" -ne 0 ] && [ "$INTERVAL" -lt 15 ]; then
  echo 'Reconciliation interval must be zero or at least 15 seconds' >&2; exit 2
fi
RELEASE=${4:-/opt/hikari/versions/current}
CERT_STORE=${5:-}
HIKARI="$RELEASE/hikari"
TEMPLATE="$RELEASE/caddy/Caddyfile.tmpl"
CHILD=""
TIMER=""
stop_child() {
  if [ -n "$CHILD" ]; then
    local watchdog
    kill "$CHILD" 2>/dev/null || true
    (sleep 10; kill -KILL "$CHILD" 2>/dev/null || true) &
    watchdog=$!
    wait "$CHILD" 2>/dev/null || true
    kill "$watchdog" 2>/dev/null || true
    wait "$watchdog" 2>/dev/null || true
    CHILD=""
  fi
}
cleanup() { stop_child; if [ -n "$TIMER" ]; then kill "$TIMER" 2>/dev/null || true; fi; rm -f "$RUNTIME/Caddyfile.next"; }
trap 'exit 0' TERM INT
trap cleanup EXIT
umask 077
mkdir -p "$RUNTIME"
LAST=""
if [ -f "$RUNTIME/Caddyfile" ]; then LAST=$(cat "$RUNTIME/Caddyfile"); fi
LAST_GENERATION=""
while :; do
  CERT_ARGS=()
  RETRY_INTERVAL=$INTERVAL
  CERT_READY=1
  if [ -n "$CERT_STORE" ]; then
    GENERATION=$(/usr/bin/readlink "$CERT_STORE/current" || true)
    if [[ "$GENERATION" =~ ^cert\.[A-Za-z0-9]{8}$ ]] &&
      [ -r "$CERT_STORE/$GENERATION/tls.key" ] &&
      /usr/bin/openssl x509 -in "$CERT_STORE/$GENERATION/tls.crt" -noout -checkend 0 >/dev/null 2>&1; then
      CERT_ARGS=(--tls-cert-dir "$CERT_STORE/$GENERATION")
    else
      CERT_READY=0
      if [ "$INTERVAL" -gt 15 ]; then RETRY_INTERVAL=15; fi
    fi
  fi
  if [ -n "$CERT_STORE" ] && [ "$INTERVAL" -eq 0 ]; then
    # Startup-only network reconciliation still needs to consume local renewals.
    RETRY_INTERVAL=15
    if [ "$CERT_READY" -eq 1 ] && [ "$GENERATION" = "$LAST_GENERATION" ] &&
      [ -n "$CHILD" ] && kill -0 "$CHILD" 2>/dev/null; then
      sleep "$RETRY_INTERVAL" &
      TIMER=$!
      wait "$TIMER" || true
      TIMER=""
      continue
    fi
  fi
  if [ "$CERT_READY" -eq 1 ] &&
    NEXT=$("$HIKARI" caddy render --config "$CONFIG" --template "$TEMPLATE" --out - ${CERT_ARGS[@]+"${CERT_ARGS[@]}"}); then
    if [ -z "$CHILD" ] || ! kill -0 "$CHILD" 2>/dev/null || [ "$NEXT" != "$LAST" ]; then
      if [ "$NEXT" != "$LAST" ] || [ ! -f "$RUNTIME/Caddyfile" ]; then
        printf '%s\n' "$NEXT" > "$RUNTIME/Caddyfile.next"
      fi
      CHECK="$RUNTIME/Caddyfile"
      if [ -f "$RUNTIME/Caddyfile.next" ]; then CHECK="$RUNTIME/Caddyfile.next"; fi
      if "$HIKARI" caddy validate --config "$CONFIG" --caddy-bin "$CADDY" --caddyfile "$CHECK"; then
        stop_child
        if [ -f "$RUNTIME/Caddyfile.next" ]; then mv -f "$RUNTIME/Caddyfile.next" "$RUNTIME/Caddyfile"; fi
        LAST="$NEXT"
        LAST_GENERATION=${GENERATION:-}
        "$CADDY" run --adapter caddyfile --config "$RUNTIME/Caddyfile" &
        CHILD=$!
      else
        # Keep a working certificate only when the candidate changes no routes or binding.
        if [ "$(printf '%s\n' "$NEXT" | sed '/^[[:space:]]*tls /d')" != \
             "$(printf '%s\n' "$LAST" | sed '/^[[:space:]]*tls /d')" ]; then
          stop_child
        fi
        rm -f "$RUNTIME/Caddyfile.next"
      fi
    fi
  else
    # Keep the HTTPS boundary closed until a safe tailnet-only config exists.
    stop_child
    echo 'hikari-caddy: waiting for Tailscale identity, interface and certificate access' >&2
  fi
  if [ "$RETRY_INTERVAL" -eq 0 ]; then
    if [ -z "$CHILD" ]; then exit 1; fi
    wait "$CHILD" || exit $?
    exit 0
  fi
  sleep "$RETRY_INTERVAL" &
  TIMER=$!
  wait "$TIMER" || true
  TIMER=""
done
