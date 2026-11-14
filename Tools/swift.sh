#!/bin/bash
# Share one package cache across local builds, tests, and command-line runs.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ "$#" -gt 0 ] || { echo "usage: $0 build|test|run|package [arguments...]" >&2; exit 2; }
action="$1"; shift
case "$action" in
  build|test|run|package) ;;
  *) echo "unsupported Swift command: $action" >&2; exit 2 ;;
esac

mkdir -p "$ROOT/tmp/swift-build" "$ROOT/tmp/swiftpm-cache" "$ROOT/tmp/process"
export TMPDIR="$ROOT/tmp/process/"
export CLANG_MODULE_CACHE_PATH="$ROOT/tmp/swift-build/ModuleCache"

finish() {
  local status=$?
  mkdir -p "$ROOT/tmp/swift-build" && touch "$ROOT/tmp/swift-build" || true
  python3 -B "$ROOT/Tools/clean_builds.py" --check >&2 || true
  exit "$status"
}
trap finish EXIT

swift "$action" --package-path "$ROOT" --scratch-path "$ROOT/tmp/swift-build" \
  --cache-path "$ROOT/tmp/swiftpm-cache" --manifest-cache local "$@"
