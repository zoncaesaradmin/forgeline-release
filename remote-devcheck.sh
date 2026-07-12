#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
CONFIG_PATH="${PWD}/.env"

SKIP_DEVCHECK=0
FRESH_RUN=0

SERVER_HOST=''
SERVER_USER=''
SERVER_SSH_PORT='22'
SERVER_FORGELINE_ROOT=''
SERVER_PORT='8080'

CLIENT_HOST=''
CLIENT_USER=''
CLIENT_SSH_PORT='22'
FORGELINE_BRIDGE_ROOT=''

SSH_OPTS_SERVER=''
SSH_OPTS_CLIENT=''
DEVCHECK_SSH_OPTS=''

REMOTE_STAGE_DIR_SERVER='/tmp/forgeline-release-stage'
REMOTE_STAGE_DIR_CLIENT='/tmp/forgeline-release-stage'

VERSION='latest'
VERIFY_CHECKSUMS='1'
START_SERVER='true'
RUN_DEVCHECK='true'
BOOTSTRAP_CLIENT_SSH_TO_SERVER='false'
DEVCHECK_BRIDGE_ADDR='127.0.0.1:6280'
SSH_CONNECT_TIMEOUT='10'
RSYNC_TIMEOUT='30'

LOCAL_RUN_BASE="${ROOT_DIR}/.run/remote-devcheck"
LOCAL_RUN_DIR=''

server_target=''
client_target=''
server_rsync_ssh=''
client_rsync_ssh=''
server_ssh_cmd=()
client_ssh_cmd=()

usage() {
  cat <<'EOF'
Usage: ./remote-devcheck.sh [--config /path/to/.env] [options]

Options:
  --config PATH            Config file to source
  --fresh                  Remove the server/client ForgeLine roots before reinstalling
  --skip-devcheck          Skip the final remote devcheck run
  --help                   Show this help
EOF
}

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

bool_true() {
  case "${1:-0}" in
    1 | true | TRUE | yes | YES)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

ensure_absolute_path() {
  case "$1" in
    /*)
      return 0
      ;;
    *)
      fail "$2 must be an absolute path. Got: $1"
      ;;
  esac
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --config)
        [ "$#" -ge 2 ] || fail "--config requires a path"
        CONFIG_PATH="$2"
        shift 2
        ;;
      --fresh)
        FRESH_RUN=1
        shift
        ;;
      --skip-devcheck)
        SKIP_DEVCHECK=1
        shift
        ;;
      --help)
        usage
        exit 0
        ;;
      *)
        fail "Unknown argument: $1"
        ;;
    esac
  done
}

load_config() {
  [ -f "$CONFIG_PATH" ] || fail "Config file not found: $CONFIG_PATH"
  set -a
  # shellcheck disable=SC1090
  . "$CONFIG_PATH"
  set +a
}

validate_config() {
  [ -n "$SERVER_HOST" ] || fail "SERVER_HOST must be set in $CONFIG_PATH"
  [ -n "$SERVER_USER" ] || fail "SERVER_USER must be set in $CONFIG_PATH"
  [ -n "$SERVER_FORGELINE_ROOT" ] || fail "SERVER_FORGELINE_ROOT must be set in $CONFIG_PATH"
  [ -n "$CLIENT_HOST" ] || fail "CLIENT_HOST must be set in $CONFIG_PATH"
  [ -n "$CLIENT_USER" ] || fail "CLIENT_USER must be set in $CONFIG_PATH"
  [ -n "$FORGELINE_BRIDGE_ROOT" ] || fail "FORGELINE_BRIDGE_ROOT must be set in $CONFIG_PATH"

  ensure_absolute_path "$REMOTE_STAGE_DIR_SERVER" "REMOTE_STAGE_DIR_SERVER"
  ensure_absolute_path "$REMOTE_STAGE_DIR_CLIENT" "REMOTE_STAGE_DIR_CLIENT"
  ensure_absolute_path "$SERVER_FORGELINE_ROOT" "SERVER_FORGELINE_ROOT"
  ensure_absolute_path "$FORGELINE_BRIDGE_ROOT" "FORGELINE_BRIDGE_ROOT"

  if [ "$FRESH_RUN" -eq 1 ] && [ "$REMOTE_STAGE_DIR_SERVER" = "$SERVER_FORGELINE_ROOT" ]; then
    fail "REMOTE_STAGE_DIR_SERVER must not equal SERVER_FORGELINE_ROOT when --fresh is used"
  fi
  if [ "$FRESH_RUN" -eq 1 ] && [ "$REMOTE_STAGE_DIR_CLIENT" = "$FORGELINE_BRIDGE_ROOT" ]; then
    fail "REMOTE_STAGE_DIR_CLIENT must not equal FORGELINE_BRIDGE_ROOT when --fresh is used"
  fi
}

build_ssh_commands() {
  server_target="${SERVER_USER}@${SERVER_HOST}"
  client_target="${CLIENT_USER}@${CLIENT_HOST}"

  server_ssh_cmd=(ssh -p "$SERVER_SSH_PORT" -o BatchMode=yes -o ConnectTimeout="$SSH_CONNECT_TIMEOUT" -o ConnectionAttempts=1 -o ServerAliveInterval=30 -o ServerAliveCountMax=4)
  if [ -n "$SSH_OPTS_SERVER" ]; then
    read -r -a server_extra <<< "$SSH_OPTS_SERVER"
    server_ssh_cmd+=("${server_extra[@]}")
  fi

  client_ssh_cmd=(ssh -p "$CLIENT_SSH_PORT" -o BatchMode=yes -o ConnectTimeout="$SSH_CONNECT_TIMEOUT" -o ConnectionAttempts=1 -o ServerAliveInterval=30 -o ServerAliveCountMax=4)
  if [ -n "$SSH_OPTS_CLIENT" ]; then
    read -r -a client_extra <<< "$SSH_OPTS_CLIENT"
    client_ssh_cmd+=("${client_extra[@]}")
  fi

  server_rsync_ssh="ssh -p ${SERVER_SSH_PORT} -o BatchMode=yes -o ConnectTimeout=${SSH_CONNECT_TIMEOUT} -o ConnectionAttempts=1 -o ServerAliveInterval=30 -o ServerAliveCountMax=4"
  if [ -n "$SSH_OPTS_SERVER" ]; then
    server_rsync_ssh="${server_rsync_ssh} ${SSH_OPTS_SERVER}"
  fi

  client_rsync_ssh="ssh -p ${CLIENT_SSH_PORT} -o BatchMode=yes -o ConnectTimeout=${SSH_CONNECT_TIMEOUT} -o ConnectionAttempts=1 -o ServerAliveInterval=30 -o ServerAliveCountMax=4"
  if [ -n "$SSH_OPTS_CLIENT" ]; then
    client_rsync_ssh="${client_rsync_ssh} ${SSH_OPTS_CLIENT}"
  fi
}

run_server_command() {
  "${server_ssh_cmd[@]}" "$server_target" "$@"
}

run_client_command() {
  "${client_ssh_cmd[@]}" "$client_target" "$@"
}

run_server_script() {
  local script="$1"
  shift
  "${server_ssh_cmd[@]}" "$server_target" 'bash -s' -- "$@" <<< "$script"
}

run_client_script() {
  local script="$1"
  shift
  "${client_ssh_cmd[@]}" "$client_target" 'bash -s' -- "$@" <<< "$script"
}

run_to_log() {
  local log_file="$1"
  shift
  set +e
  "$@" 2>&1 | tee "$log_file"
  local cmd_status=${PIPESTATUS[0]}
  set -e
  return "$cmd_status"
}

validate_local_prereqs() {
  require_command bash
  require_command ssh
  require_command rsync
  require_command curl
  require_command mktemp
  require_command tee
  require_command date
}

validate_local_bundle() {
  local product
  for product in forgeline forgeline-bridge forgeline-devcheck forgeline-devchecklogs; do
    [ -f "${ROOT_DIR}/release/${product}/${VERSION}/SHA256SUMS" ] || fail "Missing release bundle file: release/${product}/${VERSION}/SHA256SUMS"
  done

  [ -f "${ROOT_DIR}/install.sh" ] || fail "Missing install.sh in repo root"
  [ -f "${ROOT_DIR}/install-bridge.sh" ] || fail "Missing install-bridge.sh in repo root"
  [ -f "${ROOT_DIR}/devcheck.sh" ] || fail "Missing devcheck.sh in repo root"
}

create_local_run_dir() {
  local timestamp
  timestamp="$(date '+%Y%m%d-%H%M%S')"
  LOCAL_RUN_DIR="${LOCAL_RUN_BASE}/${timestamp}"
  mkdir -p "$LOCAL_RUN_DIR"
}

check_remote_host() {
  local label="$1"
  shift
  local remote_os
  section "Check ${label}"
  remote_os="$("$@" uname -s | tr -d '\r')"
  case "$remote_os" in
    Linux | Darwin)
      info "${label} OS: ${remote_os}"
      ;;
    *)
      fail "${label} is unsupported for this orchestrator: ${remote_os}"
      ;;
  esac

  "$@" command -v bash >/dev/null
  "$@" command -v rsync >/dev/null
  "$@" command -v curl >/dev/null
  "$@" command -v ssh >/dev/null
  "$@" command -v mktemp >/dev/null
  "$@" command -v pkill >/dev/null
  if [ "$label" = 'server' ]; then
    "$@" command -v nohup >/dev/null
  fi
}

prepare_remote_stage_dirs() {
  section "Prepare remote stage directories"

  run_server_script '
set -euo pipefail
mkdir -p "$1"
' "$REMOTE_STAGE_DIR_SERVER"

  run_client_script '
set -euo pipefail
mkdir -p "$1"
' "$REMOTE_STAGE_DIR_CLIENT"
}

fresh_cleanup() {
  section "Fresh cleanup"

  run_to_log "${LOCAL_RUN_DIR}/fresh-cleanup-server.log" \
    run_server_script '
set -euo pipefail
server_root="$1"
binary="${server_root%/}/.install/bin/forgeline"
if [ -n "$server_root" ] && [ "$server_root" != "/" ]; then
  pkill -f "$binary" 2>/dev/null || true
  rm -rf "$server_root"
  echo "Removed server root: $server_root"
else
  echo "Refusing to remove invalid server root: $server_root" >&2
  exit 1
fi
' "$SERVER_FORGELINE_ROOT"

  run_to_log "${LOCAL_RUN_DIR}/fresh-cleanup-client.log" \
    run_client_script '
set -euo pipefail
bridge_root="$1"
stage_dir="$2"
bridge_binary="${bridge_root%/}/.install/bin/forgeline-bridge"
if [ -n "$bridge_root" ] && [ "$bridge_root" != "/" ]; then
  pkill -f "$bridge_binary" 2>/dev/null || true
  pkill -f "${stage_dir%/}/devcheck.sh" 2>/dev/null || true
  pkill -f '/forgeline-devcheck' 2>/dev/null || true
  rm -rf "$bridge_root"
  echo "Removed client bridge root: $bridge_root"
else
  echo "Refusing to remove invalid bridge root: $bridge_root" >&2
  exit 1
fi
' "$FORGELINE_BRIDGE_ROOT" "$REMOTE_STAGE_DIR_CLIENT"
}

stage_bundle_to_host() {
  local label="$1"
  local target="$2"
  local stage_dir="$3"
  local rsync_ssh="$4"

  section "Stage bundle to ${label}"
  rsync -az --delete \
    --exclude '.git/' \
    --exclude '.run/' \
    --exclude '.build/' \
    --exclude '.agents/' \
    --exclude '.codex/' \
    -e "$rsync_ssh" \
    "${ROOT_DIR}/" "${target}:${stage_dir}/"
  info "Staged repo bundle to ${label}:${stage_dir}"
}

ensure_client_keypair() {
  run_client_script '
set -euo pipefail
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
key_path="${HOME}/.ssh/id_ed25519"
if [ ! -f "$key_path" ]; then
  ssh-keygen -t ed25519 -N "" -f "$key_path" >/dev/null
fi
chmod 600 "$key_path"
chmod 644 "${key_path}.pub"
cat "${key_path}.pub"
'
}

bootstrap_client_ssh_to_server() {
  section "Bootstrap client SSH trust to server"
  local client_pubkey
  client_pubkey="$(ensure_client_keypair)"

  run_server_script '
set -euo pipefail
pubkey="$1"
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
touch "$HOME/.ssh/authorized_keys"
chmod 600 "$HOME/.ssh/authorized_keys"
if ! grep -qxF "$pubkey" "$HOME/.ssh/authorized_keys"; then
  printf "%s\n" "$pubkey" >> "$HOME/.ssh/authorized_keys"
fi
' "$client_pubkey"

  info "Client public key ensured on server authorized_keys."
}

verify_client_to_server_ssh() {
  section "Verify client-to-server SSH"
  run_client_script '
set -euo pipefail
server_host="$1"
server_port="$2"
server_user="$3"
server_root="$4"
extra_ssh_opts="${5-}"
ssh_cmd=(ssh -p "$server_port" -o BatchMode=yes -o StrictHostKeyChecking=accept-new)
if [ -n "$extra_ssh_opts" ]; then
  read -r -a extra <<< "$extra_ssh_opts"
  ssh_cmd+=("${extra[@]}")
fi
"${ssh_cmd[@]}" "${server_user}@${server_host}" "test -d \"$server_root\" || test ! -e \"$server_root\""
' "$SERVER_HOST" "$SERVER_SSH_PORT" "$SERVER_USER" "$SERVER_FORGELINE_ROOT" "$DEVCHECK_SSH_OPTS"
}

install_server() {
  section "Install ForgeLine on server"
  run_to_log "${LOCAL_RUN_DIR}/server-install.log" \
    run_server_script '
set -euo pipefail
server_root="$1"
stage_dir="$2"
version="$3"
verify_checksums="$4"
export FORGELINE_ROOT="$server_root"
export BASE_URL="file://${stage_dir}/release"
export README_URL="file://${stage_dir}/README.md"
export VERSION="$version"
export VERIFY_CHECKSUMS="$verify_checksums"
bash "${stage_dir}/install.sh"
' "$SERVER_FORGELINE_ROOT" "$REMOTE_STAGE_DIR_SERVER" "$VERSION" "$VERIFY_CHECKSUMS"
}

start_server() {
  section "Start ForgeLine on server"
  run_to_log "${LOCAL_RUN_DIR}/server-start.log" \
    run_server_script '
set -euo pipefail
server_root="$1"
server_port="$2"
binary="${server_root%/}/.install/bin/forgeline"
boot_log="${server_root%/}/.runtime/logs/forgeline-boot.log"
[ -x "$binary" ] || { echo "Missing server binary at $binary" >&2; exit 1; }
mkdir -p "${server_root%/}/.runtime/logs"
pkill -f "$binary" 2>/dev/null || true
export FORGELINE_ROOT="$server_root"
nohup "$binary" < /dev/null > "$boot_log" 2>&1 &
attempts=0
while :; do
  if curl -ksS -o /dev/null "https://127.0.0.1:${server_port}/" 2>/dev/null \
    && curl -ksS -o /dev/null "https://127.0.0.1:${server_port}/mcp" 2>/dev/null; then
    echo "ForgeLine server is listening on port ${server_port} (REST + MCP at /mcp)"
    exit 0
  fi
  attempts=$((attempts + 1))
  if [ "$attempts" -ge 80 ]; then
    echo "ForgeLine server did not become ready. Check ${boot_log}" >&2
    exit 1
  fi
  sleep 1
done
' "$SERVER_FORGELINE_ROOT" "$SERVER_PORT"
}

verify_server_ready() {
  section "Verify ForgeLine server is running"
  run_to_log "${LOCAL_RUN_DIR}/server-ready-check.log" \
    run_server_script '
set -euo pipefail
server_root="$1"
server_port="$2"
binary="${server_root%/}/.install/bin/forgeline"
boot_log="${server_root%/}/.runtime/logs/forgeline-boot.log"
[ -x "$binary" ] || { echo "Missing server binary at $binary" >&2; exit 1; }
if curl -ksS -o /dev/null "https://127.0.0.1:${server_port}/" 2>/dev/null \
  && curl -ksS -o /dev/null "https://127.0.0.1:${server_port}/mcp" 2>/dev/null; then
  echo "ForgeLine server is already listening on port ${server_port} (REST + MCP at /mcp)"
  exit 0
fi
echo "ForgeLine server is not running on port ${server_port} (REST + MCP at /mcp)." >&2
echo "Start it first, or leave START_SERVER=true so remote-devcheck.sh starts it." >&2
echo "If startup is failing, check ${boot_log}." >&2
exit 1
' "$SERVER_FORGELINE_ROOT" "$SERVER_PORT"
}

install_client_bridge() {
  section "Install ForgeLine Bridge on client"
  run_to_log "${LOCAL_RUN_DIR}/client-install.log" \
    run_client_script '
set -euo pipefail
bridge_root="$1"
stage_dir="$2"
version="$3"
verify_checksums="$4"
export FORGELINE_BRIDGE_ROOT="$bridge_root"
export BASE_URL="file://${stage_dir}/release"
export README_URL="file://${stage_dir}/README.md"
export VERSION="$version"
export VERIFY_CHECKSUMS="$verify_checksums"
bash "${stage_dir}/install-bridge.sh"
' "$FORGELINE_BRIDGE_ROOT" "$REMOTE_STAGE_DIR_CLIENT" "$VERSION" "$VERIFY_CHECKSUMS"
}

start_client_bridge() {
  section "Start ForgeLine Bridge on client"
  run_to_log "${LOCAL_RUN_DIR}/client-start.log" \
    run_client_script '
set -euo pipefail
bridge_root="$1"
bridge_addr="$2"
binary="${bridge_root%/}/.install/bin/forgeline-bridge"
log_file="${bridge_root%/}/.runtime/logs/forgeline-bridge.log"
[ -x "$binary" ] || { echo "Missing bridge binary at $binary" >&2; exit 1; }
mkdir -p "${bridge_root%/}/.runtime/logs"
pkill -f "$binary" 2>/dev/null || true
nohup "$binary" --addr "$bridge_addr" --workspace-root "$bridge_root" --log-file "$log_file" < /dev/null > /dev/null 2>&1 &
attempts=0
mcp_request='\''{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"remote-devcheck","version":"0.1"}}}'\''
while :; do
  if curl -sf "http://${bridge_addr}/mcp" -H "Content-Type: application/json" -d "$mcp_request" 2>/dev/null | grep -q "\"protocolVersion\""; then
    echo "ForgeLine Bridge is ready at http://${bridge_addr}/mcp"
    exit 0
  fi
  attempts=$((attempts + 1))
  if [ "$attempts" -ge 60 ]; then
    echo "ForgeLine Bridge did not become ready. Check ${log_file}" >&2
    exit 1
  fi
  sleep 1
done
' "$FORGELINE_BRIDGE_ROOT" "$DEVCHECK_BRIDGE_ADDR"
}

run_remote_devcheck() {
  section "Run remote devcheck on client"
  run_to_log "${LOCAL_RUN_DIR}/devcheck.log" \
    run_client_script '
set -euo pipefail
server_host="$1"
server_user="$2"
server_root="$3"
bridge_root="$4"
server_port="$5"
server_ssh_port="$6"
bridge_addr="$7"
stage_dir="$8"
version="$9"
verify_checksums="${10-1}"
devcheck_ssh_opts="${11-}"
export SERVER_HOST="$server_host"
export SERVER_USER="$server_user"
export SERVER_FORGELINE_ROOT="$server_root"
export FORGELINE_BRIDGE_ROOT="$bridge_root"
export SERVER_PORT="$server_port"
export SERVER_SSH_PORT="$server_ssh_port"
export DEVCHECK_BRIDGE_ADDR="$bridge_addr"
export VERSION="$version"
export VERIFY_CHECKSUMS="$verify_checksums"
export BASE_URL="file://${stage_dir}/release"
export README_URL="file://${stage_dir}/README.md"
export INSTALL_BRIDGE_SCRIPT_PATH="${stage_dir}/install-bridge.sh"
export SSH_OPTS="$devcheck_ssh_opts"
bash "${stage_dir}/devcheck.sh"
' "$SERVER_HOST" "$SERVER_USER" "$SERVER_FORGELINE_ROOT" "$FORGELINE_BRIDGE_ROOT" "$SERVER_PORT" "$SERVER_SSH_PORT" "$DEVCHECK_BRIDGE_ADDR" "$REMOTE_STAGE_DIR_CLIENT" "$VERSION" "$VERIFY_CHECKSUMS" "$DEVCHECK_SSH_OPTS"
}

collect_logs() {
  section "Collect logs"

  mkdir -p "${LOCAL_RUN_DIR}/client-devcheck-logs"
  if rsync -az --timeout="$RSYNC_TIMEOUT" -e "$client_rsync_ssh" \
    "${client_target}:${FORGELINE_BRIDGE_ROOT%/}/.devcheck/logs/" \
    "${LOCAL_RUN_DIR}/client-devcheck-logs/"; then
    info "Pulled client devcheck logs into ${LOCAL_RUN_DIR}/client-devcheck-logs"
  else
    warn "Could not pull client devcheck logs."
  fi

  mkdir -p "${LOCAL_RUN_DIR}/server-runtime-logs"
  if rsync -az --timeout="$RSYNC_TIMEOUT" -e "$server_rsync_ssh" \
    "${server_target}:${SERVER_FORGELINE_ROOT%/}/.runtime/logs/" \
    "${LOCAL_RUN_DIR}/server-runtime-logs/"; then
    info "Pulled server runtime logs into ${LOCAL_RUN_DIR}/server-runtime-logs"
  else
    warn "Could not pull server runtime logs."
  fi
}

print_summary() {
  section "Summary"
  info "Local run directory: ${LOCAL_RUN_DIR}"
  info "Server host:         ${SERVER_HOST}"
  info "Client host:         ${CLIENT_HOST}"
  info "Server root:         ${SERVER_FORGELINE_ROOT}"
  info "Bridge root:         ${FORGELINE_BRIDGE_ROOT}"
}

main() {
  parse_args "$@"
  load_config
  validate_config
  validate_local_prereqs
  validate_local_bundle
  create_local_run_dir
  build_ssh_commands

  check_remote_host "server" run_server_command
  check_remote_host "client" run_client_command
  prepare_remote_stage_dirs

  stage_bundle_to_host "server" "$server_target" "$REMOTE_STAGE_DIR_SERVER" "$server_rsync_ssh"
  stage_bundle_to_host "client" "$client_target" "$REMOTE_STAGE_DIR_CLIENT" "$client_rsync_ssh"

  if [ "$FRESH_RUN" -eq 1 ]; then
    fresh_cleanup
  fi

  if bool_true "$BOOTSTRAP_CLIENT_SSH_TO_SERVER"; then
    bootstrap_client_ssh_to_server
  fi

  verify_client_to_server_ssh

  install_server

  if bool_true "$START_SERVER"; then
    start_server
  else
    info "Skipping server start. Expecting an already running ForgeLine server."
  fi

  verify_server_ready

  install_client_bridge

  local devcheck_status=0
  if [ "$SKIP_DEVCHECK" -eq 0 ] && bool_true "$RUN_DEVCHECK"; then
    info "Bridge startup is intentionally left to devcheck.sh."
    set +e
    run_remote_devcheck
    devcheck_status=$?
    set -e
  else
    start_client_bridge
    info "Skipping devcheck run."
  fi

  collect_logs

  if [ "$devcheck_status" -ne 0 ]; then
    fail "Remote devcheck failed. See ${LOCAL_RUN_DIR}"
  fi

  print_summary
}

main "$@"
