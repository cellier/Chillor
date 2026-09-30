# Building and packaging

This is a source release. It intentionally excludes developer conversations, screenshots, workspaces, credentials, model weights, runtime binaries, and historical internal notes.

## Runtime inputs

1. Install Apple's Command Line Tools (`xcode-select --install`) and verify `swift --version` reports Swift 6 or later.
2. Obtain a **relocatable ARM64 CPython 3.12** distribution, such as an install-only build from [python-build-standalone](https://github.com/astral-sh/python-build-standalone). Verify its upstream checksums before extracting. Set `CHILLOR_PYTHON_SOURCE` to the extracted directory containing `bin/python3`. A virtual environment or a Homebrew executable alone is not a relocatable runtime.
3. Obtain a compatible ARM64 Ollama distribution from [Ollama](https://github.com/ollama/ollama). Set `CHILLOR_MODEL_RUNTIME_SOURCE` to a runtime directory containing executable `ollama` and all adjacent libraries/backends it requires. The existing app starts `ollama serve`; preserve its runtime layout and license notices. An installed Ollama application's `Contents/Resources` may provide this layout; verify it for your version.
4. Run the two setup scripts, then `scripts/build.sh` as shown in the README. Setup copies these explicit inputs into ignored directories. It does not download unknown binaries or use a private developer cache.

Python packages are version-pinned in `Resources/AgentTools/agent-requirements.lock`. The lock is a version snapshot, not a cryptographic supply-chain guarantee. Installation needs package-registry access. If a package/version is unavailable for your build host, report the failure rather than silently changing it. Runtime versions are not yet automatically fetched or checksum-pinned; fully automated reproducible release builds remain future work.

Swift rendering dependencies are vendored with licenses in `Vendor/`. `swift build -c release` can validate the native source independently of runtime packaging.

## Installer

```sh
./scripts/package-dmg.sh 0.1.0-preview
```

This packages `outputs/Chillor.app`, verifies the signature, mounts the DMG read-only, compares its complete app manifest against the build, and writes checksums. Files go to `outputs/内测试用包/`. A custom local `安装与试用说明.txt` there overrides the repository's `docs/public/INSTALL.txt`.

Default signing is ad hoc for development. Public end-user distribution should have a stable Developer ID identity and a separately implemented notarization workflow. Do not describe an ad hoc build as notarized. Do not include model weights or user state in releases.
