#!/bin/bash
# One-shot certificate maintenance for the standalone Tailscale macOS app.
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
export TAILSCALE_BE_CLI=1
umask 077

APP=/Applications/Tailscale.app
CLI="$APP/Contents/MacOS/Tailscale"
RENEW_BEFORE=1209600

bounded() {
  /usr/bin/perl -e 'alarm shift; exec @ARGV or die "Could not start command\n"' "$@"
}

verify_app() {
  bounded 15 /usr/bin/codesign --verify --strict \
    -R='anchor apple generic and identifier "io.tailscale.ipn.macsys" and certificate leaf[subject.OU] = "W5364U7YZB"' \
    "$APP"
}

local_name() {
  local status name
  status=$(bounded 8 "$CLI" status --json) || return 1
  [ "$(printf '%s' "$status" | /usr/bin/plutil -extract BackendState raw -o - -)" = Running ] || return 1
  name=$(printf '%s' "$status" | /usr/bin/plutil -extract Self.DNSName raw -o - -) || return 1
  name=$(printf '%s' "${name%.}" | tr '[:upper:]' '[:lower:]')
  [ "${#name}" -le 253 ] && [[ "$name" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+ts\.net$ ]] || return 1
  printf '%s\n' "$name"
}

write_status() {
  local state=$1 status_file
  [ "$(cat "$STORE/status" 2>/dev/null || true)" != "$state" ] || return 0
  status_file=$(mktemp "$STORE/.status.XXXXXXXX")
  printf '%s\n' "$state" > "$status_file"
  chgrp "$CADDY_GROUP" "$status_file"
  chmod 0640 "$status_file"
  mv -fh "$status_file" "$STORE/status"
}

validate_pair() {
  local dir=$1 name=$2 leaf_public key_public chain
  local -a chain_args
  [ -f "$dir/tls.crt" ] && [ -f "$dir/tls.key" ] || return 1
  [ "$(stat -f %z "$dir/tls.crt")" -le 65536 ] && [ "$(stat -f %z "$dir/tls.key")" -le 16384 ] || return 1
  /usr/bin/openssl x509 -in "$dir/tls.crt" -noout -checkend "$RENEW_BEFORE" >/dev/null || return 1
  leaf_public=$(/usr/bin/openssl x509 -in "$dir/tls.crt" -pubkey -noout) || return 1
  key_public=$(/usr/bin/openssl pkey -in "$dir/tls.key" -passin pass: -pubout) || return 1
  [ -n "$leaf_public" ] && [ "$leaf_public" = "$key_public" ] || return 1
  /usr/bin/awk -v dir="$dir" '
    /^-----BEGIN CERTIFICATE-----$/ { if (++count > 8) exit 1; path = dir "/chain." count }
    path != "" { print > path }
    /^-----END CERTIFICATE-----$/ && path != "" { close(path); path = "" }
    END { if (!count || path != "") exit 1 }
  ' "$dir/tls.crt" || return 1
  chain_args=()
  for chain in "$dir"/chain.*; do chain_args+=(-c "$chain"); done
  bounded 15 /usr/bin/security verify-cert -q -L -p ssl -n "$name" "${chain_args[@]}" || return 1
  rm -f "$dir"/chain.*
}

maintain_certificate() {
  [ "$(id -u)" = 0 ] || return 1
  STORE=${1:?certificate store required}
  CADDY_GROUP=${2:?Caddy group required}
  [ -d "$STORE" ] && [ ! -L "$STORE" ] &&
    [ "$(stat -f '%u:%OLp' "$STORE")" = "0:750" ] || return 1

  local name active stage generation
  if ! verify_app >/dev/null 2>&1; then
    write_status app_unavailable
    return 1
  fi
  if ! name=$(local_name 2>/dev/null); then
    write_status tailscale_unavailable
    return 1
  fi
  active=$(readlink "$STORE/current" || true)
  if [[ "$active" =~ ^cert\.[A-Za-z0-9]{8}$ ]] &&
    [ "$(cat "$STORE/$active/fqdn" 2>/dev/null || true)" = "$name" ] &&
    [ -s "$STORE/$active/tls.key" ] &&
    /usr/bin/openssl x509 -in "$STORE/$active/tls.crt" -noout -checkend "$RENEW_BEFORE" >/dev/null 2>&1; then
    if [ "$(stat -f '%OLp:%Sg' "$STORE/current")" != "750:$CADDY_GROUP" ]; then
      chgrp -h "$CADDY_GROUP" "$STORE/current"
      chmod -h 0750 "$STORE/current"
    fi
    write_status ready
    return 0
  fi

  stage=$(mktemp -d "$STORE/.stage.XXXXXXXX")
  STAGING_CERT=$stage
  # The staging directory and publication link are writable only by this job.
  trap 'rm -rf "$STAGING_CERT"; rm -f "$STORE/.current.next"' EXIT
  if ! bounded 90 "$CLI" cert --min-validity=336h --cert-file="$stage/tls.crt" \
      --key-file="$stage/tls.key" "$name" </dev/null >/dev/null 2>&1; then
    write_status issuance_failed
    return 1
  fi
  if ! validate_pair "$stage" "$name" >/dev/null 2>&1; then
    write_status invalid_certificate
    return 1
  fi
  printf '%s\n' "$name" > "$stage/fqdn"
  chgrp "$CADDY_GROUP" "$stage" "$stage/"{fqdn,tls.crt,tls.key}
  chmod 0640 "$stage/"{fqdn,tls.crt,tls.key}
  chmod 0750 "$stage"
  generation="cert.${stage##*.}"
  [ ! -e "$STORE/$generation" ] || return 1
  mv "$stage" "$STORE/$generation"
  rm -f "$STORE/.current.next"
  ln -s "$generation" "$STORE/.current.next"
  # macOS checks the symlink's own permissions for readlink(2).
  chgrp -h "$CADDY_GROUP" "$STORE/.current.next"
  chmod -h 0750 "$STORE/.current.next"
  mv -fh "$STORE/.current.next" "$STORE/current"
  write_status ready

  # Retain old generations long enough for a concurrent Caddy restart.
  find "$STORE" -mindepth 1 -maxdepth 1 -type d -name 'cert.????????' \
    ! -name "$generation" -mtime +7 -exec rm -rf {} \;
}

maintain_certificate "$@"
