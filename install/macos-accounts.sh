#!/bin/bash
# Sourced by install.sh only for a real, privileged macOS installation.
create_macos_account() {
  local account="$1" home_dir="$2" uid
  if id "$account" >/dev/null 2>&1; then
    # Never adopt an unrelated account with the same name.
    if ! /usr/bin/dscl . -read "/Users/$account" RealName 2>/dev/null | grep -q 'hikari service'; then
      echo "Refusing to adopt existing account $account; inspect it manually." >&2
      exit 1
    fi
    if [ "$(id -u "$account")" -eq 0 ]; then echo "Refusing privileged service identity $account" >&2; exit 1; fi
    return
  fi
  if /usr/bin/dscl . -read "/Groups/$account" >/dev/null 2>&1; then
    echo "Refusing to adopt existing group $account without its service account" >&2; exit 1
  fi
  uid=400
  while [ "$uid" -lt 500 ]; do
    if [ -z "$(/usr/bin/dscl . -search /Users UniqueID "$uid")" ] \
        && [ -z "$(/usr/bin/dscl . -search /Groups PrimaryGroupID "$uid")" ]; then break; fi
    uid=$((uid + 1))
  done
  if [ "$uid" -ge 500 ]; then echo 'No unused system account ID available' >&2; exit 1; fi
  /usr/bin/dscl . -create "/Groups/$account"
  /usr/bin/dscl . -create "/Groups/$account" PrimaryGroupID "$uid"
  /usr/bin/dscl . -create "/Users/$account"
  /usr/bin/dscl . -create "/Users/$account" UniqueID "$uid"
  /usr/bin/dscl . -create "/Users/$account" PrimaryGroupID "$uid"
  /usr/bin/dscl . -create "/Users/$account" RealName 'hikari service'
  /usr/bin/dscl . -create "/Users/$account" NFSHomeDirectory "$home_dir"
  /usr/bin/dscl . -create "/Users/$account" UserShell /usr/bin/false
  /usr/bin/dscl . -create "/Users/$account" IsHidden 1
  /usr/bin/dscl . -create "/Users/$account" Password '*'
}

create_macos_config_group() {
  local group="_hikari_config" gid account
  if /usr/bin/dscl . -read "/Groups/$group" >/dev/null 2>&1; then
    if ! /usr/bin/dscl . -read "/Groups/$group" RealName | grep -q 'hikari service'; then
      echo "Refusing to adopt existing group $group" >&2; exit 1
    fi
  else
    gid=400
    while [ "$gid" -lt 500 ] && [ -n "$(/usr/bin/dscl . -search /Groups PrimaryGroupID "$gid")" ]; do gid=$((gid + 1)); done
    if [ "$gid" -ge 500 ]; then echo 'No unused service group ID available' >&2; exit 1; fi
    /usr/bin/dscl . -create "/Groups/$group"
    /usr/bin/dscl . -create "/Groups/$group" PrimaryGroupID "$gid"
    /usr/bin/dscl . -create "/Groups/$group" RealName 'hikari service configuration'
  fi
  for account in _hikari _hikari_caddy; do
    /usr/sbin/dseditgroup -o edit -a "$account" -t user "$group"
  done
}
