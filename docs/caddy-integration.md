# Existing Caddy: inspection and integration

hikari can add its dashboard site to a Caddy server you already run, instead of starting its own isolated `hikari-caddy`.

The installers do this by default. `--caddy-mode` / `-CaddyMode`, or `caddy.mode` in `config.json`, accepts:
- `auto` (default): join when safe, otherwise isolated;
- `integrate`: join or fail before writing;
- `isolated`: never touch an existing Caddy;
- `snippet`: only write a snippet.

The installer's plan says which mode it chose and why, before anything changes. Add `--reload` / `-Reload` (or `caddy.reload: true`) to reload the joined Caddy; otherwise the reload command is printed. A later `--repair` with a different mode reverses the previous choice first, and uninstall removes hikari's block, restoring your Caddyfile byte for byte.

The same operations are available directly:

## Commands

```bash
hikari caddy inspect                       # read-only: detected Caddy service, parsed sites, conflicts, verdict
hikari caddy inspect --json --caddy /usr/bin/caddy
hikari caddy integrate --dry-run           # show exactly what would change, verified by `caddy adapt`
hikari caddy integrate [--reload]          # apply (requires a caddy binary to verify)
hikari caddy unintegrate [--reload]        # remove; the Caddyfile is restored byte for byte
hikari caddy status                        # what is recorded in <state_dir>/caddy-integration.json
hikari caddy reload                        # reload the joined Caddy (never restarts it)
```

Without `--caddyfile`, hikari detects the Caddy service:

- **Linux:** the systemd unit `caddy.service`.
- **macOS:** the Homebrew launchd plist.
- **Windows:** any SCM service running `caddy.exe run --config …`.

It reads the `--config` file from that service definition. `--fqdn`, `--tailscale-ip` and `--port` override values that are otherwise read from `tailscale status`.

## What hikari changes, and nothing else

1. **Append mode (default):** three marked lines at the very end of your Caddyfile:
   ```
   # BEGIN hikari (managed; remove with `hikari caddy unintegrate`)
   import hikari.caddy
   # END hikari
   ```
   It also writes `hikari.caddy` next to the Caddyfile: one site block for `https://<your-machine>.ts.net:9100`, bound to the Tailscale IP, using Tailscale certificates.
2. **Drop-in mode:** if your Caddyfile already has a top-level glob import such as `import sites/*.caddy`, hikari only writes `sites/hikari.caddy`, and your Caddyfile is not modified at all.

Edits are byte-offset appends, never a rewrite. Line endings (LF/CRLF), a UTF-8 BOM and a missing final newline are all preserved, and removal restores the exact original bytes. A timestamped backup (`<Caddyfile>.hikari-backup-<unix time>`, last 3 kept) is written before any change. Writes are atomic: rename on Unix, `ReplaceFileW` on Windows so the file's ACL is kept.

## When hikari refuses

hikari falls back to its isolated Caddy instead of editing when any of these is true:

- the Caddyfile does not parse, or `caddy adapt` fails on the *original*;
- the service uses `--resume` (config managed through the admin API), a JSON config, or another adapter;
- something already listens on the hikari port, already serves your Tailscale name on that port, or a global `servers`, `http_port` or `https_port` option touches it;
- addresses use `{$ENV}` placeholders that cannot be resolved offline;
- the file carries a config-management header (Ansible, Puppet, Chef, Salt, NixOS, "do not edit");
- the imports cannot be evaluated: a cycle, the same file imported twice, or wildcards in directory names;
- the hikari markers are duplicated or were edited by hand (removing them could delete your content);
- a file already exists where hikari's site file would go, and hikari did not write it;
- Caddy is older than 2.6, or no caddy binary is available to verify the change.

## How a change is verified

Before writing, hikari runs `caddy adapt` (pure: no network, no servers, no storage writes) on the original Caddyfile and on candidate files placed next to it. The candidates are removed afterwards.

**What must stay identical:** every original server, keyed by its listen addresses, and every original TLS automation policy must be deep-equal afterwards, as must all top-level and non-HTTP/TLS settings.

**The only allowed differences:**
- one server listening on `<tailscale-ip>:<port>`;
- TLS policies that name only your Tailscale FQDN.

Three differences Caddy itself introduces when any site is added are treated as equivalent. Each was found by running the corpus against real Caddy 2.9.1, still holds on the pinned 2.11.9, and is covered by a unit test:
- **Handle group names:** `handle` groups are numbered across the whole config, so adding a site can rename `group0` to `group2` in your servers. They are compared modulo a consistent per-server renaming.
- **Config path in `file_server`:** Caddy puts the config file's own path in `file_server`'s hide list, and the candidate file has a different name. That path is mapped back to the real one before comparing.
- **Default TLS policies:** once hikari's Tailscale policy exists, Caddy also emits default-behaviour policies for your sites (e.g. `{"subjects":["example.com"]}`, or `{}` for host-less sites). These are accepted only if they are identical to the original default and name only hosts your config already serves.

hikari checks again after writing and restores the backup if anything differs.

**Reloading:** with `--reload`, hikari reloads through your own systemd unit (`systemctl reload caddy`) or with `caddy reload`. If the reload fails, it restores the original files and reloads again. On Caddy 2.11 and newer, a reload that fails (for example because hikari's port is taken) stops Caddy's existing sites before it gives up, so they stay down for the moment until that restoring reload brings them back up. Caddy 2.9 kept serving the old config throughout. If your Caddy has `admin off` and there is no systemd unit, hikari will not restart your server; it prints the command to run instead. Without `--reload`, hikari prints the exact reload command.

## Tests

- `dub test` runs the lexer, parser, analysis, edit and preservation tests over `tests/fixtures/caddyfiles/`. `expectations.json` describes every fixture: sites, ports, binds, listeners, verdict.
- `tests/integration/caddy/differential.ps1 -Caddy <caddy>` replays the corpus against a real Caddy. hikari's listener set must equal what `caddy adapt` reports, and both must reject the broken fixtures. Every integrable fixture must pass a verified integrate, a no-op second integrate, and an unintegrate that restores the original bytes. CI runs it on Linux and Windows with the pinned, checksum-verified Caddy.
