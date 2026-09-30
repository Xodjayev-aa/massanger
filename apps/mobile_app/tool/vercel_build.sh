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
  if (( "${#missing[@]} == 0" )); then
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
  # precache can fail transiently on storage.googleapis.com — retry a few times
  # so a blip does not turn a Production deploy red.
  local attempt=0
  until flutter precache --web; do
    attempt=$((attempt+1))
    if (( attempt >= 3 )); then
      printf 'flutter precache --web failed after %d attempts\n' "$attempt" >&2
      exit 1
    fi
    printf 'flutter precache failed, retry %d/3 in 5s...\n' "$attempt"
    sleep 5
  done
}

log_vercel_env_presence() {
  if [[ "${VERCEL:-}" != "1" ]]; then
    return 0
  fi
  printf 'Vercel build env: VERCEL_ENV=%s VERCEL_PROJECT_PRODUCTION_URL=%s\n' \
    "${VERCEL_ENV:-unset}" "${VERCEL_PROJECT_PRODUCTION_URL:-unset}"
  printf 'Env presence (values redacted):\n'
  for name in SUPABASE_URL SUPABASE_ANON_KEY SUPABASE_PUBLISHABLE_KEY WEB_REDIRECT_URL PUBLIC_SITE_URL MESSENGERX_ACCEPT_SITE_HOST TELEGRAM_OIDC_ENABLED; do
    if [[ -n "${!name:-}" ]]; then
      printf '  %s=SET\n' "$name"
    else
      printf '  %s=UNSET\n' "$name"
    fi
  done
  local forbidden_set=()
  for name in SUPABASE_SERVICE_ROLE_KEY SUPABASE_SECRET_KEY SUPABASE_JWT_SECRET SUPABASE_DB_PASSWORD GOOGLE_OAUTH_CLIENT_SECRET GOOGLE_CLIENT_SECRET TELEGRAM_API_HASH TELEGRAM_BOT_TOKEN TELEGRAM_BOT_SECRET BOT_TOKEN SEAL_KEY LINK_PAYLOAD_KEY BRIDGE_TOKEN BRIDGE_HMAC_SECRET TDLIB_DB_KEY; do
    if [[ -n "${!name:-}" ]]; then
      forbidden_set+=("$name")
    fi
  done
  if (( ${#forbidden_set[@]} > 0 )); then
    printf 'FORBIDDEN env vars present (must be removed from Vercel Production): %s\n' "${forbidden_set[*]}"
  else
    printf 'No forbidden secret env vars detected.\n'
  fi
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

  # Fail fast on Vercel if public env is missing, BEFORE downloading Flutter.
  # This makes Production vs Preview mis-scoping obvious in <2 min instead of
  # after a 15-min SDK download. The full check still runs after Flutter is ready.
  if [[ "$placeholder" == false ]]; then
    log_vercel_env_presence
    printf 'Running fast pre-check of public env (before Flutter download)...\n'
    if ! node "$config_js" write-defines --out /dev/null; then
      printf '\n=== Vercel Production Build Failed Early ===\n' >&2
      printf 'The public env check above failed.\n' >&2
      printf 'Common causes for Production red errors while Preview is green:\n' >&2
      printf '  1. SUPABASE_URL / SUPABASE_ANON_KEY set only for Preview, not Production.\n' >&2
      printf '     Vercel -> Settings -> Environment Variables -> enable for Production.\n' >&2
      printf '  2. A secret like SUPABASE_SERVICE_ROLE_KEY is set for Production.\n' >&2
      printf '     Remove all forbidden secrets from Vercel; only public anon key belongs in web.\n' >&2
      printf '  3. VERCEL_PROJECT_PRODUCTION_URL is not officialmessengerx.vercel.app\n' >&2
      printf '     and MESSENGERX_ACCEPT_SITE_HOST was not set to that exact host.\n' >&2
      printf 'See docs/vercel.md §1-2 for the exact variable list.\n' >&2
      printf 'If you see a green Preview deploy but red Production, open that Preview URL in Incognito to verify new UI is there.\n' >&2
      exit 1
    fi
    printf 'Fast pre-check passed. Proceeding to Flutter SDK...\n'
  fi

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
  # Write a version.json for cache-busting and debugging Production vs Preview.
  # This file is explicitly set to no-cache in vercel.json, so browsers always
  # fetch the latest build id. Useful to verify that Production actually updated.
  local build_id
  build_id=$(git -C "$app_dir/../.." rev-parse --short HEAD 2>/dev/null || echo "unknown")
  local built_at
  built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  printf '{"version":"%s","builtAt":"%s","flutter":"%s","host":"%s"}\n' \
    "$build_id" "$built_at" "$FLUTTER_VERSION" "${VERCEL_PROJECT_PRODUCTION_URL:-local}" \
    > "$app_dir/build/web/version.json"
  printf 'Wrote version.json: %s @ %s\n' "$build_id" "$built_at"
  printf 'Flutter web release is at %s (base href /, service worker present).\n' "$app_dir/build/web"
  if [[ "$placeholder" == false ]]; then
    printf 'OAuth return is the site root. Supabase redirect URLs and the Google JavaScript origin must match it. This script does not change Supabase and does not start a Telegram worker.\n'
    printf 'If this was a Production deploy, Vercel will now serve this build at https://officialmessengerx.vercel.app/\n'
    printf 'PWA cache note: Flutter installs flutter_service_worker.js that caches old UI. After deploy, hard reload (Ctrl+Shift+R) and clear site data for the domain to see new UI.\n'
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
