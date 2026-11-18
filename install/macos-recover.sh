#!/bin/bash
# Short-lived root recovery job; no telemetry, downloads or peer discovery.
# Execute the prior known-good binary so a corrupt new executable cannot prevent recovery.
set -euo pipefail
VERSIONS=${1:-/opt/hikari/versions}
CONFIG=${2:-/Library/Application Support/hikari/config.json}
PENDING="$VERSIONS/.activation-previous"
if [ ! -f "$PENDING" ]; then exit 0; fi
PREVIOUS=$(cat "$PENDING")
case "$PREVIOUS" in
  ''|*[!0-9A-Za-z.-]*|.*) echo 'Invalid activation recovery marker' >&2; exit 1 ;;
esac
if [ ! -x "$VERSIONS/$PREVIOUS/hikari" ]; then
  echo 'Prior release missing; run the trusted installer to repair hikari.' >&2
  exit 1
fi
exec "$VERSIONS/$PREVIOUS/hikari" update recover --config "$CONFIG" --versions-dir "$VERSIONS"
