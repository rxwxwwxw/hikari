#!/usr/bin/env python3
import argparse
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch
import zipfile

ROOT = Path(__file__).resolve().parents[2]

def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / f'install/{name}.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

bootstrap = load('bootstrap')
readiness = load('readiness')


class BootstrapTests(unittest.TestCase):
    def test_signed_install_and_fail_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            private = root / 'private.pem'
            public = root / 'public.pem'
            subprocess.run(['openssl', 'genpkey', '-algorithm', 'Ed25519', '-out', str(private)], check=True, capture_output=True)
            subprocess.run(['openssl', 'pkey', '-in', str(private), '-pubout', '-out', str(public)], check=True, capture_output=True)
            (root / 'trust.json').write_text(json.dumps({'repo': 'example/hikari', 'public_key': public.read_text()}))
            for system, arch in [('linux', 'x86_64'), ('darwin', 'arm64'), ('windows', 'x86_64')]:
                filename = f'hikari-{system}-{arch}' + ('.zip' if system == 'windows' else '.tar.gz')
                files = {'VERSION': b'0.2.0\n', 'web/index.html': b'dashboard',
                         'hikari.exe' if system == 'windows' else 'hikari': b'binary',
                         'install/install.ps1' if system == 'windows' else 'install/install.sh': b'installer'}
                for name in ['install/readiness.py', 'install/verify-release.py', 'caddy/Caddyfile.tmpl', 'caddy/snippet.caddy.tmpl']:
                    files[name] = b'fixture'
                if system == 'windows':
                    with zipfile.ZipFile(root / filename, 'w') as archive:
                        for name, data in files.items(): archive.writestr(name, data)
                else:
                    with tarfile.open(root / filename, 'w:gz') as archive:
                        for name, data in files.items():
                            entry = tarfile.TarInfo(name); entry.size = len(data)
                            archive.addfile(entry, io.BytesIO(data))
                data = (root / filename).read_bytes()
                manifest = {'schema_version': 1, 'repo': 'example/hikari', 'version': '0.2.0', 'artifacts': [
                    {'os': system, 'arch': arch, 'filename': filename, 'size_bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()}]}
                (root / 'manifest.json').write_text(json.dumps(manifest))
                subprocess.run(['openssl', 'pkeyutl', '-sign', '-inkey', str(private), '-rawin', '-in', str(root / 'manifest.json'), '-out', str(root / 'manifest.sig')], check=True, capture_output=True)
                launched = []
                run = subprocess.run
                def launch(command, **kwargs):
                    if command[0] in ('bash', 'powershell.exe'):
                        launched.append(command)
                        return subprocess.CompletedProcess(command, 0)
                    return run(command, **kwargs)
                def download(url, destination, limit):
                    content = (root / url.rsplit('/', 1)[1]).read_bytes()
                    self.assertLessEqual(len(content), limit)
                    destination.write_bytes(content)
                with patch.object(bootstrap, 'HERE', root), patch.object(bootstrap, 'target', return_value=(system, arch)), patch.object(bootstrap, 'download', side_effect=download), patch.object(bootstrap.subprocess, 'run', side_effect=launch):
                    self.assertEqual(bootstrap.main(['--version', '0.2.0', '--dry-run', '--reload']), 0)
                    self.assertEqual(len(launched), 1)
                    self.assertIn('-Reload' if system == 'windows' else '--reload', launched[0])
                    launched.clear()
                    with self.assertRaises(ValueError): bootstrap.main(['--version', '0.3.0'])
                    self.assertFalse(launched)
                    (root / filename).write_bytes(b'partial download')
                    with self.assertRaises(ValueError): bootstrap.main([])
                    self.assertFalse(launched)
                    (root / filename).write_bytes(data)
                    (root / 'manifest.sig').write_bytes(b'bad signature')
                    with self.assertRaises(subprocess.CalledProcessError): bootstrap.main([])
                    self.assertFalse(launched)

    def test_download_retries_discard_partial_data(self):
        class Response:
            def __init__(self, fail): self.fail, self.reads = fail, 0
            def __enter__(self): return self
            def __exit__(self, *args): pass
            def read(self, size):
                self.reads += 1
                if self.reads == 1: return b'whole'
                if self.fail: raise OSError('interrupted')
                return b''
        from unittest.mock import Mock
        opener = Mock(); opener.open.side_effect = [Response(True), Response(False)]
        with tempfile.TemporaryDirectory() as directory, patch.object(bootstrap.urllib.request, 'build_opener', return_value=opener):
            dest = Path(directory) / 'archive'
            bootstrap.download('https://example.com/archive', dest, 100)
            self.assertEqual(dest.read_bytes(), b'whole')
        with self.assertRaises(ValueError): bootstrap.download('http://example.com/archive', Path('/unused'), 100)


class ReadinessTests(unittest.TestCase):
    def test_ready_pending_wrong_routes_and_unavailable_tls(self):
        with tempfile.TemporaryDirectory() as directory:
            Path(directory, 'index.html').write_bytes(b'dashboard')
            config = {'listen': {'base_path': '/hikari'}, 'paths': {'web_dir': directory}}
            info = {'status': 'ok', 'app': 'hikari', 'schema_version': 1, 'agent_version': '0.2.0', 'node_id': 'hikari:test', 'fqdn': 'host.tail.ts.net'}
            calls = []
            def fetch(url):
                calls.append(url)
                return b'dashboard' if url.endswith('/hikari/') else json.dumps(info).encode()
            results, url = readiness.check(config, '0.2.0', info['fqdn'], get=fetch)
            self.assertTrue(all(ok for _, ok, _ in results))
            self.assertEqual(url, 'https://host.tail.ts.net:9100/hikari/')
            self.assertTrue(all('/status' not in u and '/hardware' not in u for u in calls))
            calls.clear()
            results, _ = readiness.check(config, '0.2.0', info['fqdn'], True, fetch)
            self.assertFalse(all(ok for _, ok, _ in results))
            self.assertFalse(any(u.startswith('https') for u in calls))
            def unavailable(url):
                if url.startswith('https'): raise OSError('TLS failed')
                return fetch(url)
            results, _ = readiness.check(config, '0.2.0', info['fqdn'], get=unavailable)
            self.assertTrue(results[0][1])
            self.assertFalse(results[-1][1])
            Path(directory, 'index.html').write_bytes(b'wrong route')
            results, _ = readiness.check(config, '0.2.0', info['fqdn'], get=fetch)
            self.assertFalse(results[-1][1])
            results, _ = readiness.check(config, '0.3.0', info['fqdn'], get=fetch)
            self.assertFalse(results[0][1])
            results, _ = readiness.check(config, '0.2.0', info['fqdn'], get=lambda url: b'[]')
            self.assertFalse(results[0][1])


class OpenSslSelectionTests(unittest.TestCase):
    """Mirrors tests/platform/test_openssl.d for the bootstrap/installer verifier."""
    LIBRESSL = 'LibreSSL 3.3.6\n'
    OPENSSL3 = 'OpenSSL 3.4.0 22 Oct 2024 (Library: OpenSSL 3.4.0 22 Oct 2024)\n'
    HB_ARM = '/opt/homebrew/opt/openssl@3/bin/openssl'
    HB_INTEL = '/usr/local/opt/openssl@3/bin/openssl'

    def find(self, system, files, path_openssl=None):
        """files: {path: version output}; path_openssl: (resolved path, output) for PATH lookup."""
        outputs = dict(files)
        if path_openssl:
            outputs[path_openssl[0]] = path_openssl[1]
        ran = []
        def run_version(executable):
            ran.append(executable)
            if executable not in outputs:
                raise FileNotFoundError(executable)
            return outputs[executable]
        result = bootstrap.verifier.find_openssl(
            system=system, which=lambda name: path_openssl[0] if path_openssl else None,
            isfile=lambda path: path in files, run_version=run_version)
        return result, ran

    def test_classification(self):
        classify = bootstrap.verifier.classify_openssl
        self.assertEqual(classify(self.LIBRESSL), (False, 'LibreSSL 3.3.6', 'libressl'))
        self.assertTrue(classify(self.OPENSSL3)[0])
        self.assertTrue(classify('OpenSSL 3.0.13 30 Jan 2024')[0])
        self.assertFalse(classify('OpenSSL 1.1.1w  11 Sep 2023')[0])
        self.assertFalse(classify('')[0])
        self.assertEqual(classify('BoringSSL')[2], 'unknown')

    def test_darwin_prefers_homebrew_over_libressl_path(self):
        result, ran = self.find('Darwin', {self.HB_ARM: self.OPENSSL3}, ('/usr/bin/openssl', self.LIBRESSL))
        self.assertEqual(result, self.HB_ARM)
        self.assertEqual(ran, [self.HB_ARM])
        result, ran = self.find('Darwin', {self.HB_INTEL: self.OPENSSL3}, ('/usr/bin/openssl', self.LIBRESSL))
        self.assertEqual(result, self.HB_INTEL)
        self.assertEqual(ran, [self.HB_INTEL])

    def test_path_fallback_and_non_darwin_skip_probes(self):
        result, _ = self.find('Darwin', {}, ('/usr/local/bin/openssl', self.OPENSSL3))
        self.assertEqual(result, '/usr/local/bin/openssl')
        # Linux never consults the Homebrew locations, even if they exist.
        result, ran = self.find('Linux', {self.HB_ARM: self.OPENSSL3}, ('/usr/bin/openssl', self.OPENSSL3))
        self.assertEqual(result, '/usr/bin/openssl')
        self.assertEqual(ran, ['/usr/bin/openssl'])

    def test_windows_finds_program_files_openssl_without_path(self):
        git = r'C:\Program Files\Git\mingw64\bin\openssl.exe'
        win64 = r'C:\Program Files\OpenSSL-Win64\bin\openssl.exe'
        # Elevated shell / SYSTEM task: nothing on PATH, Git for Windows installed.
        result, ran = self.find('Windows', {git: self.OPENSSL3})
        self.assertEqual(result, git)
        self.assertEqual(ran, [git])
        result, ran = self.find('Windows', {win64: self.OPENSSL3})
        self.assertEqual(result, win64)
        # PATH remains the fallback, and other systems never probe Windows paths.
        result, _ = self.find('Windows', {}, (r'C:\tools\openssl.exe', self.OPENSSL3))
        self.assertEqual(result, r'C:\tools\openssl.exe')
        result, ran = self.find('Linux', {git: self.OPENSSL3}, ('/usr/bin/openssl', self.OPENSSL3))
        self.assertEqual(ran, ['/usr/bin/openssl'])

    def test_libressl_only_is_rejected_with_actionable_error(self):
        with self.assertRaises(ValueError) as caught:
            self.find('Darwin', {}, ('/usr/bin/openssl', self.LIBRESSL))
        message = str(caught.exception)
        self.assertIn('LibreSSL 3.3.6', message)
        self.assertIn('cannot verify Ed25519', message)
        self.assertIn('brew install openssl@3', message)
        with self.assertRaises(ValueError) as caught:
            self.find('Darwin', {})
        self.assertIn('not found on PATH', str(caught.exception))

    def test_verification_fails_closed_without_capable_openssl(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ('archive', 'manifest', 'signature', 'public_key'):
                (root / name).write_bytes(b'x')
            args = argparse.Namespace(archive=str(root / 'archive'), manifest=str(root / 'manifest'),
                                      signature=str(root / 'signature'), public_key=str(root / 'public_key'),
                                      repo='example/hikari', os='darwin', arch='arm64', extract_dir=None)
            def refuse(*_args, **_kwargs):
                raise ValueError('No Ed25519-capable OpenSSL found: /usr/bin/openssl is LibreSSL 3.3.6')
            with patch.object(bootstrap.verifier, 'find_openssl', refuse), \
                 patch.object(bootstrap.verifier.subprocess, 'run') as run:
                with self.assertRaisesRegex(ValueError, 'LibreSSL'):
                    bootstrap.verifier.verify(args)
                run.assert_not_called()


if __name__ == '__main__': unittest.main()
