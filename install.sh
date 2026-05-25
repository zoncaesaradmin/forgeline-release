#!/usr/bin/env bash

set -eu

PRODUCT="${PRODUCT:-forgeline}"
VERSION="${VERSION:-latest}"
INSTALL_DIR="${INSTALL_DIR:-}"
VERIFY_CHECKSUMS="${VERIFY_CHECKSUMS:-1}"
REPO_OWNER="${REPO_OWNER:-zoncaesaradmin}"
REPO_NAME="${REPO_NAME:-forgeline-release}"
REPO_REF="${REPO_REF:-main}"
BASE_URL="${BASE_URL:-https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${REPO_REF}/release}"
SERVICE_ADDR="${SERVICE_ADDR:-:8080}"
SYSTEM_INSTALL_DIR='/usr/local/bin'

fail() {
  printf 'Error: %s\n' "$1" >&2
  exit 1
}

info() {
  printf '%s\n' "$1"
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

detect_os() {
  case "$(uname -s)" in
    Linux)
      printf 'linux\n'
      ;;
    Darwin)
      printf 'darwin\n'
      ;;
    MINGW* | MSYS* | CYGWIN*)
      printf 'windows\n'
      ;;
    *)
      fail "Unsupported operating system: $(uname -s)"
      ;;
  esac
}

detect_arch() {
  case "$(uname -m)" in
    x86_64 | amd64)
      printf 'amd64\n'
      ;;
    arm64 | aarch64)
      printf 'arm64\n'
      ;;
    *)
      fail "Unsupported architecture: $(uname -m)"
      ;;
  esac
}

resolve_install_name() {
  if [ -n "${BINARY_NAME:-}" ]; then
    printf '%s\n' "$BINARY_NAME"
    return
  fi

  case "$PRODUCT" in
    forgeline)
      printf 'forgeline\n'
      ;;
    *)
      fail "Unsupported PRODUCT '$PRODUCT'. Set BINARY_NAME explicitly for new products."
      ;;
  esac
}

resolve_artifact_stem() {
  case "$PRODUCT" in
    forgeline)
      printf 'forgeline\n'
      ;;
    *)
      fail "Unsupported PRODUCT '$PRODUCT'. Add artifact mapping for this product."
      ;;
  esac
}

checksums_enabled() {
  bool_true "$VERIFY_CHECKSUMS"
}

download() {
  url="$1"
  destination="$2"
  curl -fsSL "$url" -o "$destination" || fail "Download failed: $url"
}

sha256_file() {
  file_path="$1"

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

verify_checksum() {
  checksums_file="$1"
  artifact_file="$2"
  artifact_name="$3"

  expected_sum="$(awk -v name="$artifact_name" '$2 == name { print $1 }' "$checksums_file")"
  [ -n "$expected_sum" ] || fail "No checksum entry found for $artifact_name"
  actual_sum="$(sha256_file "$artifact_file")"

  [ "$expected_sum" = "$actual_sum" ] || fail "Checksum verification failed for $artifact_name"
}

manual_start_command() {
  case "$os" in
    windows)
      printf '"%s" -addr "%s" -log-file "%s"\n' "$target_path" "$SERVICE_ADDR" "$runtime_log_file"
      ;;
    *)
      printf '"%s" -addr "%s" -log-file "%s"\n' "$target_path" "$SERVICE_ADDR" "$runtime_log_file"
      ;;
  esac
}

manual_stop_command() {
  case "$os" in
    windows)
      printf 'taskkill /IM "%s" /F\n' "${install_name}${artifact_suffix}"
      ;;
    *)
      printf "pkill -f '%s'\n" "$target_path"
      ;;
  esac
}

print_manual_run_instructions() {
  ensure_runtime_log_dir
  info "Start manually:"
  info "  $(manual_start_command)"
  info "Stop manually:"
  if [ "$os" = 'windows' ]; then
    info "  Close the process window, or run: $(manual_stop_command)"
  else
    info "  Press Ctrl-C if running in the foreground, or run: $(manual_stop_command)"
  fi
}

resolve_runtime_log_file() {
  case "$os" in
    darwin)
      printf '%s\n' "${HOME:-/tmp}/Library/Logs/forgeline/forgeline.log"
      ;;
    linux)
      printf '%s\n' "${HOME:-/tmp}/.local/state/forgeline/forgeline.log"
      ;;
    windows)
      printf '%s\n' "${HOME:-/tmp}/AppData/Local/forgeline/logs/forgeline.log"
      ;;
    *)
      printf '%s\n' '/tmp/forgeline.log'
      ;;
  esac
}

ensure_runtime_log_dir() {
  runtime_log_dir="$(dirname "$runtime_log_file")"
  mkdir -p "$runtime_log_dir" 2>/dev/null || true
}

path_contains_dir() {
  target_dir="$1"
  case ":${PATH:-}:" in
    *":${target_dir}:"*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

print_path_guidance() {
  install_dir_no_slash="${INSTALL_DIR%/}"
  if path_contains_dir "$install_dir_no_slash"; then
    info "PATH note: ${install_dir_no_slash} is already on PATH."
    return
  fi

  info "PATH note: ${install_dir_no_slash} is not currently on PATH."
  if [ "$os" = 'windows' ]; then
    info "Run the binary with its full path, or add ${install_dir_no_slash} to your user PATH."
  else
    info "Run the binary with its full path, or add this line to your shell profile:"
    info "  export PATH=\"${install_dir_no_slash}:\$PATH\""
  fi
}

install_binary() {
  source_file="$1"
  target_file="$2"
  target_dir="$(dirname "$target_file")"
  temp_target="${target_file}.tmp.$$"

  mkdir -p "$target_dir" 2>/dev/null || fail "Cannot create $target_dir. Set INSTALL_DIR to a writable directory."

  if [ -f "$target_file" ] && [ "$(sha256_file "$source_file")" = "$(sha256_file "$target_file")" ]; then
    binary_changed=0
    binary_action='unchanged'
    info "Binary already up to date at ${target_file}"
    return
  fi

  if [ -f "$target_file" ]; then
    binary_action='updated'
  else
    binary_action='installed'
  fi

  cp "$source_file" "$temp_target" 2>/dev/null || fail "Cannot write to $target_file. Set INSTALL_DIR to a writable directory."
  chmod 0755 "$temp_target" || fail "Failed to set executable permissions on $temp_target"
  mv -f "$temp_target" "$target_file" || fail "Failed to replace $target_file"
  binary_changed=1
  info "Binary ${binary_action} at ${target_file}"
}

is_root() {
  [ "$(id -u)" -eq 0 ]
}

resolve_default_install_dir() {
  if is_root; then
    printf '%s\n' "$SYSTEM_INSTALL_DIR"
    return
  fi

  [ -n "${HOME:-}" ] || fail "HOME is not set. Set INSTALL_DIR explicitly."
  printf '%s\n' "${HOME}/.local/bin"
}

require_command curl
require_command uname
require_command awk
require_command mktemp
require_command mkdir
require_command cp
require_command chmod
require_command mv
require_command dirname
require_command id

os="$(detect_os)"
arch="$(detect_arch)"
install_name="$(resolve_install_name)"
artifact_stem="$(resolve_artifact_stem)"
artifact_suffix=''

if [ "$os" = 'windows' ]; then
  artifact_suffix='.exe'
fi

runtime_log_file="$(resolve_runtime_log_file)"

artifact_name="${artifact_stem}_${os}_${arch}${artifact_suffix}"
release_url="${BASE_URL%/}/${PRODUCT}/${VERSION}"
checksums_url="${release_url}/SHA256SUMS"
artifact_url="${release_url}/${artifact_name}"
binary_changed=0
binary_action='unknown'

if [ -z "$INSTALL_DIR" ]; then
  INSTALL_DIR="$(resolve_default_install_dir)"
fi

target_path="${INSTALL_DIR%/}/${install_name}${artifact_suffix}"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT INT TERM

checksums_file="${tmp_dir}/SHA256SUMS"
artifact_file="${tmp_dir}/${artifact_name}"

section "Forgeline Installer"
info "Product: ${PRODUCT}"
info "Version: ${VERSION}"
info "Platform: ${os}/${arch}"
info "Install path: ${target_path}"
info "Resolved artifact: ${artifact_name}"
info "Download source: ${artifact_url}"

download "$checksums_url" "$checksums_file"
download "$artifact_url" "$artifact_file"

if checksums_enabled; then
  verify_checksum "$checksums_file" "$artifact_file" "$artifact_name"
  info "Checksum verified."
else
  info "Checksum verification skipped."
fi

section "Binary"
install_binary "$artifact_file" "$target_path"

section "Summary"
info "Binary status: ${binary_action}"
info "Binary path: ${target_path}"
info "Log file: ${runtime_log_file}"
print_manual_run_instructions
print_path_guidance
info "Help command: ${install_name}${artifact_suffix} --help"
info "Logs: the binary writes to the log file shown above."
