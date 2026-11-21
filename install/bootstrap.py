#!/usr/bin/env python3
"""Install a signed hikari release using pinned repository trust."""
import argparse
import importlib.util
import json
from pathlib import Path
import platform
import re
import subprocess
import sys
import tempfile
import time
import urllib.request

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('release_verifier', HERE / 'verify-release.py')
verifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verifier)


class HttpsRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if not newurl.startswith('https://'):
            raise ValueError('Refusing non-HTTPS download redirect')
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def download(url, destination, limit):
    if not url.startswith('https://'):
        raise ValueError('Release downloads require HTTPS')
    opener = urllib.request.build_opener(HttpsRedirect())
    # A failed download is discarded; never append to a partial payload.
    for attempt in range(3):
        try:
            deadline = time.monotonic() + 120
            with opener.open(url, timeout=15) as response, destination.open('wb') as output:
                total = 0
                while True:
                    chunk = response.read(65536)
                    if not chunk:
                        break
                    total += len(chunk)
                    if total > limit or time.monotonic() > deadline:
                        raise ValueError('Download exceeds size or time limit')
                    output.write(chunk)
            return
        except (OSError, TimeoutError):
            destination.unlink(missing_ok=True)
            if attempt == 2:
                raise


def target():
    system = {'Linux': 'linux', 'Darwin': 'darwin', 'Windows': 'windows'}.get(platform.system())
    machine = platform.machine().lower()
    arch = {'amd64': 'x86_64', 'x86_64': 'x86_64', 'arm64': 'aarch64', 'aarch64': 'aarch64'}.get(machine)
    if system == 'darwin' and arch == 'aarch64':
        arch = 'arm64'
    if (system, arch) not in {('linux', 'x86_64'), ('linux', 'aarch64'), ('darwin', 'arm64'), ('windows', 'x86_64')}:
        raise ValueError(f'No supported release for {platform.system()} / {machine}')
    return system, arch


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--version', default='latest')
    parser.add_argument('--dry-run', action='store_true')
    parser.add_argument('--repair', action='store_true', help='Reconcile units/Caddyfile and recover any interrupted activation')
    parser.add_argument('--reload', action='store_true', help='Explicitly authorize reloading an integrated Caddy')
    parser.add_argument('--caddy-mode', choices=['auto', 'integrate', 'isolated', 'snippet'], default=None)
    parser.add_argument('installer_args', nargs=argparse.REMAINDER, help='Additional platform installer options after --')
    args = parser.parse_args(argv)
    if sys.version_info < (3, 9):
        raise ValueError('Python 3.9+ is required')
    system, arch = target()
    trust = json.loads((HERE / 'trust.json').read_text())
    repo, public_key = trust.get('repo', ''), trust.get('public_key', '')
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repo) or 'BEGIN PUBLIC KEY' not in public_key:
        raise ValueError('Bootstrap trust is not configured: obtain an independently trusted installer with a pinned release key')
    if args.version != 'latest' and not re.fullmatch(r'v?\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?', args.version):
        raise ValueError('Expected latest or a release version such as 0.2.0')
    # Fails before any download when only LibreSSL (or nothing) is available.
    verifier.find_openssl()
    release = 'latest/download' if args.version == 'latest' else 'download/v' + args.version.removeprefix('v')
    base = f'https://github.com/{repo}/releases/{release}'
    filename = f'hikari-{system}-{arch}' + ('.zip' if system == 'windows' else '.tar.gz')
    print(f'Install plan: {repo}, {args.version}, {system}-{arch}; Caddy: {args.caddy_mode or "saved setting or auto (reuse existing when safe)"}', flush=True)
    with tempfile.TemporaryDirectory(prefix='hikari-bootstrap-') as directory:
        work = Path(directory)
        key = work / 'release-public-key.pem'
        key.write_text(public_key)
        for name, limit in [('manifest.json', 1024 * 1024), ('manifest.sig', 4096), (filename, verifier.MAX_BYTES)]:
            download(base + '/' + name, work / name, limit)
        stage = work / 'release'
        verified = verifier.verify(argparse.Namespace(archive=str(work / filename), manifest=str(work / 'manifest.json'),
            signature=str(work / 'manifest.sig'), public_key=str(key), repo=repo, os=system, arch=arch, extract_dir=str(stage)))
        if args.version != 'latest' and verified != args.version.removeprefix('v'):
            raise ValueError('Signed version does not match requested version')
        if (stage / 'VERSION').read_text().strip() != verified:
            raise ValueError('Archive VERSION does not match signed manifest')
        required = ['install/readiness.py', 'install/verify-release.py', 'caddy/Caddyfile.tmpl', 'caddy/snippet.caddy.tmpl',
                    'install/install.ps1' if system == 'windows' else 'install/install.sh']
        if any(not (stage / name).is_file() for name in required):
            raise ValueError('Release lacks the bootstrap-compatible installer; choose a newer release')
        extra = args.installer_args
        if extra[:1] == ['--']:
            extra = extra[1:]
        if system == 'windows':
            command = ['powershell.exe', '-NoProfile', '-File', str(stage / 'install/install.ps1'),
                       '-BinarySource', str(work / filename), '-Repo', repo, '-PubKey', str(key),
                       '-Manifest', str(work / 'manifest.json'), '-Signature', str(work / 'manifest.sig')]
            if args.dry_run: command += ['-DryRun']
            if args.repair: command += ['-Repair']
            if args.reload: command += ['-Reload']
            if args.caddy_mode: command += ['-CaddyMode', args.caddy_mode]
        else:
            command = ['bash', str(stage / 'install/install.sh'), '--binary-source', str(work / filename),
                       '--manifest', str(work / 'manifest.json'), '--sig', str(work / 'manifest.sig'), '--repo', repo, '--pubkey', str(key)]
            if args.dry_run: command += ['--dry-run']
            if args.repair: command += ['--repair']
            if args.reload: command += ['--reload']
            if args.caddy_mode: command += ['--caddy-mode', args.caddy_mode]
        result = subprocess.run(command + extra, check=False).returncode
        if result not in (0, 2):
            print('Installation failed; see the installer error above.', file=sys.stderr)
        return result


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        sys.exit(f'Installation failed: {error}')
