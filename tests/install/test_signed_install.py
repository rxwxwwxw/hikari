#!/usr/bin/env python3
"""Run the real Unix release bootstrap/installer against a disposable Caddyfile."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('bootstrap', ROOT / 'install/bootstrap.py')
bootstrap = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bootstrap)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--caddy', required=True)
    args = parser.parse_args()
    system, arch = bootstrap.target()
    if system == 'windows': raise SystemExit('Unix integration fixture only')
    with tempfile.TemporaryDirectory(prefix='hikari-signed-install-') as directory:
        work = Path(directory)
        payload = work / 'payload'; payload.mkdir()
        shutil.copy2(ROOT / 'bin/hikari', payload / 'hikari')
        shutil.copy2(ROOT / 'VERSION', payload / 'VERSION')
        for name in ('install', 'caddy', 'web'):
            shutil.copytree(ROOT / name, payload / name, ignore=shutil.ignore_patterns('__pycache__'))
        filename = f'hikari-{system}-{arch}.tar.gz'
        with tarfile.open(work / filename, 'w:gz') as archive:
            archive.add(payload, arcname='.')
        private, public = work / 'key.pem', work / 'public.pem'
        subprocess.run(['openssl', 'genpkey', '-algorithm', 'Ed25519', '-out', str(private)], check=True, capture_output=True)
        subprocess.run(['openssl', 'pkey', '-in', str(private), '-pubout', '-out', str(public)], check=True, capture_output=True)
        trust = {'repo': 'example/hikari', 'public_key': public.read_text()}
        (work / 'trust.json').write_text(json.dumps(trust))
        data = (work / filename).read_bytes()
        manifest = {'schema_version': 1, 'repo': trust['repo'], 'version': (payload / 'VERSION').read_text().strip(), 'artifacts': [
            {'os': system, 'arch': arch, 'filename': filename, 'size_bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()}]}
        (work / 'manifest.json').write_text(json.dumps(manifest))
        subprocess.run(['openssl', 'pkeyutl', '-sign', '-inkey', str(private), '-rawin', '-in', str(work / 'manifest.json'), '-out', str(work / 'manifest.sig')], check=True, capture_output=True)
        user = work / 'user'; user.mkdir()
        cf = user / 'Caddyfile'
        original = b'example.com {\n respond "keep my service"\n}\n'
        cf.write_bytes(original)
        installed = work / 'installed'
        forwarded = ['--', '--root', str(installed), '--service-mode=skip', '--tailscale-fixture', str(ROOT / 'tests/fixtures/tailscale/online_fleet.json'),
                     '--existing-caddyfile', str(cf), '--existing-caddy-bin', args.caddy, '--caddy-bin', args.caddy]
        def download(url, destination, limit):
            source = work / url.rsplit('/', 1)[1]
            assert source.stat().st_size <= limit
            shutil.copyfile(source, destination)
        with patch.object(bootstrap, 'HERE', work), patch.object(bootstrap, 'download', side_effect=download):
            assert bootstrap.main(['--dry-run'] + forwarded) == 0
            assert not installed.exists() and cf.read_bytes() == original
            assert bootstrap.main(forwarded) == 0
        assert b'# BEGIN hikari' in cf.read_bytes()
        config_dir = installed / ('Library/Application Support/hikari' if system == 'darwin' else 'etc/hikari')
        config = json.loads((config_dir / 'config.json').read_text())
        assert config['caddy']['mode'] == 'auto'
        assert config['updates']['repo'] == trust['repo']
        assert (config_dir / 'release-public-key.pem').read_text() == public.read_text()
        subprocess.run(['bash', str(ROOT / 'install/uninstall.sh'), '--root', str(installed), '--service-mode=skip'], check=True)
        assert cf.read_bytes() == original
        print('Signed archive bootstrap, default Caddy reuse, retained trust, and uninstall restoration passed.')


if __name__ == '__main__': main()
