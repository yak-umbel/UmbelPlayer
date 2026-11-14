#!/bin/bash
# Exercise the actual adapter under process entry points XCTest cannot own.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$ROOT/tmp/display-layer-access-check"
mkdir -p "$WORK" "$ROOT/tmp/process" "$ROOT/tmp/swift-build/ModuleCache"
export TMPDIR="$ROOT/tmp/process/"

xcrun --sdk macosx swiftc -swift-version 6 -parse-as-library \
  -module-cache-path "$ROOT/tmp/swift-build/ModuleCache" \
  "$ROOT/Sources/UmbelCore/Video/DisplayLayerAccess.swift" \
  "$ROOT/Tools/tests/fixtures/DisplayLayerAccessCheck.swift" \
  -o "$WORK/check"

python3 -B - "$WORK/check" <<'PY'
import subprocess
import sys

failed = False
for mode in ("main-thread", "main-queue", "background"):
    try:
        result = subprocess.run([sys.argv[1], mode], capture_output=True, text=True, timeout=10)
    except subprocess.TimeoutExpired:
        print(f"FAIL {mode}: synchronous access did not return", flush=True)
        failed = True
        continue
    if result.returncode:
        print(f"FAIL {mode}: exit {result.returncode}\n{result.stdout}{result.stderr}", flush=True)
        failed = True
    else:
        print(f"PASS {mode}", flush=True)
sys.exit(1 if failed else 0)
PY
