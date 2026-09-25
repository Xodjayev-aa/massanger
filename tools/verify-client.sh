#!/usr/bin/env bash
# Run on a Mac/Linux workstation with the Flutter SDK installed. Read-only by
# default: --fix is an explicit opt-in because dart fix/format modify source.
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage: bash tools/verify-client.sh [--fix] [--log-dir DIR]

From any directory: run flutter pub get, flutter analyze (strict), then
flutter test and a release Flutter web build with placeholder (non-live) config.
--fix additionally runs dart fix --apply and dart format lib test between
pub get and analysis. Review the resulting git diff before committing.
Logs are kept in .messengerx/verify-client/ (gitignored, private) by default.
EOF
}

fix=false
log_dir=''
while (($#)); do
  case "$1" in
    --fix) fix=true; shift ;;
    --log-dir)
      if (($# < 2)) || [[ -z "$2" ]]; then
        printf 'Missing directory after --log-dir\n' >&2
        exit 2
      fi
      log_dir=$2
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

root=$(cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
app_dir="$root/apps/mobile_app"
if [[ ! -f "$app_dir/pubspec.yaml" ]]; then
  printf 'Flutter app not found at %s\n' "$app_dir" >&2
  exit 1
fi
if ! command -v flutter >/dev/null 2>&1; then
  printf 'Flutter SDK is not on PATH. Install Flutter >=3.24 and rerun on the target machine.\n' >&2
  exit 127
fi
if ! command -v node >/dev/null 2>&1; then
  printf 'Node.js is not on PATH. The web build script needs it to assemble public dart-defines.\n' >&2
  exit 127
fi
if [[ "$fix" == true ]] && ! command -v dart >/dev/null 2>&1; then
  printf 'The Dart SDK is not on PATH (required for --fix). Add Flutter/bin to PATH.\n' >&2
  exit 127
fi

umask 077
if [[ -z "$log_dir" ]]; then
  log_dir="$root/.messengerx/verify-client/$(date -u +%Y%m%dT%H%M%SZ)-$$"
elif [[ "$log_dir" != /* ]]; then
  log_dir="$PWD/$log_dir"
fi
mkdir -p "$log_dir"
chmod 700 "$log_dir"
cd -- "$app_dir"
printf 'Flutter client verification: %s\nLogs: %s\n' "$app_dir" "$log_dir"

run_step() {
  local name=$1
  shift
  printf '\n==> %s\n' "$name"
  # pipefail makes a failed flutter/dart command fail even when tee succeeds.
  if "$@" 2>&1 | tee "$log_dir/$name.log"; then
    printf 'PASS %s\n' "$name"
  else
    local status=$?
    printf 'FAIL %s (exit %s). See %s/%s.log\n' "$name" "$status" "$log_dir" "$name" >&2
    exit "$status"
  fi
}

run_step flutter-version flutter --version
run_step pub-get flutter pub get
if [[ "$fix" == true ]]; then
  run_step dart-fix dart fix --apply
  run_step dart-format dart format lib test
fi
run_step analyze flutter analyze --no-fatal-infos
run_step test flutter test --reporter expanded
run_step web-build bash tool/vercel_build.sh build --placeholder
printf '\nAll Flutter verification steps passed (the placeholder web build is not a live deployment). Logs: %s\n' "$log_dir"
if [[ "$fix" == true ]]; then
  printf 'Review git diff (dart fix/format modified files) before committing.\n'
fi
