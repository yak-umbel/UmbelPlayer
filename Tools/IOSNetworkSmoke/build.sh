#!/bin/bash
# The core, which holds the five modules, built for iOS devices at the floor the package supports (iOS 15),
# which a test run cannot check: there is no simulator of that version, and the tests build for a later one.
#
#   build.sh --floor
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HERE="$ROOT/Tools/IOSNetworkSmoke"
WORK="$ROOT/tmp/ios-smoke"
[ "${1:-}" = "--floor" ] || { echo "usage: build.sh --floor" >&2; exit 2; }
mkdir -p "$ROOT/tmp/process" "$WORK"
export TMPDIR="$ROOT/tmp/process/"
[ -d "$WORK/pkg" ] || bash "$HERE/setup.sh" || exit 1
cd "$WORK/pkg" || exit 1
status=0
# The package's one scheme, named after it, builds the core and the modules in it.
for scheme in UmbelPlayer; do
  if xcodebuild build -scheme "$scheme" -destination 'generic/platform=iOS' -derivedDataPath "$WORK/derived-device" \
      IPHONEOS_DEPLOYMENT_TARGET=15.0 CODE_SIGNING_ALLOWED=NO > "$WORK/floor-$scheme.log" 2>&1; then
    echo "$scheme: iOS device, floor 15.0: build passed"
  else
    echo "$scheme: iOS device, floor 15.0: FAILED (log: tmp/ios-smoke/floor-$scheme.log)"
    grep -m3 "error:" "$WORK/floor-$scheme.log" | cut -c1-200
    status=1
  fi
done
exit $status
