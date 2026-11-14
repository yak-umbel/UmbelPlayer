#!/bin/bash
# A copy of the package, cut down to what the iOS Simulator run needs, under tmp/ios-smoke/pkg:
# the SRT, RIST and NFS suites as they are (their peers are in the test process), two smoke tests that
# read from servers on this Mac, and what those suites read from the repository.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HERE="$ROOT/Tools/IOSNetworkSmoke"
W="$ROOT/tmp/ios-smoke/pkg"
rm -rf "${W:?}"
mkdir -p "$W/Tests" "$W/Binaries" "$W/Tools/BuildNetwork" "$W/Tests/Fixtures"
cp -R "$ROOT/Sources" "$W/Sources"
for t in UmbelSRTSourceTests UmbelRISTSourceTests UmbelNFSSourceTests; do cp -R "$ROOT/Tests/$t" "$W/Tests/$t"; done
# The binaries are shared, read only: a copy of them would be most of a gigabyte.
for f in "$ROOT"/Binaries/*.xcframework; do ln -s "$f" "$W/Binaries/$(basename "$f")"; done
# What the notices tests and one demux test read from the repository, at the paths they look for.
cp "$ROOT/Tools/BuildNetwork/VERSIONS" "$W/Tools/BuildNetwork/VERSIONS"
cp "$ROOT/Tests/Fixtures/live_stream.ts" "$W/Tests/Fixtures/live_stream.ts"
mkdir -p "$W/Tests/UmbelSFTPSmokeTests" "$W/Tests/UmbelSMBSmokeTests"
cp "$HERE/SmokeTests/SFTPSmokeTests.swift" "$W/Tests/UmbelSFTPSmokeTests/"
cp "$HERE/SmokeTests/SMBSmokeTests.swift" "$W/Tests/UmbelSMBSmokeTests/"
cp "$HERE/Package.swift.template" "$W/Package.swift"
echo "package copy ready: $W"
