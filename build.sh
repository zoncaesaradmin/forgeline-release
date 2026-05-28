#!/usr/bin/env bash

set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
LOCAL_REPO_PATH="${LOCAL_REPO_PATH:-${ROOT_DIR}/../forgeline}"
PRIMARY_REPO_URL="${PRIMARY_REPO_URL:-${LOCAL_REPO_PATH}}"
FALLBACK_REPO_URL="${FALLBACK_REPO_URL:-https://github.com/zoncaesaradmin/forgeline.git}"
SOURCE_REF="${SOURCE_REF:-main}"
WORK_ROOT="${WORK_ROOT:-${ROOT_DIR}/.build}"
SOURCE_DIR="${SOURCE_DIR:-${WORK_ROOT}/forgeline}"
BUILD_SUBDIR="${BUILD_SUBDIR:-}"
BUILD_DIR="${BUILD_DIR:-}"
TARGET_DIR="${TARGET_DIR:-${ROOT_DIR}/release/forgeline/latest}"

ARTIFACTS='
forgeline_darwin_amd64
forgeline_darwin_arm64
forgeline_linux_amd64
forgeline_linux_arm64
forgeline_windows_amd64.exe
forgeline_windows_arm64.exe
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
  git clone "$repo_url" "$SOURCE_DIR"
}

prepare_source_repo() {
  if [ -d "$SOURCE_DIR/.git" ]; then
    section "Source"
    info "Updating existing source checkout at ${SOURCE_DIR}"
    git -C "$SOURCE_DIR" fetch --all --tags
    git -C "$SOURCE_DIR" checkout "$SOURCE_REF"
    git -C "$SOURCE_DIR" pull --ff-only origin "$SOURCE_REF"
    return
  fi

  section "Source"
  info "Cloning source repo from ${PRIMARY_REPO_URL}"
  if ! clone_source_repo "$PRIMARY_REPO_URL"; then
    if [ "$FALLBACK_REPO_URL" = "$PRIMARY_REPO_URL" ]; then
      fail "Failed to clone source repo from ${PRIMARY_REPO_URL}"
    fi
    info "Primary clone failed. Retrying with fallback repo URL: ${FALLBACK_REPO_URL}"
    clone_source_repo "$FALLBACK_REPO_URL"
  fi

  git -C "$SOURCE_DIR" checkout "$SOURCE_REF"
}

run_release_build() {
  section "Build"
  resolve_build_dir
  [ -d "$BUILD_DIR" ] || fail "Build directory not found: ${BUILD_DIR}"
  info "Running make release in ${BUILD_DIR}"
  make -C "$BUILD_DIR" release
}

resolve_build_dir() {
  if [ -n "$BUILD_DIR" ]; then
    return
  fi

  if [ -n "$BUILD_SUBDIR" ]; then
    BUILD_DIR="${SOURCE_DIR}/${BUILD_SUBDIR}"
    return
  fi

  for candidate_dir in "$SOURCE_DIR" "$SOURCE_DIR/backend" "$SOURCE_DIR/server"; do
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

write_checksums() {
  checksums_path="${TARGET_DIR}/SHA256SUMS"
  : > "$checksums_path"

  for artifact_name in $ARTIFACTS; do
    sha256_line "${TARGET_DIR}/${artifact_name}" >> "$checksums_path"
  done

  info "Wrote SHA256SUMS"
}

require_command git
require_command make
require_command find
require_command cp
require_command chmod
require_command mkdir
require_command awk
require_command basename
require_command grep
require_command head

prepare_source_repo
run_release_build
copy_release_artifacts
write_checksums

section "Summary"
info "Source repo: ${SOURCE_DIR}"
info "Source ref: ${SOURCE_REF}"
info "Build dir: ${BUILD_DIR}"
info "Release target: ${TARGET_DIR}"
info "Artifacts copied:"
for artifact_name in $ARTIFACTS; do
  info "  ${TARGET_DIR}/${artifact_name}"
done
info "Checksums: ${TARGET_DIR}/SHA256SUMS"
