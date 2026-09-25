#!/usr/bin/env bash
# Build the MessengerX Flutter web client for static hosting at the site root.
#
# Vercel Hobby does not provide a Flutter SDK. `install` downloads the pinned
# Linux SDK; `build` compiles with --base-href=/ and only the public Supabase
# URL plus anon/publishable key. It never passes service-role, Google or
# Telegram secrets to dart-define.
set -Eeuo pipefail

FLUTTER_VERSION=3.24.5
FLUTTER_COMMIT=dec2ee5c1f98f8e84a7d5380c05eb8a3d0a81668
SDK_URL="https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz"
SDK_DIR="${FLUTTER_SDK_DIR:-/tmp/messengerx-flutter-sdk}"

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
app_dir=$(cd -- "$script_dir/.." && pwd)
config_js="$script_dir/web_build_config.mjs"

usage() {
  printf '%s\n' \
    'Usage: vercel_build.sh install' \
    '       vercel_build.sh build [--placeholder]' \
    'install downloads Flutter '"$FLUTTER_VERSION"' when it is not already on PATH.' \
    'build compiles apps/mobile_app/build/web at base href /.' \
    'Pass --placeholder only for CI. Vercel builds must use the public Supabase env vars.'
}

need_node() {
  if ! command -v node >/dev/null 2>&1; then
    printf 'node is required to assemble the public dart-defines.\n' >&2
    exit 1
  fi
}

install_download_tools() {
  local missing=()
  command -v curl >/dev/null 2>&1 || missing+=(curl)
  command -v tar >/dev/null 2>&1 || missing+=(tar)
  command -v xz >/dev/null 2>&1 || missing+=(xz)
  command -v git >/dev/null 2>&1 || missing+=(git)
  command -v unzip >/dev/null 2>&1 || missing+=(unzip)
  if (("${#missing[@]} == 0")); then
    return 0
  fi
  printf 'Installing download tools missing from this build image: %s\n' "${missing[*]}"
  if command -v dnf >/dev/null 2>&1; then
    dnf install -y curl xz tar git unzip ca-certificates
  elif command -v microdnf >/dev/null 2>&1; then
    microdnf install -y curl xz tar git unzip ca-certificates
  elif command -v apt-get >/dev/null 2>&1; then
    apt-get update
    apt-get install -y curl xz-utils tar git unzip ca-certificates
  else
    printf 'Cannot install %s. Vercel'\''s Amazon Linux image should provide dnf.\n' "${missing[*]}" >&2
    exit 1
  fi
}

flutter_version_of() {
  local bin=$1
  if [[ -z "$bin" || ! -x "$bin" ]]; then
    return 1
  fi
  "$bin" --version 2>/dev/null | awk 'NR==1 { print $2; exit }'
}

flutter_is_pinned() {
  local bin=$1
  local version
  version=$(flutter_version_of "$bin" || true)
  [[ "$version" == "$FLUTTER_VERSION" ]]
}

verify_sdk_commit() {
  local root=$1
  if [[ -d "$root/.git" ]]; then
    local commit
    commit=$(git -C "$root" rev-parse HEAD)
    if [[ "$commit" != "$FLUTTER_COMMIT" ]]; then
      printf 'Flutter SDK commit %s does not match pinned %s\n' "$commit" "$FLUTTER_COMMIT" >&2
      exit 1
    fi
    return 0
  fi
  if ! "$root/bin/flutter" --version 2>/dev/null | grep -q 'revision dec2ee5c1f'; then
    printf 'Flutter SDK did not report pinned revision dec2ee5c1f (%s)\n' "$FLUTTER_COMMIT" >&2
    exit 1
  fi
}

download_tarball() {
  local tarball=$1
  curl --fail --location --retry 5 --retry-delay 2 --output "$tarball" "$SDK_URL" || return 1
  # Reject an HTML error page before extraction. Returning, not exiting, lets
  # the caller fall back to the pinned GitHub tag.
  tar -tJf "$tarball" >/dev/null || return 1
}

install_sdk() {
  install_download_tools
  mkdir -p "$SDK_DIR"
  rm -rf "$SDK_DIR/flutter"
  local tarball
  tarball=$(mktemp)
  printf 'Vercel does not include Flutter. Downloading SDK %s\n' "$FLUTTER_VERSION"
  if download_tarball "$tarball"; then
    tar -xJf "$tarball" -C "$SDK_DIR"
    rm -f "$tarball"
  else
    rm -f "$tarball"
    printf 'Official tarball failed. Cloning pinned tag %s from GitHub.\n' "$FLUTTER_VERSION"
    git clone --depth 1 --branch "$FLUTTER_VERSION" https://github.com/flutter/flutter.git "$SDK_DIR/flutter"
  fi
  git config --global --add safe.directory "$SDK_DIR/flutter" || true
  verify_sdk_commit "$SDK_DIR/flutter"
  export PATH="$SDK_DIR/flutter/bin:$PATH"
}

ensure_flutter() {
  if command -v flutter >/dev/null 2>&1 && flutter_is_pinned "$(command -v flutter)"; then
    return 0
  fi
  if [[ -x "$SDK_DIR/flutter/bin/flutter" ]] && flutter_is_pinned "$SDK_DIR/flutter/bin/flutter"; then
    export PATH="$SDK_DIR/flutter/bin:$PATH"
    return 0
  fi
  install_sdk
  if ! flutter_is_pinned "$SDK_DIR/flutter/bin/flutter"; then
    printf 'Installed Flutter is not %s\n' "$FLUTTER_VERSION" >&2
    exit 1
  fi
  export PATH="$SDK_DIR/flutter/bin:$PATH"
}

prepare_flutter() {
  ensure_flutter
  export FLUTTER_SUPPRESS_ANALYTICS=true
  export PUB_CACHE="${PUB_CACHE:-$HOME/.pub-cache}"
  flutter config --no-analytics --enable-web >/dev/null
  flutter precache --web
}

cmd_install() {
  prepare_flutter
  flutter --version
}

cmd_build() {
  local placeholder=false
  if [[ "${1:-}" == "--placeholder" ]]; then
    placeholder=true
  elif [[ -n "${1:-}" ]]; then
    usage >&2
    exit 2
  fi
  need_node
  prepare_flutter
  # Global so the EXIT trap can still see it after this function returns.
  # A local would be unset by then, and `set -u` would fail the build after
  # Flutter had already succeeded.
  MX_DEFINES=$(mktemp)
  chmod 600 "$MX_DEFINES"
  trap 'rm -f "${MX_DEFINES:-}"' EXIT
  local node_args=( "$config_js" write-defines --out "$MX_DEFINES" )
  if [[ "$placeholder" == true ]]; then
    node_args+=(--placeholder)
  fi
  node "${node_args[@]}"
  chmod 600 "$MX_DEFINES"
  (
    cd -- "$app_dir"
    flutter build web --release \
      --base-href=/ \
      --pwa-strategy=offline-first \
      --dart-define-from-file="$MX_DEFINES"
  )
  node "$config_js" verify-output --dir "$app_dir/build/web"
  printf 'Flutter web release is at %s (base href /, service worker present).\n' "$app_dir/build/web"
  if [[ "$placeholder" == false ]]; then
    printf 'OAuth return is the site root. Supabase redirect URLs and the Google JavaScript origin must match it. This script does not change Supabase and does not start a Telegram worker.\n'
  fi
}

main() {
  local command=${1:-}
  if [[ -z "$command" ]]; then
    usage >&2
    exit 2
  fi
  shift
  case "$command" in
    install) cmd_install "$@" ;;
    build) cmd_build "$@" ;;
    -h|--help) usage ;;
    *) usage >&2; exit 2 ;;
  esac
}

main "$@"
