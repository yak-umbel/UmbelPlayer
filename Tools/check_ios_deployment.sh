#!/bin/bash
# Compile the independent example and its framework at the supported iOS floor.
# A recent SDK alone does not check availability for older deployment targets.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$ROOT/tmp/process" "$ROOT/tmp/xcode-derived" "$ROOT/tmp/deployment-checks"
export TMPDIR="$ROOT/tmp/process/"
LOG="$ROOT/tmp/deployment-checks/ios15.log"

if ! xcodebuild build \
    -project "$ROOT/Examples/UmbelPlayiOS/UmbelPlayiOS.xcodeproj" \
    -scheme UmbelPlaybackChecks -configuration Debug \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "$ROOT/tmp/xcode-derived" \
    -clonedSourcePackagesDirPath "$ROOT/tmp/xcode-derived/SourcePackages" \
    IPHONEOS_DEPLOYMENT_TARGET=15.0 CODE_SIGNING_ALLOWED=NO \
    >"$LOG" 2>&1; then
  echo "iOS 15 deployment build failed; log: $LOG" >&2
  grep -m 8 -E 'error:|fatal error:' "$LOG" >&2 || true
  exit 1
fi
echo "iOS 15 deployment build passed; log: $LOG"
