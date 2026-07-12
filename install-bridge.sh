#!/usr/bin/env bash

set -euo pipefail

PRODUCT='forgeline-bridge'
REPO_OWNER="${REPO_OWNER:-zoncaesaradmin}"
REPO_NAME="${REPO_NAME:-forgeline-release}"
REPO_REF="${REPO_REF:-main}"

fail() {
  printf 'Error: %s\n' "$1" >&2
  exit 1
}

resolve_local_installer() {
  local script_dir

  if [ ! -f "${0:-}" ]; then
    return 1
  fi

  script_dir="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
  [ -f "${script_dir}/install.sh" ] || return 1
  printf '%s\n' "${script_dir}/install.sh"
}

download_installer() {
  local installer_url tmp_dir installer_path

  command -v curl >/dev/null 2>&1 || fail "curl is required to download install.sh"
  command -v mktemp >/dev/null 2>&1 || fail "mktemp is required to download install.sh"

  installer_url="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${REPO_REF}/install.sh"
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' EXIT INT TERM
  installer_path="${tmp_dir}/install.sh"
  curl -fsSL "$installer_url" -o "$installer_path" || fail "Download failed: $installer_url"
  chmod 0755 "$installer_path" || true
  printf '%s\n' "$installer_path"
}

installer_path="$(resolve_local_installer || true)"
if [ -z "$installer_path" ]; then
  installer_path="$(download_installer)"
fi

exec env PRODUCT="$PRODUCT" bash "$installer_path" "$@"
