# forgeline-release

Public release repository for forgeline

This repository is for distribution only. It contains installable artifacts and
user-facing documentation, not private source code or internal build logic.

## Available products

- `forgeline`: installs the combined `forgeline` app binary that embeds both backend and MCP

## Supported platforms

- macOS: `amd64`, `arm64`
- Linux: `amd64`, `arm64`
- Windows: `amd64`, `arm64`

## Artifact resolution

The installer auto-detects your operating system and CPU architecture, then
downloads the matching release artifact:

- macOS Intel: `forgeline_darwin_amd64`
- macOS Apple Silicon: `forgeline_darwin_arm64`
- Linux x86_64: `forgeline_linux_amd64`
- Linux ARM64: `forgeline_linux_arm64`
- Windows x86_64: `forgeline_windows_amd64.exe`
- Windows ARM64: `forgeline_windows_arm64.exe`

Architecture only affects which binary is downloaded. It does not change the
default install directory.

## Install the latest forgeline release

Default install:

```bash
export FORGELINE_HOME=/mnt/large-disk/forgeline
curl -fsSL https://raw.githubusercontent.com/zoncaesaradmin/forgeline-release/main/install.sh | bash
```

This installs to:

```text
$FORGELINE_HOME/.local/bin/forgeline
```

Explicit user-local install:

```bash
curl -fsSL https://raw.githubusercontent.com/zoncaesaradmin/forgeline-release/main/install.sh | \
  FORGELINE_HOME=/mnt/large-disk/forgeline bash
```

Explicit install directory override:

```bash
curl -fsSL https://raw.githubusercontent.com/zoncaesaradmin/forgeline-release/main/install.sh | \
  FORGELINE_HOME=/mnt/large-disk/forgeline INSTALL_DIR=/opt/forgeline/bin bash
```

Recommended install when workspaces should live on a larger mounted disk:

```bash
curl -fsSL https://raw.githubusercontent.com/zoncaesaradmin/forgeline-release/main/install.sh | \
  FORGELINE_HOME=/mnt/large-disk/forgeline bash
```

## Install a specific version

```bash
curl -fsSL https://raw.githubusercontent.com/zoncaesaradmin/forgeline-release/main/install.sh | \
  PRODUCT=forgeline VERSION=v0.1.0 FORGELINE_HOME=/mnt/large-disk/forgeline bash
```

## Install behavior by platform

- macOS: combined app binary install with manual start/stop guidance
- Linux: combined app binary install with manual start/stop guidance
- Windows: combined app binary install with manual start/stop guidance

## Install from this public repo

No `GITHUB_TOKEN` is required. The installer downloads artifacts directly from:

```text
https://raw.githubusercontent.com/zoncaesaradmin/forgeline-release/main/release/forgeline/latest/
```

## Refresh release artifacts

This repo also includes a helper script to rebuild and refresh the latest forgeline
release payload from the private source repo.

Run:

```bash
./build.sh
```

What `build.sh` does:

1. clones or updates `../forgeline`, or falls back to `https://github.com/zoncaesaradmin/forgeline.git`
2. checks out `main`
3. auto-detects the release-capable source subdirectory, currently `app/`
4. runs `make release` there and finds the built `forgeline_*` combined app binaries
5. copies them into `release/forgeline/latest/`
6. regenerates `release/forgeline/latest/SHA256SUMS`

Defaults:

- local source repo: `../forgeline`
- fallback source repo: `https://github.com/zoncaesaradmin/forgeline.git`
- source ref: `main`
- source checkout: `.build/forgeline`
- build subdir: auto-detected, currently `app`
- target release dir: `release/forgeline/latest`

Optional overrides:

- `PRIMARY_REPO_URL`
- `FALLBACK_REPO_URL`
- `SOURCE_REF`
- `WORK_ROOT`
- `SOURCE_DIR`
- `BUILD_SUBDIR`
- `BUILD_DIR`
- `TARGET_DIR`

## Install to a custom directory

```bash
curl -fsSL https://raw.githubusercontent.com/zoncaesaradmin/forgeline-release/main/install.sh | \
  PRODUCT=forgeline VERSION=latest FORGELINE_HOME=/mnt/large-disk/forgeline INSTALL_DIR=/opt/forgeline/bin bash
```

## What the installer does

The installer:

1. detects your operating system and architecture
2. resolves the correct artifact under `release/<product>/<version>/`
3. downloads `SHA256SUMS` and the matching binary
4. verifies the checksum by default
5. installs or updates the binary in `INSTALL_DIR`
6. installs a local copy of this repo README as `forgeline-README.md` next to the binary
7. prints what it installed, updated, or skipped
8. prints the log file locations, the configured `FORGELINE_HOME`, and simple manual start/stop commands

Default settings:

- `PRODUCT=forgeline`
- `VERSION=latest`
- `FORGELINE_HOME` must be set before install
- `INSTALL_DIR=$FORGELINE_HOME/.local/bin` unless overridden
- `VERIFY_CHECKSUMS=1`
- `REPO_OWNER=zoncaesaradmin`
- `REPO_NAME=forgeline-release`
- `REPO_REF=main`
- `SERVICE_ADDR=:8080`
- `SERVICE_MCP_ADDR=:8081`

Optional overrides:

- `FORGELINE_HOME`
- `BINARY_NAME`
- `BASE_URL`
- `README_URL`

## Upgrade behavior

The same `install.sh` command is used for both fresh installs and upgrades.

- Running the installer again downloads the current artifact from the selected
  `VERSION` path and replaces the installed binary.
- The binary replacement is done by writing a temp file and atomically moving
  it into place.
- The installer does not start the process automatically.
- Each run prints the installed binary path, the log file location, and manual
  start and stop commands.

## Installed location

By default, the forgeline binary is installed to:

```text
$FORGELINE_HOME/.local/bin/forgeline
```

If you set `INSTALL_DIR`, the binary is installed there instead. For a
user-local install, the binary path is usually:

```text
$FORGELINE_HOME/.local/bin/forgeline
```

## Run it

After installation:

```bash
$FORGELINE_HOME/.local/bin/forgeline --help
```

Manual start command shape:

```bash
$FORGELINE_HOME/.local/bin/forgeline &
```

By default, the embedded backend binds `0.0.0.0:8080` and the embedded MCP server binds `0.0.0.0:8081`.

Manual stop command:

```bash
pkill -f "$FORGELINE_HOME/.local/bin/forgeline"
```

`FORGELINE_HOME` is the runtime workspace/state home. When set, it drives:

```text
$FORGELINE_HOME/state
$FORGELINE_HOME/state/workspaces
$FORGELINE_HOME/state/controlplane.sqlite
```

`FORGELINE_HOME` is required for the release installer and for normal installed runtime usage. Set it before running the installer and keep it available in the environment when starting forgeline.

## Logs

The installer uses log paths under `FORGELINE_HOME`:

- backend log: `$FORGELINE_HOME/.local/state/forgeline/forgeline.log`
- MCP log: `$FORGELINE_HOME/.local/state/forgeline/forgeline-mcp.log`

For more runtime options after install, the installer also places a local copy of this README at:

```text
<install-dir>/forgeline-README.md
```

## Uninstall

Remove the installed binary:

```bash
rm -f "$FORGELINE_HOME/.local/bin/forgeline"
```

If you overrode `INSTALL_DIR`, remove the binary from that location instead.
