#!/bin/bash
# The smoke tests on an iPad simulator of each iOS version installed, one after another, then the floor build.
#
#   all.sh            summary at the end; each run's log is tmp/ios-smoke/ios<version>.log
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HERE="$ROOT/Tools/IOSNetworkSmoke"
WORK="$ROOT/tmp/ios-smoke"
mkdir -p "$WORK"
bash "$HERE/setup.sh" || exit 1
status=0
# One iPad for each iOS runtime: "<version> <udid>" lines.
while read -r version udid; do
  [ -n "$udid" ] || continue
  bash "$HERE/run.sh" "$udid" "ios$version"
  result=$?
  echo "iOS $version: $([ $result -eq 0 ] && echo passed || echo FAILED) (log: tmp/ios-smoke/ios$version.log)"
  [ $result -eq 0 ] || status=1
done < <(xcrun simctl list devices available -j | python3 -c '
import json, sys
data = json.load(sys.stdin)["devices"]
for runtime, devices in sorted(data.items()):
    if "iOS" not in runtime:
        continue
    pads = [d for d in devices if d["name"].startswith("iPad") and d.get("isAvailable", True)]
    if pads:
        pads.sort(key=lambda d: (0 if "A16" in d["name"] else 1, d["name"]))
        print(runtime.split("iOS-")[-1].replace("-", "."), pads[0]["udid"])
')
bash "$HERE/build.sh" --floor || status=1
exit $status
