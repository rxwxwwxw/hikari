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

CERT_DIR="$ROOT/Application Support/hikari/certificates/cert.Fixture1"
mkdir -p "$CERT_DIR"
printf '%s\n' box.tail.ts.net > "$CERT_DIR/fqdn"
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj '/CN=box.tail.ts.net' \
  -keyout "$CERT_DIR/tls.key" -out "$CERT_DIR/tls.crt" >/dev/null 2>&1
"$REPO_ROOT/bin/hikari" caddy render --config "$ROOT/config.json" --fqdn box.tail.ts.net \
  --tailscale-ip 100.64.0.10 --tls-cert-dir "$CERT_DIR" --out "$ROOT/Caddyfile.managed"
"$CADDY_BIN" validate --config "$ROOT/Caddyfile.managed" --adapter caddyfile
"$CADDY_BIN" adapt --config "$ROOT/Caddyfile.managed" --adapter caddyfile > "$ROOT/adapted-managed.json"
python3 - "$ROOT/adapted-managed.json" "$CERT_DIR" <<'PYTLS'
import json, pathlib, sys
config = json.loads(pathlib.Path(sys.argv[1]).read_text())
cert_dir = pathlib.Path(sys.argv[2])
files = config["apps"]["tls"]["certificates"]["load_files"]
assert len(files) == 1 and files[0]["certificate"] == str(cert_dir / "tls.crt")
assert files[0]["key"] == str(cert_dir / "tls.key")
PYTLS
if "$REPO_ROOT/bin/hikari" caddy render --config "$ROOT/config.json" --fqdn renamed.tail.ts.net \
  --tailscale-ip 100.64.0.10 --tls-cert-dir "$CERT_DIR" --out "$ROOT/Caddyfile.managed" >/dev/null 2>&1; then
  echo 'Managed certificate was rendered for a different MagicDNS hostname' >&2
  exit 1
fi
echo 'Pinned Caddy validated managed certificate paths and rejected a changed MagicDNS hostname.'

python3 "$REPO_ROOT/tests/install/test_signed_install.py" --caddy "$CADDY_BIN"
