# Building from source

Install LDC (`ldc2`) and DUB; Windows also needs Microsoft Visual C++ Build Tools. These are developer prerequisites, not requirements for prebuilt releases.

```sh
dub build --compiler=ldc2 --build=release
dub test --compiler=ldc2
./bin/hikari version
```

Install a trusted local build on Linux or macOS:

```sh
./install/install.sh --dry-run
sudo ./install/install.sh --reload
```

On Windows, use an Administrator PowerShell:

```powershell
.\install\install.ps1 -DryRun
.\install\install.ps1 -Reload
```

The installer uses a local trusted binary without archive verification. Downloaded archives require a signed manifest and independently trusted public key; use the [release bootstrap](install-bootstrap.md) for ordinary installation.

Build standalone bootstrap entry points with `python3 tools/package-bootstrap.py`. Outputs go to `dist/bootstrap/`; each embeds the verifier and `install/trust.json`. Run `python3 tests/install/test_bootstrap.py` and `python3 tests/integration/macos/test-release-verification.py` to test verification and readiness offline. The release workflow generates the same files alongside the signed platform archives.
