#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
REPO_URL="${REPO_URL:-git@github.com:zoncaesaradmin/forgeline.git}"
SOURCE_REF="${SOURCE_REF:-main}"
WORK_ROOT="${WORK_ROOT:-${ROOT_DIR}/.build}"
SOURCE_DIR="${SOURCE_DIR:-${WORK_ROOT}/forgeline}"
BUILD_SUBDIR="${BUILD_SUBDIR:-}"
BUILD_DIR="${BUILD_DIR:-}"
TARGET_DIR="${TARGET_DIR:-${ROOT_DIR}/release/forgeline/latest}"
BRIDGE_BUILD_DIR="${BRIDGE_BUILD_DIR:-${SOURCE_DIR}/bridge}"
BRIDGE_TARGET_DIR="${BRIDGE_TARGET_DIR:-${ROOT_DIR}/release/forgeline-bridge/latest}"
BRIDGE_RELEASE_DIR="${BRIDGE_RELEASE_DIR:-${WORK_ROOT}/bridge-release}"
DEVCHECK_BUILD_DIR="${DEVCHECK_BUILD_DIR:-${SOURCE_DIR}/e2etests}"
DEVCHECK_TARGET_DIR="${DEVCHECK_TARGET_DIR:-${ROOT_DIR}/release/forgeline-devcheck/latest}"
DEVCHECK_RELEASE_DIR="${DEVCHECK_RELEASE_DIR:-${WORK_ROOT}/devcheck-release}"
DEVCHECKLOGS_TARGET_DIR="${DEVCHECKLOGS_TARGET_DIR:-${ROOT_DIR}/release/forgeline-devchecklogs/latest}"
DEVCHECKLOGS_RELEASE_DIR="${DEVCHECKLOGS_RELEASE_DIR:-${WORK_ROOT}/devchecklogs-release}"
RELEASE_TARGETS="${RELEASE_TARGETS:-linux/amd64 linux/arm64 darwin/amd64 darwin/arm64 windows/amd64 windows/arm64}"
RUNTIME_CATALOG_SOURCE="${RUNTIME_CATALOG_SOURCE:-${SOURCE_DIR}/conf/runtime/forgeline-catalog.default.yaml}"
RUNTIME_CATALOG_FILE_NAME="${RUNTIME_CATALOG_FILE_NAME:-forgeline-catalog.default.yaml}"

ARTIFACTS='
forgeline_darwin_amd64
forgeline_darwin_arm64
forgeline_linux_amd64
forgeline_linux_arm64
forgeline_windows_amd64.exe
forgeline_windows_arm64.exe
'

BRIDGE_ARTIFACTS='
forgeline-bridge_darwin_amd64
forgeline-bridge_darwin_arm64
forgeline-bridge_linux_amd64
forgeline-bridge_linux_arm64
forgeline-bridge_windows_amd64.exe
forgeline-bridge_windows_arm64.exe
'

DEVCHECK_ARTIFACTS='
forgeline-devcheck_darwin_amd64
forgeline-devcheck_darwin_arm64
forgeline-devcheck_linux_amd64
forgeline-devcheck_linux_arm64
forgeline-devcheck_windows_amd64.exe
forgeline-devcheck_windows_arm64.exe
'

DEVCHECKLOGS_ARTIFACTS='
forgeline-devchecklogs_darwin_amd64
forgeline-devchecklogs_darwin_arm64
forgeline-devchecklogs_linux_amd64
forgeline-devchecklogs_linux_arm64
forgeline-devchecklogs_windows_amd64.exe
forgeline-devchecklogs_windows_arm64.exe
'

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

cleanup_legacy_build_state() {
  legacy_bridge_release_dir="${WORK_ROOT}/forgelinebridge-release"
  if [ -d "$legacy_bridge_release_dir" ]; then
    rm -rf "$legacy_bridge_release_dir"
  fi
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

makefile_supports_release() {
  makefile_path="$1"
  [ -f "$makefile_path" ] || return 1
  grep -q '^release:' "$makefile_path" || return 1
  grep -q 'forgeline_' "$makefile_path" || return 1
}

sha256_line() {
  file_path="$1"
  file_name="$(basename "$file_path")"

  if command -v sha256sum >/dev/null 2>&1; then
    sum="$(sha256sum "$file_path" | awk '{print $1}')"
  elif command -v shasum >/dev/null 2>&1; then
    sum="$(shasum -a 256 "$file_path" | awk '{print $1}')"
  elif command -v openssl >/dev/null 2>&1; then
    sum="$(openssl dgst -sha256 "$file_path" | awk '{print $NF}')"
  else
    fail "No SHA-256 tool available. Install sha256sum, shasum, or openssl."
  fi

  printf '%s  %s\n' "$sum" "$file_name"
}

clone_source_repo() {
  repo_url="$1"
  [ -n "$repo_url" ] || fail "Repository URL is empty"

  rm -rf "$SOURCE_DIR"
  mkdir -p "$WORK_ROOT"
  git clone "$repo_url" "$SOURCE_DIR" || fail "Failed to clone source repo from ${repo_url}. If this is a private repo, configure SSH access for git@github.com or override REPO_URL with an authenticated clone URL."
}

prepare_source_repo() {
  section "Source"
  info "Cloning fresh source repo from ${REPO_URL}"
  clone_source_repo "$REPO_URL"

  git -C "$SOURCE_DIR" checkout "$SOURCE_REF"
}

run_release_build() {
  section "Build"
  resolve_build_dir
  [ -d "$BUILD_DIR" ] || fail "Build directory not found: ${BUILD_DIR}"
  info "Running make release in ${BUILD_DIR}"
  make -C "$BUILD_DIR" release
}

run_bridge_release_build() {
  section "Build Bridge"
  [ -d "$BRIDGE_BUILD_DIR" ] || fail "Bridge build directory not found: ${BRIDGE_BUILD_DIR}"
  rm -rf "$BRIDGE_RELEASE_DIR"
  mkdir -p "$BRIDGE_RELEASE_DIR"
  info "Cross-compiling forgeline-bridge from ${BRIDGE_BUILD_DIR}"

  for target in $RELEASE_TARGETS; do
    os_name="${target%/*}"
    arch_name="${target#*/}"
    artifact_ext=''
    if [ "$os_name" = 'windows' ]; then
      artifact_ext='.exe'
    fi
    artifact_path="${BRIDGE_RELEASE_DIR}/forgeline-bridge_${os_name}_${arch_name}${artifact_ext}"
    info "Building $(basename "$artifact_path")"
    (
      cd "$BRIDGE_BUILD_DIR"
      CGO_ENABLED=0 GOOS="$os_name" GOARCH="$arch_name" GOCACHE="${WORK_ROOT}/go-build-cache-bridge" go build -o "$artifact_path" ./cmd/forgeline-bridge
    )
  done
}

run_devcheck_release_build() {
  section "Build Dev Tools"
  [ -d "$DEVCHECK_BUILD_DIR" ] || fail "Dev tools build directory not found: ${DEVCHECK_BUILD_DIR}"
  rm -rf "$DEVCHECK_RELEASE_DIR" "$DEVCHECKLOGS_RELEASE_DIR"
  mkdir -p "$DEVCHECK_RELEASE_DIR" "$DEVCHECKLOGS_RELEASE_DIR"
  info "Cross-compiling forgeline-devcheck and forgeline-devchecklogs from ${DEVCHECK_BUILD_DIR}"

  for target in $RELEASE_TARGETS; do
    os_name="${target%/*}"
    arch_name="${target#*/}"
    artifact_ext=''
    if [ "$os_name" = 'windows' ]; then
      artifact_ext='.exe'
    fi
    devcheck_artifact_path="${DEVCHECK_RELEASE_DIR}/forgeline-devcheck_${os_name}_${arch_name}${artifact_ext}"
    devchecklogs_artifact_path="${DEVCHECKLOGS_RELEASE_DIR}/forgeline-devchecklogs_${os_name}_${arch_name}${artifact_ext}"
    info "Building $(basename "$devcheck_artifact_path")"
    (
      cd "$DEVCHECK_BUILD_DIR"
      CGO_ENABLED=0 GOOS="$os_name" GOARCH="$arch_name" GOCACHE="${WORK_ROOT}/go-build-cache-devcheck" go build -o "$devcheck_artifact_path" ./bridge/integration-test
    )
    info "Building $(basename "$devchecklogs_artifact_path")"
    (
      cd "$DEVCHECK_BUILD_DIR"
      CGO_ENABLED=0 GOOS="$os_name" GOARCH="$arch_name" GOCACHE="${WORK_ROOT}/go-build-cache-devcheck" go build -o "$devchecklogs_artifact_path" ./checklogs
    )
  done
}

resolve_build_dir() {
  if [ -n "$BUILD_DIR" ]; then
    return
  fi

  if [ -n "$BUILD_SUBDIR" ]; then
    BUILD_DIR="${SOURCE_DIR}/${BUILD_SUBDIR}"
    return
  fi

  for candidate_dir in "$SOURCE_DIR/app" "$SOURCE_DIR" "$SOURCE_DIR/server/backend" "$SOURCE_DIR/server" "$SOURCE_DIR/backend"; do
    if makefile_supports_release "${candidate_dir}/Makefile"; then
      BUILD_DIR="$candidate_dir"
      return
    fi
  done

  fail "Could not find a release-capable Makefile under ${SOURCE_DIR}. Set BUILD_DIR or BUILD_SUBDIR explicitly."
}

find_artifact() {
  artifact_name="$1"

  resolve_build_dir
  for base_dir in "$BUILD_DIR/release" "$BUILD_DIR/dist" "$BUILD_DIR/build" "$BUILD_DIR/bin" "$BUILD_DIR/out" "$SOURCE_DIR/release" "$SOURCE_DIR/dist" "$SOURCE_DIR/build" "$SOURCE_DIR/bin" "$SOURCE_DIR/out"; do
    if [ -d "$base_dir" ]; then
      found_path="$(find "$base_dir" -type f -name "$artifact_name" ! -path '*/.git/*' | head -n 1 || true)"
      if [ -n "$found_path" ]; then
        printf '%s\n' "$found_path"
        return
      fi
    fi
  done

  found_path="$(find "$SOURCE_DIR" -type f -name "$artifact_name" ! -path '*/.git/*' | head -n 1 || true)"
  [ -n "$found_path" ] || fail "Could not find built artifact: ${artifact_name}"
  printf '%s\n' "$found_path"
}

copy_release_artifacts() {
  section "Publish"
  mkdir -p "$TARGET_DIR"

  for artifact_name in $ARTIFACTS; do
    source_path="$(find_artifact "$artifact_name")"
    cp "$source_path" "${TARGET_DIR}/${artifact_name}"
    chmod 0755 "${TARGET_DIR}/${artifact_name}" || true
    info "Copied ${artifact_name}"
  done
}

bridge_artifact_path() {
  artifact_name="$1"
  artifact_path="${BRIDGE_RELEASE_DIR}/${artifact_name}"
  [ -f "$artifact_path" ] || fail "Could not find built bridge artifact: ${artifact_name}"
  printf '%s\n' "$artifact_path"
}

copy_bridge_release_artifacts() {
  section "Publish Bridge"
  mkdir -p "$BRIDGE_TARGET_DIR"

  for artifact_name in $BRIDGE_ARTIFACTS; do
    source_path="$(bridge_artifact_path "$artifact_name")"
    cp "$source_path" "${BRIDGE_TARGET_DIR}/${artifact_name}"
    chmod 0755 "${BRIDGE_TARGET_DIR}/${artifact_name}" || true
    info "Copied ${artifact_name}"
  done
}

devcheck_artifact_path() {
  artifact_name="$1"
  artifact_path="${DEVCHECK_RELEASE_DIR}/${artifact_name}"
  [ -f "$artifact_path" ] || fail "Could not find built devcheck artifact: ${artifact_name}"
  printf '%s\n' "$artifact_path"
}

copy_devcheck_release_artifacts() {
  section "Publish Dev Tools"
  mkdir -p "$DEVCHECK_TARGET_DIR"

  for artifact_name in $DEVCHECK_ARTIFACTS; do
    source_path="$(devcheck_artifact_path "$artifact_name")"
    cp "$source_path" "${DEVCHECK_TARGET_DIR}/${artifact_name}"
    chmod 0755 "${DEVCHECK_TARGET_DIR}/${artifact_name}" || true
    info "Copied ${artifact_name}"
  done
}

devchecklogs_artifact_path() {
  artifact_name="$1"
  artifact_path="${DEVCHECKLOGS_RELEASE_DIR}/${artifact_name}"
  [ -f "$artifact_path" ] || fail "Could not find built devchecklogs artifact: ${artifact_name}"
  printf '%s\n' "$artifact_path"
}

copy_devchecklogs_release_artifacts() {
  section "Publish Dev Checklogs"
  mkdir -p "$DEVCHECKLOGS_TARGET_DIR"

  for artifact_name in $DEVCHECKLOGS_ARTIFACTS; do
    source_path="$(devchecklogs_artifact_path "$artifact_name")"
    cp "$source_path" "${DEVCHECKLOGS_TARGET_DIR}/${artifact_name}"
    chmod 0755 "${DEVCHECKLOGS_TARGET_DIR}/${artifact_name}" || true
    info "Copied ${artifact_name}"
  done
}

write_checksums() {
  checksums_path="${TARGET_DIR}/SHA256SUMS"
  : > "$checksums_path"

  for artifact_name in $ARTIFACTS; do
    sha256_line "${TARGET_DIR}/${artifact_name}" >> "$checksums_path"
  done
  if [ -f "${TARGET_DIR}/${RUNTIME_CATALOG_FILE_NAME}" ]; then
    sha256_line "${TARGET_DIR}/${RUNTIME_CATALOG_FILE_NAME}" >> "$checksums_path"
  fi

  info "Wrote SHA256SUMS"
}

write_bridge_checksums() {
  checksums_path="${BRIDGE_TARGET_DIR}/SHA256SUMS"
  : > "$checksums_path"

  for artifact_name in $BRIDGE_ARTIFACTS; do
    sha256_line "${BRIDGE_TARGET_DIR}/${artifact_name}" >> "$checksums_path"
  done
  if [ -f "${BRIDGE_TARGET_DIR}/${RUNTIME_CATALOG_FILE_NAME}" ]; then
    sha256_line "${BRIDGE_TARGET_DIR}/${RUNTIME_CATALOG_FILE_NAME}" >> "$checksums_path"
  fi

  info "Wrote bridge SHA256SUMS"
}

write_devcheck_checksums() {
  checksums_path="${DEVCHECK_TARGET_DIR}/SHA256SUMS"
  : > "$checksums_path"

  for artifact_name in $DEVCHECK_ARTIFACTS; do
    sha256_line "${DEVCHECK_TARGET_DIR}/${artifact_name}" >> "$checksums_path"
  done

  info "Wrote devcheck SHA256SUMS"
}

write_devchecklogs_checksums() {
  checksums_path="${DEVCHECKLOGS_TARGET_DIR}/SHA256SUMS"
  : > "$checksums_path"

  for artifact_name in $DEVCHECKLOGS_ARTIFACTS; do
    sha256_line "${DEVCHECKLOGS_TARGET_DIR}/${artifact_name}" >> "$checksums_path"
  done

  info "Wrote devchecklogs SHA256SUMS"
}

write_runtime_catalog_artifact() {
  target_dir="$1"
  target_file="${target_dir}/${RUNTIME_CATALOG_FILE_NAME}"
  temp_file="${target_file}.tmp"

  mkdir -p "$target_dir"
  [ -f "$RUNTIME_CATALOG_SOURCE" ] || fail "Runtime catalog source not found: ${RUNTIME_CATALOG_SOURCE}"
  [ -s "$RUNTIME_CATALOG_SOURCE" ] || fail "Runtime catalog source is empty: ${RUNTIME_CATALOG_SOURCE}"
  cp "$RUNTIME_CATALOG_SOURCE" "$temp_file"
  mv -f "$temp_file" "$target_file"
  [ -s "$target_file" ] || fail "Published runtime catalog is empty: ${target_file}"
  chmod 0644 "$target_file" || true
  info "Published ${RUNTIME_CATALOG_FILE_NAME} to ${target_dir}"
}

publish_runtime_catalogs() {
  section "Publish Catalog"
  write_runtime_catalog_artifact "$TARGET_DIR"
  write_runtime_catalog_artifact "$BRIDGE_TARGET_DIR"
}

require_command git
require_command make
require_command go
require_command find
require_command cp
require_command chmod
require_command mkdir
require_command awk
require_command basename
require_command grep
require_command head

cleanup_legacy_build_state
prepare_source_repo
run_release_build
copy_release_artifacts
run_bridge_release_build
copy_bridge_release_artifacts
run_devcheck_release_build
copy_devcheck_release_artifacts
copy_devchecklogs_release_artifacts
publish_runtime_catalogs
write_checksums
write_bridge_checksums
write_devcheck_checksums
write_devchecklogs_checksums

section "Summary"
info "Source repo: ${SOURCE_DIR}"
info "Source ref: ${SOURCE_REF}"
info "App build dir: ${BUILD_DIR}"
info "App release target: ${TARGET_DIR}"
info "App artifacts copied:"
for artifact_name in $ARTIFACTS; do
  info "  ${TARGET_DIR}/${artifact_name}"
done
info "App checksums: ${TARGET_DIR}/SHA256SUMS"
info "App runtime catalog: ${TARGET_DIR}/${RUNTIME_CATALOG_FILE_NAME}"
info "Bridge build dir: ${BRIDGE_BUILD_DIR}"
info "Bridge release target: ${BRIDGE_TARGET_DIR}"
info "Bridge artifacts copied:"
for artifact_name in $BRIDGE_ARTIFACTS; do
  info "  ${BRIDGE_TARGET_DIR}/${artifact_name}"
done
info "Bridge checksums: ${BRIDGE_TARGET_DIR}/SHA256SUMS"
info "Bridge runtime catalog: ${BRIDGE_TARGET_DIR}/${RUNTIME_CATALOG_FILE_NAME}"
info "Dev tools build dir: ${DEVCHECK_BUILD_DIR}"
info "Dev tools release target: ${DEVCHECK_TARGET_DIR}"
info "Dev tools artifacts copied:"
for artifact_name in $DEVCHECK_ARTIFACTS; do
  info "  ${DEVCHECK_TARGET_DIR}/${artifact_name}"
done
info "Dev tools checksums: ${DEVCHECK_TARGET_DIR}/SHA256SUMS"
info "Dev checklogs release target: ${DEVCHECKLOGS_TARGET_DIR}"
info "Dev checklogs artifacts copied:"
for artifact_name in $DEVCHECKLOGS_ARTIFACTS; do
  info "  ${DEVCHECKLOGS_TARGET_DIR}/${artifact_name}"
done
info "Dev checklogs checksums: ${DEVCHECKLOGS_TARGET_DIR}/SHA256SUMS"
