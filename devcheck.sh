#!/usr/bin/env bash

set -euo pipefail

# Developer end-to-end verification for ForgeLine.
#
# Runs the same deep test code used during ForgeLine's own development against
# the REAL installed server and bridge — not a parallel test environment. All
# operations target the actual production installation paths.
#
# Run this ON THE BRIDGE MACHINE (where forgeline-bridge is installed) as the
# same user who installed it. The bridge machine already holds the SSH key
# trusted by the server, so no additional credentials are needed.
#
# What it does:
#   Phase 1 — full workflow test
#     Stops any running bridge, spawns a fresh one from the real installed binary
#     using the real workspace root, drives the complete workflow against the real
#     server (set_remote_server → check_remote_server → set_workspace → sync →
#     submit build → poll to completion), scans all logs for infra-level failures.
#   Phase 2 — upgrade test
#     Re-runs install-bridge.sh against the real FORGELINE_BRIDGE_ROOT to prove
#     the installer preserves runtime state, then verifies the reinstalled binary
#     starts and can read the workspace configured in Phase 1.
#
# After this script runs, the bridge's runtime config will reflect the test run:
#   - Remote server will be set to SERVER_HOST / SERVER_USER
#   - Current workspace will be set to "bridge-test-workspace"
# Restart the bridge with your normal command when you are done. Reset the
# workspace with set_workspace if you want a different active workspace.
#
# Required:
#   SERVER_HOST             ForgeLine server hostname or IP
#   SERVER_USER             SSH user on the server (trusted via authorized_keys)
#   SERVER_FORGELINE_ROOT   Path where forgeline is installed on the server
#                           (the FORGELINE_ROOT value used for install.sh there)
#   FORGELINE_BRIDGE_ROOT   Path where the bridge is installed on this machine
#                           (the FORGELINE_BRIDGE_ROOT value used for
#                           install-bridge.sh here)
#
# Optional:
#   SERVER_PORT             Backend HTTPS port on the server (default: 8080)
#   SERVER_SSH_PORT         SSH port on the server (default: 22)
#   SSH_OPTS                Extra ssh/rsync options, e.g. "-i /path/to/key"
#   DEVCHECK_BRIDGE_ADDR    Address the test bridge listens on (default:
#                           127.0.0.1:6280 — the real bridge port; any running
#                           bridge on this address is stopped before the test)
#   VERSION                 Release version of the dev tools to download
#                           (default: latest)

PRODUCT_DEVCHECK='forgeline-devcheck'
PRODUCT_DEVCHECKLOGS='forgeline-devchecklogs'
VERSION="${VERSION:-latest}"
VERIFY_CHECKSUMS="${VERIFY_CHECKSUMS:-1}"
REPO_OWNER="${REPO_OWNER:-zoncaesaradmin}"
REPO_NAME="${REPO_NAME:-forgeline-release}"
REPO_REF="${REPO_REF:-main}"
BASE_URL="${BASE_URL:-https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${REPO_REF}/release}"
README_URL="${README_URL:-https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${REPO_REF}/README.md}"

SERVER_HOST="${SERVER_HOST:-}"
SERVER_USER="${SERVER_USER:-}"
SERVER_PORT="${SERVER_PORT:-8080}"
SERVER_SSH_PORT="${SERVER_SSH_PORT:-22}"
SERVER_FORGELINE_ROOT="${SERVER_FORGELINE_ROOT:-}"
SSH_OPTS="${SSH_OPTS:-}"
FORGELINE_BRIDGE_ROOT="${FORGELINE_BRIDGE_ROOT:-}"
DEVCHECK_BRIDGE_ADDR="${DEVCHECK_BRIDGE_ADDR:-127.0.0.1:6280}"
INSTALL_BRIDGE_SCRIPT_PATH="${INSTALL_BRIDGE_SCRIPT_PATH:-}"

fail() {
  printf 'Error: %s\n' "$1" >&2
  exit 1
}

info() {
  printf '%s\n' "$1"
}

warn() {
  printf 'Warning: %s\n' "$1" >&2
}

section() {
  printf '\n== %s ==\n' "$1"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

devcheck_child_pid=''
upgrade_bridge_pid=''
pid_file=''
upgrade_pid_file=''

cleanup_devcheck_processes() {
  local exit_code=$?

  if [ -n "${devcheck_child_pid:-}" ]; then
    kill "$devcheck_child_pid" 2>/dev/null || true
    wait "$devcheck_child_pid" 2>/dev/null || true
  fi

  if [ -n "${upgrade_bridge_pid:-}" ]; then
    kill "$upgrade_bridge_pid" 2>/dev/null || true
    wait "$upgrade_bridge_pid" 2>/dev/null || true
  fi

  if [ -n "${pid_file:-}" ] && [ -f "$pid_file" ]; then
    bridge_pid="$(cat "$pid_file" 2>/dev/null || true)"
    if [ -n "$bridge_pid" ]; then
      kill "$bridge_pid" 2>/dev/null || true
      wait "$bridge_pid" 2>/dev/null || true
    fi
    rm -f "$pid_file"
  fi

  if [ -n "${upgrade_pid_file:-}" ] && [ -f "$upgrade_pid_file" ]; then
    bridge_pid="$(cat "$upgrade_pid_file" 2>/dev/null || true)"
    if [ -n "$bridge_pid" ]; then
      kill "$bridge_pid" 2>/dev/null || true
      wait "$bridge_pid" 2>/dev/null || true
    fi
    rm -f "$upgrade_pid_file"
  fi

  if [ -n "${FORGELINE_BRIDGE_ROOT:-}" ]; then
    pkill -f "${FORGELINE_BRIDGE_ROOT%/}/.install/bin/forgeline-bridge" 2>/dev/null || true
  fi
  pkill -f '/forgeline-devcheck' 2>/dev/null || true

  rm -rf "$tmp_dir"
  exit "$exit_code"
}

bool_true() {
  case "${1:-0}" in
    1 | true | TRUE | yes | YES) return 0 ;;
    *) return 1 ;;
  esac
}

checksums_enabled() {
  bool_true "$VERIFY_CHECKSUMS"
}

detect_os() {
  case "$(uname -s)" in
    Linux)   printf 'linux\n' ;;
    Darwin)  printf 'darwin\n' ;;
    MINGW* | MSYS* | CYGWIN*) printf 'windows\n' ;;
    *) fail "Unsupported operating system: $(uname -s)" ;;
  esac
}

detect_arch() {
  case "$(uname -m)" in
    x86_64 | amd64)   printf 'amd64\n' ;;
    arm64 | aarch64)  printf 'arm64\n' ;;
    *) fail "Unsupported architecture: $(uname -m)" ;;
  esac
}

download() {
  local url="$1" destination="$2"
  curl -fsSL "$url" -o "$destination" || fail "Download failed: $url"
}

sha256_file() {
  local file_path="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file_path" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file_path" | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 "$file_path" | awk '{print $NF}'
  else
    fail "No SHA-256 tool available. Install sha256sum, shasum, or openssl."
  fi
}

artifact_magic() {
  od -An -t x1 -N 4 "$1" | tr -d ' \n'
}

validate_downloaded_artifact() {
  local file_path="$1" artifact_name="$2" magic
  magic="$(artifact_magic "$file_path")"
  case "$os" in
    darwin)
      case "$magic" in
        cffaedfe | cefaedfe | feedfacf | feedface) return 0 ;;
      esac ;;
    linux)
      case "$magic" in
        7f454c46) return 0 ;;
      esac ;;
    windows)
      case "$magic" in
        4d5a*) return 0 ;;
      esac ;;
  esac
  fail "Downloaded artifact ${artifact_name} does not look like a valid ${os}/${arch} executable."
}

verify_checksum() {
  local checksums_file="$1" artifact_file="$2" artifact_name="$3"
  local expected_sum actual_sum
  expected_sum="$(awk -v name="$artifact_name" '$2 == name { print $1 }' "$checksums_file")"
  [ -n "$expected_sum" ] || fail "No checksum entry found for $artifact_name"
  actual_sum="$(sha256_file "$artifact_file")"
  [ "$expected_sum" = "$actual_sum" ] || fail "Checksum verification failed for $artifact_name"
}

install_tool_binary() {
  local product="$1" install_name="$2"
  local artifact_name="${install_name}_${os}_${arch}${artifact_suffix}"
  local release_url="${BASE_URL%/}/${product}/${VERSION}"
  local target_path="${tool_dir%/}/${install_name}${artifact_suffix}"
  local checksums_file="${tmp_dir}/${product}.SHA256SUMS"
  local artifact_file="${tmp_dir}/${artifact_name}"

  section "Install ${install_name}"
  download "${release_url}/SHA256SUMS" "$checksums_file"
  download "${release_url}/${artifact_name}" "$artifact_file"
  validate_downloaded_artifact "$artifact_file" "$artifact_name"

  if checksums_enabled; then
    verify_checksum "$checksums_file" "$artifact_file" "$artifact_name"
    info "Checksum verified."
  else
    info "Checksum verification skipped."
  fi

  cp "$artifact_file" "${target_path}.tmp.$$" || fail "Cannot write to ${target_path}"
  chmod 0755 "${target_path}.tmp.$$"
  mv -f "${target_path}.tmp.$$" "$target_path"
  info "Installed at ${target_path}"
}

port_in_use() {
  local addr="$1" host port
  host="${addr%%:*}"
  port="${addr##*:}"
  (echo >/dev/tcp/"$host"/"$port") 2>/dev/null
}

stop_bridge_on_port() {
  local addr="$1"
  local port="${addr##*:}"
  local attempts=0

  info "Stopping any running forgeline-bridge on ${addr}"
  pkill -f "${FORGELINE_BRIDGE_ROOT}/.install/bin/forgeline-bridge" 2>/dev/null || true

  while port_in_use "$addr"; do
    attempts=$((attempts + 1))
    if [ $attempts -ge 20 ]; then
      fail "Port ${addr} is still in use after waiting. Something other than forgeline-bridge may be holding it. Free port ${port} and retry."
    fi
    sleep 0.5
  done
}

collect_server_logs() {
  local dest="$1"
  mkdir -p "$dest"
  if rsync -az -e "ssh -p ${SERVER_SSH_PORT} ${SSH_OPTS}" \
    "${SERVER_USER}@${SERVER_HOST}:${SERVER_FORGELINE_ROOT%/}/.runtime/logs/" \
    "${dest}/" 2>/dev/null; then
    info "Pulled server logs into ${dest}"
  else
    warn "Could not rsync server logs from ${SERVER_USER}@${SERVER_HOST}. Continuing without them."
  fi
}

wait_for_bridge() {
  local addr="$1" i=0
  local mcp_request='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"devcheck-probe","version":"0.1"}}}'
  while [ $i -lt 40 ]; do
    if curl -sf "http://${addr}/mcp" \
         -H 'Content-Type: application/json' \
         -d "$mcp_request" 2>/dev/null | grep -q '"protocolVersion"'; then
      return 0
    fi
    i=$((i + 1))
    sleep 0.25
  done
  return 1
}

# ── Validate prerequisites ────────────────────────────────────────────────────

require_command curl
require_command uname
require_command awk
require_command mktemp
require_command mkdir
require_command cp
require_command chmod
require_command mv
require_command rm
require_command od
require_command tr
require_command ssh
require_command rsync

[ -n "$SERVER_HOST" ]           || fail "SERVER_HOST must be set. Example: export SERVER_HOST=build-server.example.com"
[ -n "$SERVER_USER" ]           || fail "SERVER_USER must be set. Example: export SERVER_USER=ubuntu"
[ -n "$SERVER_FORGELINE_ROOT" ] || fail "SERVER_FORGELINE_ROOT must be set to the path where forgeline is installed on the server. Example: export SERVER_FORGELINE_ROOT=/mnt/large-disk/forgeline"
[ -n "$FORGELINE_BRIDGE_ROOT" ] || fail "FORGELINE_BRIDGE_ROOT must be set to the path where forgeline-bridge is installed on this machine. Example: export FORGELINE_BRIDGE_ROOT=\$HOME/forgeline-bridge-workspace"

bridge_binary="${FORGELINE_BRIDGE_ROOT%/}/.install/bin/forgeline-bridge"
[ -x "$bridge_binary" ] || fail "forgeline-bridge binary not found at ${bridge_binary}. Run install-bridge.sh first."

os="$(detect_os)"
arch="$(detect_arch)"
artifact_suffix=''
[ "$os" = 'windows' ] && artifact_suffix='.exe'

# ── Setup ─────────────────────────────────────────────────────────────────────

# Dev tools download into tmp; they are deleted at exit.
tmp_dir="$(mktemp -d)"
tool_dir="${tmp_dir}/bin"
mkdir -p "$tool_dir"
trap cleanup_devcheck_processes EXIT INT TERM

# Run logs live under the real bridge root so they persist for review after
# the script exits. Cleared at the start of each run.
devcheck_log_dir="${FORGELINE_BRIDGE_ROOT%/}/.devcheck/logs"
rm -rf "${FORGELINE_BRIDGE_ROOT%/}/.devcheck"
mkdir -p "$devcheck_log_dir"

# Reset the bridge runtime config so Phase 1 starts from a clean state.
# The test writes a fresh config (set_remote_server, set_workspace) and Phase 2
# then verifies it survives install-bridge.sh. Any previous config is intentionally
# discarded — see the summary at the end for what to restore afterward.
rm -f "${FORGELINE_BRIDGE_ROOT%/}/.runtime/forgeline-config.yaml"

bridge_log_file="${devcheck_log_dir}/forgeline-bridge.log"
client_log_file="${devcheck_log_dir}/forgeline-devcheck-client.log"
server_log_dir="${devcheck_log_dir}/server"
pid_file="${FORGELINE_BRIDGE_ROOT%/}/.devcheck/forgeline-bridge.pid"

section "ForgeLine Developer End-to-End Check"
info "Server:               ${SERVER_USER}@${SERVER_HOST}:${SERVER_PORT}"
info "Server forgeline root: ${SERVER_FORGELINE_ROOT}"
info "Bridge root:          ${FORGELINE_BRIDGE_ROOT}"
info "Bridge binary:        ${bridge_binary}"
info "Run logs:             ${devcheck_log_dir}"

# ── Install dev tools ─────────────────────────────────────────────────────────

install_tool_binary "$PRODUCT_DEVCHECK" "$PRODUCT_DEVCHECK"
install_tool_binary "$PRODUCT_DEVCHECKLOGS" "$PRODUCT_DEVCHECKLOGS"

devcheck_binary="${tool_dir%/}/${PRODUCT_DEVCHECK}${artifact_suffix}"
devchecklogs_binary="${tool_dir%/}/${PRODUCT_DEVCHECKLOGS}${artifact_suffix}"

# ── Phase 1: full workflow test ───────────────────────────────────────────────

section "Phase 1: stop any running bridge, then run end-to-end workflow test"

# If a bridge is already running on this port, stop it so the test can bind.
if port_in_use "$DEVCHECK_BRIDGE_ADDR"; then
  stop_bridge_on_port "$DEVCHECK_BRIDGE_ADDR"
fi

info "Running forgeline-devcheck against ${SERVER_HOST}"
test_status=0
"$devcheck_binary" \
  --bridge-binary      "$bridge_binary" \
  --bridge-addr        "$DEVCHECK_BRIDGE_ADDR" \
  --bridge-base-url    "http://${DEVCHECK_BRIDGE_ADDR}" \
  --backend-base-url   "https://${SERVER_HOST}:${SERVER_PORT}" \
  --mcp-host           "$SERVER_HOST" \
  --mcp-port           "$SERVER_PORT" \
  --ssh-user           "$SERVER_USER" \
  --workspace-root     "$FORGELINE_BRIDGE_ROOT" \
  --remote-server-root "$SERVER_FORGELINE_ROOT" \
  --log-file           "$client_log_file" \
  --bridge-log-file    "$bridge_log_file" \
  --pid-file           "$pid_file" &
devcheck_child_pid=$!
wait "$devcheck_child_pid" || test_status=$?
devcheck_child_pid=''

collect_server_logs "$server_log_dir"

section "Phase 1: log check"
# Scan client log and server boot log for crashes, infra patterns, and non-JSON lines.
# forgeline-boot.log is overwritten on each server start so it only covers the current
# boot — safe to scan in full. The rolling forgeline.log / forgeline-mcp.log accumulate
# across restarts and are pulled for manual inspection only, not scanned here.
# The bridge log is checked separately for crash-level entries only — the negative-path
# test scenarios intentionally produce SSH "permission denied" errors which would otherwise
# be flagged by the infra-pattern check.
server_boot_log="${server_log_dir}/forgeline-boot.log"
all_logs="${client_log_file}"
[ -f "$server_boot_log" ] && all_logs="${all_logs},${server_boot_log}"
log_status=0
"$devchecklogs_binary" --logs "$all_logs" || log_status=$?
if grep -qE '"level":"(panic|fatal)"' "$bridge_log_file" 2>/dev/null; then
  log_status=1
  info "Bridge log contains crash-level entries. See ${bridge_log_file}"
fi

if [ "$test_status" -ne 0 ]; then
  fail "Phase 1 failed (forgeline-devcheck exit ${test_status}). Logs: ${devcheck_log_dir}"
fi
if [ "$log_status" -ne 0 ]; then
  fail "Phase 1 log check found infra-level failures. Logs: ${devcheck_log_dir}"
fi
info "Phase 1 passed."

# ── Phase 2: upgrade test ─────────────────────────────────────────────────────
#
# Re-run install-bridge.sh against the real FORGELINE_BRIDGE_ROOT to prove the
# installer preserves runtime state (workspace config, catalog overrides) when
# upgrading a live installation. Then verify the reinstalled binary starts and
# can read the workspace configured in Phase 1.

section "Phase 2: upgrade test — reinstall bridge over real installation"

config_file="${FORGELINE_BRIDGE_ROOT%/}/.runtime/forgeline-config.yaml"
[ -f "$config_file" ] || fail "Expected runtime config at ${config_file} — Phase 1 should have written it. Something went wrong."

if [ -n "$INSTALL_BRIDGE_SCRIPT_PATH" ]; then
  [ -x "$INSTALL_BRIDGE_SCRIPT_PATH" ] || fail "INSTALL_BRIDGE_SCRIPT_PATH is set but not executable: ${INSTALL_BRIDGE_SCRIPT_PATH}"
  info "Using staged install-bridge.sh from ${INSTALL_BRIDGE_SCRIPT_PATH}"
  install_bridge_script="$INSTALL_BRIDGE_SCRIPT_PATH"
else
  info "Downloading install-bridge.sh"
  install_bridge_script="${tmp_dir}/install-bridge.sh"
  download "https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${REPO_REF}/install-bridge.sh" "$install_bridge_script"
  chmod +x "$install_bridge_script"
fi

info "Re-running install-bridge.sh against ${FORGELINE_BRIDGE_ROOT}"
upgrade_log="${devcheck_log_dir}/upgrade-install.log"
upgrade_install_status=0
FORGELINE_BRIDGE_ROOT="$FORGELINE_BRIDGE_ROOT" \
BASE_URL="$BASE_URL" \
README_URL="$README_URL" \
VERSION="$VERSION" \
VERIFY_CHECKSUMS="$VERIFY_CHECKSUMS" \
bash "$install_bridge_script" >"$upgrade_log" 2>&1 \
  || upgrade_install_status=$?

if [ "$upgrade_install_status" -ne 0 ]; then
  info "install-bridge.sh output:"
  cat "$upgrade_log" >&2
  fail "Upgrade test: install-bridge.sh failed (exit ${upgrade_install_status}). See ${upgrade_log}"
fi

# The installer must not have wiped the runtime config.
[ -f "$config_file" ] || fail "Upgrade test: install-bridge.sh wiped ${config_file}. This is a bug in the installer."
info "Runtime config survived the reinstall."

# Verify the reinstalled binary starts and responds correctly.
info "Starting reinstalled bridge to verify it works"
upgrade_bridge_log="${devcheck_log_dir}/forgeline-bridge-upgrade.log"
upgrade_pid_file="${FORGELINE_BRIDGE_ROOT%/}/.devcheck/forgeline-bridge-upgrade.pid"

"$bridge_binary" \
  --addr           "$DEVCHECK_BRIDGE_ADDR" \
  --workspace-root "$FORGELINE_BRIDGE_ROOT" \
  --log-file       "$upgrade_bridge_log" &
upgrade_bridge_pid=$!
printf '%s' "$upgrade_bridge_pid" > "$upgrade_pid_file"

upgrade_status=0
if ! wait_for_bridge "$DEVCHECK_BRIDGE_ADDR"; then
  upgrade_status=1
  info "Upgrade test: reinstalled bridge did not become ready. See ${upgrade_bridge_log}"
else
  # Confirm workspace state survived by calling get_workspace.
  ws_response="$(curl -s "http://${DEVCHECK_BRIDGE_ADDR}/mcp" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_workspace","arguments":{}}}' \
    2>/dev/null || true)"
  if printf '%s' "$ws_response" | grep -q '"bridge-test-workspace"'; then
    info "Upgrade test: workspace state confirmed present after reinstall."
  else
    upgrade_status=1
    info "Upgrade test: get_workspace did not return bridge-test-workspace after reinstall."
    info "Response: ${ws_response}"
  fi
fi

kill "$upgrade_bridge_pid" 2>/dev/null || true
wait "$upgrade_bridge_pid" 2>/dev/null || true
upgrade_bridge_pid=''
rm -f "$upgrade_pid_file"

if [ "$upgrade_status" -ne 0 ]; then
  fail "Upgrade test failed. See ${upgrade_bridge_log}"
fi
info "Phase 2 passed: reinstall preserves runtime state and the reinstalled bridge works."

# ── Summary ───────────────────────────────────────────────────────────────────

section "Summary"
info "All checks passed."
info "  Phase 1: end-to-end workflow test — passed"
info "  Phase 2: upgrade test             — passed"
info ""
info "Logs are at ${devcheck_log_dir}"
info ""
info "The bridge runtime config now reflects this test run:"
info "  Remote server: ${SERVER_HOST} / ${SERVER_USER}"
info "  Current workspace: bridge-test-workspace"
info "Restart the bridge when you are ready to use it again:"
info "  \"${bridge_binary}\" --workspace-root \"${FORGELINE_BRIDGE_ROOT}\" &"
