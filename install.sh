#!/usr/bin/env bash

set -euo pipefail

PRODUCT="${PRODUCT:-forgeline}"
VERSION="${VERSION:-latest}"
INSTALL_DIR="${INSTALL_DIR:-}"
VERIFY_CHECKSUMS="${VERIFY_CHECKSUMS:-1}"
REPO_OWNER="${REPO_OWNER:-zoncaesaradmin}"
REPO_NAME="${REPO_NAME:-forgeline-release}"
REPO_REF="${REPO_REF:-main}"
BASE_URL="${BASE_URL:-https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${REPO_REF}/release}"
README_URL="${README_URL:-https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${REPO_REF}/README.md}"
FORGELINE_ROOT="${FORGELINE_ROOT:-}"
FORGELINE_BRIDGE_ROOT="${FORGELINE_BRIDGE_ROOT:-}"
CATALOG_FILE_NAME="${CATALOG_FILE_NAME:-forgeline-catalog.default.yaml}"
OVERRIDE_CATALOG_FILE_NAME="${OVERRIDE_CATALOG_FILE_NAME:-forgeline-catalog.override.yaml}"

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

checksums_enabled() {
  bool_true "$VERIFY_CHECKSUMS"
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

configure_product() {
  case "$PRODUCT" in
    forgeline)
      install_name='forgeline'
      artifact_stem='forgeline'
      installer_title='Forgeline Installer'
      workspace_root_name='FORGELINE_ROOT'
      workspace_root="${FORGELINE_ROOT}"
      workspace_root_example='/mnt/large-disk/forgeline'
      readme_file_name='forgeline-README.md'
      catalog_consumer_name='Forgeline'
      ;;
    forgeline-bridge)
      install_name='forgeline-bridge'
      artifact_stem='forgeline-bridge'
      installer_title='ForgeLine Bridge Installer'
      workspace_root_name='FORGELINE_BRIDGE_ROOT'
      workspace_root="${FORGELINE_BRIDGE_ROOT}"
      workspace_root_example='$HOME/forgeline-bridge-workspace'
      readme_file_name='forgeline-bridge-README.md'
      catalog_consumer_name='ForgeLine Bridge'
      ;;
    *)
      fail "Unsupported PRODUCT '$PRODUCT'. Supported values: forgeline, forgeline-bridge."
      ;;
  esac
}

download() {
  local url="$1"
  local destination="$2"
  if is_github_contents_api_url "$url"; then
    curl -fsSL \
      -H 'Accept: application/vnd.github.raw' \
      -H 'X-GitHub-Api-Version: 2022-11-28' \
      "$url" -o "$destination" || fail "Download failed: $url"
    return
  fi

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
  local file_path="$1"
  od -An -t x1 -N 4 "$file_path" | tr -d ' \n'
}

validate_downloaded_artifact() {
  local file_path="$1"
  local magic
  magic="$(artifact_magic "$file_path")"

  case "$os" in
    darwin)
      case "$magic" in
        cffaedfe | cefaedfe | feedfacf | feedface)
          return 0
          ;;
      esac
      ;;
    linux)
      case "$magic" in
        7f454c46)
          return 0
          ;;
      esac
      ;;
    windows)
      case "$magic" in
        4d5a*)
          return 0
          ;;
      esac
      ;;
  esac

  fail "Downloaded artifact ${artifact_name} does not look like a valid ${os}/${arch} executable. Refusing to install it."
}

verify_checksum() {
  local checksums_file="$1"
  local artifact_file="$2"
  local artifact_name="$3"
  local expected_sum
  local actual_sum

  expected_sum="$(awk -v name="$artifact_name" '$2 == name { print $1 }' "$checksums_file")"
  [ -n "$expected_sum" ] || fail "No checksum entry found for $artifact_name"
  actual_sum="$(sha256_file "$artifact_file")"

  [ "$expected_sum" = "$actual_sum" ] || fail "Checksum verification failed for $artifact_name"
}

checksum_entry_exists() {
  local checksums_file="$1"
  local artifact_name="$2"

  awk -v name="$artifact_name" '
    $2 == name {
      found = 1
      exit
    }
    END {
      exit(found ? 0 : 1)
    }
  ' "$checksums_file"
}

is_github_contents_api_url() {
  case "$1" in
    https://api.github.com/repos/*/contents/*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

manual_start_command() {
  case "$PRODUCT" in
    forgeline)
      case "$os" in
        windows)
          printf '"%s"\n' "$target_path"
          ;;
        *)
          printf '"%s" &\n' "$target_path"
          ;;
      esac
      ;;
    forgeline-bridge)
      case "$os" in
        windows)
          printf '"%s" --workspace-root "%s"\n' "$target_path" "$workspace_root"
          ;;
        *)
          printf '"%s" --workspace-root "%s" &\n' "$target_path" "$workspace_root"
          ;;
      esac
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

ensure_runtime_support_dirs() {
  case "$PRODUCT" in
    forgeline)
      mkdir -p "$(dirname "$runtime_backend_log_file")" 2>/dev/null || true
      mkdir -p "$(dirname "$runtime_mcp_log_file")" 2>/dev/null || true
      ;;
    forgeline-bridge)
      mkdir -p "$(dirname "$bridge_log_file")" 2>/dev/null || true
      ;;
  esac
}

print_manual_run_instructions() {
  ensure_runtime_support_dirs
  info ""
  info "Start manually:"
  info "  $(manual_start_command)"
  info ""
  info "Stop manually:"
  info "  $(manual_stop_command)"
  info ""
}

resolve_runtime_catalog_file() {
  printf '%s\n' "${workspace_root}/.runtime/${CATALOG_FILE_NAME}"
}

resolve_runtime_override_catalog_file() {
  printf '%s\n' "${workspace_root}/.runtime/${OVERRIDE_CATALOG_FILE_NAME}"
}

resolve_runtime_backend_log_file() {
  printf '%s\n' "${workspace_root}/.runtime/logs/forgeline.log"
}

resolve_runtime_mcp_log_file() {
  printf '%s\n' "${workspace_root}/.runtime/logs/forgeline-mcp.log"
}

resolve_bridge_log_file() {
  printf '%s\n' "${workspace_root}/.runtime/logs/forgeline-bridge.log"
}

resolve_bridge_config_file() {
  printf '%s\n' "${workspace_root}/.runtime/forgeline-config.yaml"
}

download_optional() {
  local url="$1"
  local destination="$2"

  if is_github_contents_api_url "$url"; then
    if curl -fsSL \
      -H 'Accept: application/vnd.github.raw' \
      -H 'X-GitHub-Api-Version: 2022-11-28' \
      "$url" -o "$destination"; then
      return 0
    fi

    rm -f "$destination" 2>/dev/null || true
    return 1
  fi

  if curl -fsSL "$url" -o "$destination"; then
    return 0
  fi

  rm -f "$destination" 2>/dev/null || true
  return 1
}

install_binary() {
  local source_file="$1"
  local target_file="$2"
  local target_dir
  local temp_target
  target_dir="$(dirname "$target_file")"
  temp_target="${target_file}.tmp.$$"

  mkdir -p "$target_dir" 2>/dev/null || fail "Cannot create $target_dir. Set INSTALL_DIR to a writable directory."

  if [ -f "$target_file" ] && [ "$(sha256_file "$source_file")" = "$(sha256_file "$target_file")" ]; then
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
  info "Binary ${binary_action} at ${target_file}"
}

install_readme() {
  local readme_target="$1"
  local readme_dir
  local temp_readme
  readme_dir="$(dirname "$readme_target")"
  temp_readme="${readme_target}.tmp.$$"

  mkdir -p "$readme_dir" 2>/dev/null || fail "Cannot create $readme_dir. Set INSTALL_DIR to a writable directory."

  if ! download_optional "$README_URL" "$temp_readme"; then
    rm -f "$temp_readme" 2>/dev/null || true
    warn "Could not download README from ${README_URL}"
    readme_installed=0
    return
  fi

  mv -f "$temp_readme" "$readme_target" || fail "Failed to install README at $readme_target"
  readme_installed=1
}

install_catalog() {
  local source_file="$1"
  local target_file="$2"
  local target_dir
  local temp_target
  target_dir="$(dirname "$target_file")"
  temp_target="${target_file}.tmp.$$"

  if [ ! -f "$source_file" ]; then
    return
  fi

  mkdir -p "$target_dir" 2>/dev/null || fail "Cannot create $target_dir. Ensure ${workspace_root_name} is writable."

  if [ -f "$target_file" ]; then
    if [ "$(sha256_file "$source_file")" = "$(sha256_file "$target_file")" ]; then
      info "Catalog already up to date at ${target_file}"
    else
      info "Catalog already exists at ${target_file}; leaving your current file unchanged."
    fi
    return
  fi

  cp "$source_file" "$temp_target" 2>/dev/null || fail "Cannot write runtime catalog to $target_file"
  chmod 0644 "$temp_target" || fail "Failed to set permissions on $temp_target"
  mv -f "$temp_target" "$target_file" || fail "Failed to install runtime catalog at $target_file"
  info "Catalog installed at ${target_file}"
}

print_root_guidance() {
  info "${workspace_root_name}: ${workspace_root}"
}

print_catalog_guidance() {
  info ""
  info "Catalog usage:"
  info "  Default catalog file is here:"
  info "  ${runtime_catalog_file}"
  info ""
  info "  Place your own override catalog here:"
  info "  ${runtime_override_catalog_file}"
  info ""
  info "  Or point ${catalog_consumer_name} at a custom catalog file:"
  info "  export FORGELINE_CATALOG_FILE=/path/to/forgeline-catalog.yaml"
}

require_workspace_root() {
  [ -n "$workspace_root" ] || fail "${workspace_root_name} must be set before install. Example: export ${workspace_root_name}=${workspace_root_example}"
}

ensure_workspace_root_dir() {
  if mkdir -p "$workspace_root" 2>/dev/null; then
    return
  fi

  parent_dir="$(dirname "$workspace_root")"
  fail "Cannot create ${workspace_root_name} at $workspace_root. Create the directory first and ensure your user can write to it, for example: sudo mkdir -p \"$workspace_root\" && sudo chown -R \"\$(id -un)\":\"\$(id -gn)\" \"$workspace_root\". Parent path: $parent_dir"
}

resolve_default_install_dir() {
  printf '%s\n' "${workspace_root}/.install/bin"
}

print_product_summary() {
  case "$PRODUCT" in
    forgeline)
      info "Backend log file: ${runtime_backend_log_file}"
      info "MCP log file: ${runtime_mcp_log_file}"
      print_root_guidance
      ;;
    forgeline-bridge)
      info "Bridge config path: ${bridge_config_file}"
      info "Bridge log file: ${bridge_log_file}"
      print_root_guidance
      ;;
  esac
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
require_command rm
require_command od
require_command tr

configure_product

os="$(detect_os)"
arch="$(detect_arch)"
artifact_suffix=''

require_workspace_root
ensure_workspace_root_dir

if [ "$os" = 'windows' ]; then
  artifact_suffix='.exe'
fi

runtime_catalog_file="$(resolve_runtime_catalog_file)"
runtime_override_catalog_file="$(resolve_runtime_override_catalog_file)"

case "$PRODUCT" in
  forgeline)
    runtime_backend_log_file="$(resolve_runtime_backend_log_file)"
    runtime_mcp_log_file="$(resolve_runtime_mcp_log_file)"
    ;;
  forgeline-bridge)
    bridge_log_file="$(resolve_bridge_log_file)"
    bridge_config_file="$(resolve_bridge_config_file)"
    ;;
esac

artifact_name="${artifact_stem}_${os}_${arch}${artifact_suffix}"
release_url="${BASE_URL%/}/${PRODUCT}/${VERSION}"
checksums_url="${release_url}/SHA256SUMS"
artifact_url="${release_url}/${artifact_name}"
catalog_url="${release_url}/${CATALOG_FILE_NAME}"
binary_action='unknown'

if [ -z "$INSTALL_DIR" ]; then
  INSTALL_DIR="$(resolve_default_install_dir)"
fi

target_path="${INSTALL_DIR%/}/${install_name}${artifact_suffix}"
readme_path="${INSTALL_DIR%/}/${readme_file_name}"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT INT TERM

checksums_file="${tmp_dir}/SHA256SUMS"
artifact_file="${tmp_dir}/${artifact_name}"
catalog_file="${tmp_dir}/${CATALOG_FILE_NAME}"
readme_installed=0

section "$installer_title"
info "Install path: ${target_path}"

download "$checksums_url" "$checksums_file"
download "$artifact_url" "$artifact_file"
validate_downloaded_artifact "$artifact_file"

if checksums_enabled; then
  verify_checksum "$checksums_file" "$artifact_file" "$artifact_name"
  info "Checksum verified."
else
  info "Checksum verification skipped."
fi

if download_optional "$catalog_url" "$catalog_file"; then
  if checksums_enabled && checksum_entry_exists "$checksums_file" "$CATALOG_FILE_NAME"; then
    verify_checksum "$checksums_file" "$catalog_file" "$CATALOG_FILE_NAME"
  elif checksums_enabled; then
    warn "No checksum entry found for ${CATALOG_FILE_NAME}; skipping catalog checksum verification."
  fi
else
  warn "Could not download ${CATALOG_FILE_NAME} from ${catalog_url}. ${catalog_consumer_name} now requires a runtime catalog file, so add one at ${runtime_catalog_file} or set FORGELINE_CATALOG_FILE before starting."
fi

section "Binary"
install_binary "$artifact_file" "$target_path"
install_readme "$readme_path"
install_catalog "$catalog_file" "$runtime_catalog_file"

section "Summary"
info "Binary path: ${target_path}"
info "Default catalog file: ${runtime_catalog_file}"
info "Override catalog file: ${runtime_override_catalog_file}"
print_product_summary
if [ "$readme_installed" -eq 1 ]; then
  info "README path: ${readme_path}"
fi
print_catalog_guidance
print_manual_run_instructions
