# forgeline-release

Public release repository for `forgeline` and `forgeline-bridge`.

This repository is for distribution only. It contains installable artifacts and
user-facing install steps, not private source code or internal build logic.

## Which one should you install?

Install `forgeline` if you want to run the ForgeLine server itself on a build
machine or host and access ForgeLine from that installed server. This is the
main package for running the combined backend and MCP service.

Install `forgeline-bridge` only if you additionally want a PC-side local MCP
server for workstation mode, where you work on a repo locally but prepare,
sync, or build against a remote ForgeLine environment. It is an additional
package for local-to-remote workflow support, not a replacement for the main
`forgeline` server install.

Most users who only want to run the main ForgeLine server should install just
`forgeline` and stop there.

## Supported platforms

- macOS: `amd64`, `arm64`
- Linux: `amd64`, `arm64`
- Windows: `amd64`, `arm64`

## Artifact names

`forgeline`:

- `forgeline_darwin_amd64`
- `forgeline_darwin_arm64`
- `forgeline_linux_amd64`
- `forgeline_linux_arm64`
- `forgeline_windows_amd64.exe`
- `forgeline_windows_arm64.exe`

`forgeline-bridge`:

- `forgeline-bridge_darwin_amd64`
- `forgeline-bridge_darwin_arm64`
- `forgeline-bridge_linux_amd64`
- `forgeline-bridge_linux_arm64`
- `forgeline-bridge_windows_amd64.exe`
- `forgeline-bridge_windows_arm64.exe`

`forgeline-devcheck` / `forgeline-devchecklogs` (developer test tooling, built from
the same test code used during development — see [DEVELOPER-TESTING.md](DEVELOPER-TESTING.md)):

- `forgeline-devcheck_darwin_amd64` / `forgeline-devchecklogs_darwin_amd64`
- `forgeline-devcheck_darwin_arm64` / `forgeline-devchecklogs_darwin_arm64`
- `forgeline-devcheck_linux_amd64` / `forgeline-devchecklogs_linux_amd64`
- `forgeline-devcheck_linux_arm64` / `forgeline-devchecklogs_linux_arm64`
- `forgeline-devcheck_windows_amd64.exe` / `forgeline-devchecklogs_windows_amd64.exe`
- `forgeline-devcheck_windows_arm64.exe` / `forgeline-devchecklogs_windows_arm64.exe`

## Main Server: forgeline

Use this when you want to run the main ForgeLine server on a machine and access
ForgeLine from that installed server.

### Install forgeline

```bash
export FORGELINE_ROOT=/mnt/large-disk/forgeline
curl -fsSL https://raw.githubusercontent.com/zoncaesaradmin/forgeline-release/main/install.sh | bash
```

Default installed path:

```text
$FORGELINE_ROOT/.install/bin/forgeline
```

Default runtime catalog path:

```text
$FORGELINE_ROOT/.runtime/forgeline-catalog.default.yaml
```

User override catalog path:

```text
$FORGELINE_ROOT/.runtime/forgeline-catalog.override.yaml
```

With an explicit install directory:

```bash
curl -fsSL https://raw.githubusercontent.com/zoncaesaradmin/forgeline-release/main/install.sh | \
  FORGELINE_ROOT=/mnt/large-disk/forgeline INSTALL_DIR=/opt/forgeline/bin bash
```

Specific version:

```bash
curl -fsSL https://raw.githubusercontent.com/zoncaesaradmin/forgeline-release/main/install.sh | \
  VERSION=v0.1.0 FORGELINE_ROOT=/mnt/large-disk/forgeline bash
```

### Run forgeline

Manual start command shape:

```bash
nohup "$FORGELINE_ROOT/.install/bin/forgeline" \
  < /dev/null \
  > "$FORGELINE_ROOT/.runtime/logs/forgeline-boot.log" 2>&1 &
```

Manual stop command:

```bash
pkill -f "$FORGELINE_ROOT/.install/bin/forgeline"
```

`FORGELINE_ROOT` is required by the release installer. The installed runtime
derives:

```text
runtime dir:          $FORGELINE_ROOT/.runtime
default catalog:      $FORGELINE_ROOT/.runtime/forgeline-catalog.default.yaml
override catalog:     $FORGELINE_ROOT/.runtime/forgeline-catalog.override.yaml
state directory:      $FORGELINE_ROOT/.runtime/state
workspace directory:  $FORGELINE_ROOT/.runtime/state/workspaces
sqlite database:      $FORGELINE_ROOT/.runtime/state/controlplane.sqlite
backend log:          $FORGELINE_ROOT/.runtime/logs/forgeline.log
MCP log:              $FORGELINE_ROOT/.runtime/logs/forgeline-mcp.log
```

The installer places the default runtime catalog there when it is missing.
If you want your own repo names, profiles, or build targets, create and edit
the override file instead. Source now resolves catalogs in this order:

- `FORGELINE_CATALOG_FILE`, if set
- `.runtime/forgeline-catalog.override.yaml`
- legacy `.runtime/forgeline-catalog.yaml`, if present
- `.runtime/forgeline-catalog.default.yaml`

The installed app serves the REST API and the MCP surface on a single unified
port (source repo default):

```text
REST API: https://0.0.0.0:8080
MCP:      https://0.0.0.0:8080/mcp
```

## Optional Workstation Package: forgeline-bridge

Use this only when you also want a local workstation-side MCP server on your
PC or laptop for working on repos locally while syncing or building remotely
through ForgeLine.

Install this in addition to `forgeline` when you need that workstation flow.
Do not use it as a replacement for the main server package.

### Install forgeline-bridge

```bash
export FORGELINE_BRIDGE_ROOT=$HOME/forgeline-bridge-workspace
curl -fsSL https://raw.githubusercontent.com/zoncaesaradmin/forgeline-release/main/install-bridge.sh | bash
```

Default installed path:

```text
$FORGELINE_BRIDGE_ROOT/.install/bin/forgeline-bridge
```

Default runtime catalog path:

```text
$FORGELINE_BRIDGE_ROOT/.runtime/forgeline-catalog.default.yaml
```

User override catalog path:

```text
$FORGELINE_BRIDGE_ROOT/.runtime/forgeline-catalog.override.yaml
```

With an explicit install directory:

```bash
curl -fsSL https://raw.githubusercontent.com/zoncaesaradmin/forgeline-release/main/install-bridge.sh | \
  FORGELINE_BRIDGE_ROOT=$HOME/forgeline-bridge-workspace INSTALL_DIR=/opt/forgeline-bridge/bin bash
```

Specific version:

```bash
curl -fsSL https://raw.githubusercontent.com/zoncaesaradmin/forgeline-release/main/install-bridge.sh | \
  VERSION=v0.1.0 FORGELINE_BRIDGE_ROOT=$HOME/forgeline-bridge-workspace bash
```

### Run forgeline-bridge

Manual start command shape:

```bash
$FORGELINE_BRIDGE_ROOT/.install/bin/forgeline-bridge --workspace-root "$FORGELINE_BRIDGE_ROOT" &
```

Manual stop command:

```bash
pkill -f "$FORGELINE_BRIDGE_ROOT/.install/bin/forgeline-bridge"
```

`FORGELINE_BRIDGE_ROOT` is required by the bridge installer so it can
print an exact start command. The installed runtime derives:

```text
default catalog:  $FORGELINE_BRIDGE_ROOT/.runtime/forgeline-catalog.default.yaml
override catalog: $FORGELINE_BRIDGE_ROOT/.runtime/forgeline-catalog.override.yaml
config file:   $FORGELINE_BRIDGE_ROOT/.runtime/forgeline-config.yaml
state dir:     $FORGELINE_BRIDGE_ROOT/.runtime
log file:      $FORGELINE_BRIDGE_ROOT/.runtime/logs/forgeline-bridge.log
TLS cert:      $FORGELINE_BRIDGE_ROOT/.runtime/tls/forgeline-bridge/server.crt
TLS key:       $FORGELINE_BRIDGE_ROOT/.runtime/tls/forgeline-bridge/server.key
endpoint:      http://127.0.0.1:6280/mcp
```

The bridge installer places the default runtime catalog there when it is
missing. If you want your own repo names, profiles, or build targets for the
local bridge workspace, create and edit the override file instead.

This is a different default port from the main `forgeline` MCP endpoint, which
shares the server's unified port at `https://<host>:8080/mcp`.

If `.runtime/forgeline-config.yaml` is missing, the bridge can still use
source-side config defaults, but it still requires a runtime catalog from
`FORGELINE_CATALOG_FILE`, the override file, the legacy file, or the default
file.

Simple MCP verification:

```bash
curl -sS http://127.0.0.1:6280/mcp \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json' \
  -d '{
    "jsonrpc":"2.0",
    "id":1,
    "method":"initialize",
    "params":{
      "protocolVersion":"2025-03-26",
      "capabilities":{},
      "clientInfo":{"name":"curl","version":"1.0"}
    }
  }'
```

If the bridge MCP is running, that command should return a JSON-RPC response
with a `result` object and `serverInfo` for `forgeline-bridge`.

## Public installer paths

No `GITHUB_TOKEN` is required. Use these installer paths:

```text
https://raw.githubusercontent.com/zoncaesaradmin/forgeline-release/main/install.sh
https://raw.githubusercontent.com/zoncaesaradmin/forgeline-release/main/install-bridge.sh
https://raw.githubusercontent.com/zoncaesaradmin/forgeline-release/main/devcheck.sh
```

## Refresh release artifacts

Run:

```bash
./build.sh
```

What `build.sh` does:

1. freshly clones `git@github.com:zoncaesaradmin/forgeline.git`
2. checks out `main`
3. auto-detects the release-capable app subdirectory, currently `app/`
4. runs `make release` there for the combined app
5. cross-compiles `forgeline-bridge` from `bridge/`
6. cross-compiles `forgeline-devcheck` and `forgeline-devchecklogs` from `e2etests/`
   (the same end-to-end developer test code used during development)
7. copies app artifacts into `release/forgeline/latest/`
8. copies bridge artifacts into `release/forgeline-bridge/latest/`
9. copies dev-tool artifacts into `release/forgeline-devcheck/latest/` and
   `release/forgeline-devchecklogs/latest/`
10. publishes `forgeline-catalog.default.yaml` into the app and bridge release
    channels
11. regenerates all four `SHA256SUMS` files

Defaults:

- source repo: `git@github.com:zoncaesaradmin/forgeline.git`
- source ref: `main`
- source checkout: `.build/forgeline`
- app build subdir: auto-detected, currently `app`
- app target release dir: `release/forgeline/latest`
- bridge build dir: `bridge`
- bridge target release dir: `release/forgeline-bridge/latest`
- dev-tools build dir: `e2etests`
- devcheck target release dir: `release/forgeline-devcheck/latest`
- devchecklogs target release dir: `release/forgeline-devchecklogs/latest`

Optional overrides:

- `REPO_URL`
- `SOURCE_REF`
- `WORK_ROOT`
- `SOURCE_DIR`
- `BUILD_SUBDIR`
- `BUILD_DIR`
- `TARGET_DIR`
- `BRIDGE_BUILD_DIR`
- `BRIDGE_TARGET_DIR`
- `BRIDGE_RELEASE_DIR`
- `RELEASE_TARGETS`

## Uninstall

Remove the installed app binary:

```bash
rm -f "$FORGELINE_ROOT/.install/bin/forgeline"
```

Remove the installed bridge binary:

```bash
rm -f "$FORGELINE_BRIDGE_ROOT/.install/bin/forgeline-bridge"
```

If you overrode `INSTALL_DIR`, remove the binaries from that location instead.
