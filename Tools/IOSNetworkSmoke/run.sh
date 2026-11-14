#!/bin/bash
# The smoke tests in the iOS Simulator, on one device.
#
#   run.sh <simulator udid> [label]
#
# Starts the servers, runs the suites (their output in tmp/ios-smoke/<label>.log), and stops the servers
# whatever came of it. The tests build for iOS 17: one of the suites uses ContinuousClock, which iOS 16 has.
# The libraries' own floor, iOS 15, is checked by build.sh --floor.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HERE="$ROOT/Tools/IOSNetworkSmoke"
WORK="$ROOT/tmp/ios-smoke"
UDID="${1:?usage: run.sh <simulator udid> [label]}"; LABEL="${2:-run}"
mkdir -p "$ROOT/tmp/process" "$WORK"
export TMPDIR="$ROOT/tmp/process/"
[ -d "$WORK/pkg" ] || bash "$HERE/setup.sh" || exit 1
trap 'bash "$HERE/servers.sh" stop' EXIT
bash "$HERE/servers.sh" start || exit 1
# shellcheck disable=SC1091
source "$WORK/env.sh"
cd "$WORK/pkg" || exit 1
# With one product in the package, Xcode makes one scheme, named after the package; it has every test target.
xcodebuild test -scheme UmbelPlayer \
  -destination "platform=iOS Simulator,id=$UDID" \
  -derivedDataPath "$WORK/derived" \
  -only-testing:UmbelSRTSourceTests -only-testing:UmbelRISTSourceTests -only-testing:UmbelNFSSourceTests \
  -only-testing:UmbelSFTPSmokeTests -only-testing:UmbelSMBSmokeTests \
  IPHONEOS_DEPLOYMENT_TARGET=17.0 CODE_SIGNING_ALLOWED=NO \
  > "$WORK/$LABEL.log" 2>&1
status=$?
echo "xcodebuild exit=$status" >> "$WORK/$LABEL.log"
exit $status
