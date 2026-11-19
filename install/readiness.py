#!/usr/bin/env python3
"""Bounded, read-only installation readiness checks; never requests telemetry."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def fetch(url, limit=4 * 1024 * 1024, timeout=5):
    if sys.platform == 'darwin':
        # The system curl uses macOS trust. A Homebrew or python.org Python can
        # have a separate root store even when Safari and Caddy trust the chain.
        with subprocess.Popen(
            ['/usr/bin/curl', '--disable', '--noproxy', '*', '--silent',
             '--fail', '--proto', '=http,https', '--max-time', str(timeout),
             '--max-filesize', str(limit), '--write-out', '\n%{http_code}', url],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL
        ) as request:
            # Bound streamed responses even on older curl builds that only
            # enforce --max-filesize against a known Content-Length.
            payload = request.stdout.read(limit + 5)
            if len(payload) > limit + 4:
                request.kill()
                raise ValueError('Response exceeds size limit')
            if request.wait() or not payload.endswith(b'\n200'):
                raise OSError('Expected a verified HTTP 200 response')
            return payload[:-4]
    # Do not send local health checks or private telemetry to environment proxies.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    with opener.open(url, timeout=timeout) as response:
        if response.status != 200:
            raise ValueError('Expected HTTP 200')
        body = response.read(limit + 1)
        if len(body) > limit:
            raise ValueError('Response exceeds size limit')
        return body


def check(config, version, fqdn, pending_reload=False, get=fetch):
    results = []
    listen = config.get('listen', {})
    host = listen.get('loopback_bind', '127.0.0.1')
    if host not in ('127.0.0.1', '::1'):
        raise ValueError('Refusing non-loopback agent health URL')
    local = f'http://{"[::1]" if host == "::1" else host}:{int(listen.get("loopback_port", 19100))}'
    info = None
    try:
        health = json.loads(get(local + '/healthz'))
        info = json.loads(get(local + '/api/v1/info'))
        if not isinstance(health, dict) or not isinstance(info, dict):
            raise ValueError('Expected agent JSON objects')
        if (health.get('app') != 'hikari' or health.get('status') != 'ok' or info.get('app') != 'hikari'
                or info.get('schema_version') != 1 or info.get('agent_version') != version
                or not info.get('node_id')):
            raise ValueError('Unexpected agent identity or version')
        results.append(('Agent', True, 'Expected hikari version responds on loopback'))
    except (OSError, ValueError, TypeError):
        info = None
        results.append(('Agent', False, 'Start or repair the hikari service; inspect its logs'))
    fqdn = fqdn.rstrip('.').lower()
    import re
    valid_name = re.fullmatch(r'[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?\.ts\.net', fqdn) is not None
    if not valid_name:
        results.append(('Tailscale', False, 'Log into Tailscale and enable MagicDNS and HTTPS certificates, then rerun the installer'))
        return results, None
    if not info or str(info.get('fqdn', '')).rstrip('.').lower() != fqdn:
        results.append(('Service identity', False, 'The running agent cannot confirm this Tailscale name; check Tailscale access under its service account'))
    base_path = listen.get('base_path', '/').strip('/')
    url = f'https://{fqdn}:{int(listen.get("tailnet_port", 9100))}/' + (base_path + '/' if base_path else '')
    if pending_reload:
        results.append(('HTTPS', False, 'Caddy integration is written but reload was not authorized; rerun with --reload (Windows: -Reload)'))
        return results, url
    try:
        remote = json.loads(get(url + 'api/v1/info'))
        if not isinstance(remote, dict):
            raise ValueError('Expected HTTPS API JSON object')
        if (not info or remote.get('app') != 'hikari' or remote.get('schema_version') != 1
                or remote.get('node_id') != info.get('node_id') or remote.get('agent_version') != version
                or str(remote.get('fqdn', '')).rstrip('.').lower() != fqdn):
            raise ValueError('HTTPS API identity mismatch')
        html = get(url)
        expected = (Path(config['paths']['web_dir']) / 'index.html').read_bytes()
        if hashlib.sha256(html).digest() != hashlib.sha256(expected).digest():
            raise ValueError('Dashboard route does not serve the installed asset')
        results.append(('HTTPS', True, 'Certificate, API identity, and dashboard route verified'))
    except (OSError, ValueError, KeyError, TypeError):
        results.append(('HTTPS', False, 'Check the selected Caddy service logs, its certificate permissions, DNS, and the configured routes; rerun after fixing them'))
    return results, url


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', required=True)
    parser.add_argument('--version', required=True)
    parser.add_argument('--fqdn', default='')
    parser.add_argument('--pending-reload', action='store_true')
    parser.add_argument('--certificate-store', type=Path)
    parser.add_argument('--skip', action='store_true')
    args = parser.parse_args()
    if args.skip:
        print('Installed; setup incomplete (service activation skipped; readiness not checked).')
        return 0
    try:
        config = json.loads(Path(args.config).read_text(encoding='utf-8-sig'))
        deadline = time.monotonic() + (35 if args.certificate_store else 15)
        def bounded_fetch(url):
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise OSError('Readiness deadline reached')
            return fetch(url, timeout=min(5, remaining))
        while True:
            results, url = check(config, args.version, args.fqdn, args.pending_reload, bounded_fetch)
            if all(ok for _, ok, _ in results) or args.pending_reload or not url or deadline - time.monotonic() <= 2:
                break
            time.sleep(1)
    except (OSError, ValueError, TypeError) as error:
        print(f'Installed; setup incomplete: could not check readiness ({error}).')
        return 2
    ready = all(ok for _, ok, _ in results)
    if args.certificate_store and not ready:
        try:
            state = (args.certificate_store / 'status').read_text().strip()
        except OSError:
            state = 'pending'
        messages = {
            'pending': 'Waiting for the standalone Tailscale certificate job',
            'app_unavailable': 'The certificate job could not verify the standalone Tailscale app',
            'tailscale_unavailable': 'The certificate job could not read a running Tailscale identity',
            'issuance_failed': 'Tailscale could not issue the certificate. Check tailnet HTTPS settings',
            'invalid_certificate': 'The issued certificate failed hostname, key, expiry or trust checks',
            'ready': 'Certificate published. Check the isolated Caddy service and HTTPS route',
        }
        results.append(('Tailscale certificate', state == 'ready', messages.get(state, messages['pending'])))
    print('Ready' if ready else 'Installed; setup incomplete')
    for name, ok, message in results:
        print(f'  [{"pass" if ok else "action needed"}] {name}: {message}')
    if url:
        print(f'  {"Dashboard URL" if ready else "Intended address (not verified ready)"}: {url}')
    return 0 if ready else 2


if __name__ == '__main__':
    sys.exit(main())
