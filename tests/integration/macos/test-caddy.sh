#!/bin/bash
# Validate actual Caddy adaptation without starting a listener or obtaining certs.
set -euo pipefail
REPO_ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
ROOT=$(mktemp -d /tmp/hikari-caddy-test-XXXXXX)
trap 'rm -rf "$ROOT"' EXIT
CADDY_BIN=${CADDY_BIN:-}
if [ "${1:-}" = --download-pinned ]; then
  case "$(uname -m)" in arm64|aarch64) ARCH=arm64; TAG=ARM64;; x86_64) ARCH=amd64; TAG=AMD64;; *) exit 2;; esac
  VERSION=$(sed -n 's/^CADDY_PINNED_VERSION="\([^"]*\)"/\1/p' "$REPO_ROOT/install/install.sh")
  EXPECTED=$(sed -n "s/^CADDY_SHA512_MAC_${TAG}=\"\([^\"]*\)\"/\1/p" "$REPO_ROOT/install/install.sh")
  test -n "$VERSION" && test -n "$EXPECTED"
  curl -fsSL --max-time 45 "https://github.com/caddyserver/caddy/releases/download/v${VERSION}/caddy_${VERSION}_mac_${ARCH}.tar.gz" -o "$ROOT/caddy.tgz"
  ACTUAL=$(shasum -a 512 "$ROOT/caddy.tgz" | awk '{print $1}')
  test "$ACTUAL" = "$EXPECTED"
  tar -xzf "$ROOT/caddy.tgz" -C "$ROOT" caddy
  CADDY_BIN="$ROOT/caddy"
fi
if [ -z "$CADDY_BIN" ] || [ ! -x "$CADDY_BIN" ]; then echo 'Set CADDY_BIN or pass --download-pinned' >&2; exit 2; fi
python3 - "$ROOT" <<'PY'
import json,pathlib,sys
root=pathlib.Path(sys.argv[1])
config={"schema_version":1,"listen":{"base_path":"/hikari"},
        "paths":{"state_dir":str(root/"Application Support/hikari/state"),"web_dir":str(root/"Web Assets")}}
(root/"config.json").write_text(json.dumps(config))
PY
"$REPO_ROOT/bin/hikari" caddy render --config "$ROOT/config.json" --fqdn box.tail.ts.net \
  --tailscale-ip 100.64.0.10 --out "$ROOT/Caddyfile"
"$CADDY_BIN" validate --config "$ROOT/Caddyfile" --adapter caddyfile
"$CADDY_BIN" adapt --config "$ROOT/Caddyfile" --adapter caddyfile > "$ROOT/adapted.json"
python3 - "$ROOT" <<'PY'
import json,pathlib,sys
root=pathlib.Path(sys.argv[1]); config=json.loads((root/"adapted.json").read_text())
assert config["admin"]["disabled"] is True
assert config["storage"]["root"]==str(root/"Application Support/hikari/state/caddy")
servers=list(config["apps"]["http"]["servers"].values())
assert len(servers)==1 and servers[0]["listen"]==["100.64.0.10:9100"]
assert servers[0]["automatic_https"]["disable_redirects"] is True
serialized=json.dumps(config)
assert "/hikari/api/v1/*" in serialized
assert str(root/"Web Assets") in serialized
PY
echo 'Pinned Caddy validated macOS spaced paths, prefixed routes and tailnet-only listener.'

python3 "$REPO_ROOT/tests/install/test_signed_install.py" --caddy "$CADDY_BIN"
