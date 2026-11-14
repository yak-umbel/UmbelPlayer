#!/bin/bash
# Cases for Tools/check_privacy_manifest.sh.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../check_privacy_manifest.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAILURES=0

expect() {
  local label="$1" want="$2"; shift 2
  "$@" >/dev/null 2>&1
  local got=$?
  if [ "$got" -eq "$want" ]; then
    echo "  ✓ $label"
  else
    echo "  ✗ ${label}: expected exit ${want}, got $got"
    FAILURES=$((FAILURES + 1))
  fi
}

manifest() {
  local out="$1"; shift
  {
    echo '<?xml version="1.0" encoding="UTF-8"?>'
    echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
    echo '<plist version="1.0"><dict>'
    echo '<key>NSPrivacyTracking</key><false/>'
    echo '<key>NSPrivacyCollectedDataTypes</key><array/>'
    echo '<key>NSPrivacyAccessedAPITypes</key><array>'
    local category
    for category in "$@"; do
      echo "<dict><key>NSPrivacyAccessedAPIType</key><string>NSPrivacyAccessedAPICategory$category</string>"
      echo '<key>NSPrivacyAccessedAPITypeReasons</key><array><string>C617.1</string></array></dict>'
    done
    echo '</array></dict></plist>'
  } > "$out"
}

echo "test_check_privacy_manifest"

SYSROOT="$(xcrun --sdk macosx --show-sdk-path)"
printf '#include <sys/stat.h>\nint demo(const char *p) { struct stat s; return stat(p, &s); }\n' > "$TMP/stat.c"
xcrun clang -dynamiclib -arch arm64 -isysroot "$SYSROOT" "$TMP/stat.c" -o "$TMP/libstat.dylib"
printf 'int demo(void) { return 7; }\n' > "$TMP/plain.c"
xcrun clang -dynamiclib -arch arm64 -isysroot "$SYSROOT" "$TMP/plain.c" -o "$TMP/libplain.dylib"
manifest "$TMP/none.xcprivacy"
manifest "$TMP/timestamps.xcprivacy" FileTimestamp

expect "a binary calling stat with file timestamps declared passes" 0 \
  "$SCRIPT" --binary "$TMP/libstat.dylib" "$TMP/timestamps.xcprivacy"
expect "a binary calling stat without them fails" 1 \
  "$SCRIPT" --binary "$TMP/libstat.dylib" "$TMP/none.xcprivacy"
expect "a binary calling none of them passes an empty manifest" 0 \
  "$SCRIPT" --binary "$TMP/libplain.dylib" "$TMP/none.xcprivacy"
expect "a missing manifest fails" 1 \
  "$SCRIPT" --binary "$TMP/libplain.dylib" "$TMP/absent.xcprivacy"

mkdir -p "$TMP/src"
echo 'let now = ProcessInfo.processInfo.systemUptime' > "$TMP/src/Clock.swift"
manifest "$TMP/boot.xcprivacy" SystemBootTime
expect "sources reading the uptime with boot time declared pass" 0 \
  "$SCRIPT" --sources "$TMP/src" "$TMP/boot.xcprivacy"
expect "sources reading the uptime without it fail" 1 \
  "$SCRIPT" --sources "$TMP/src" "$TMP/timestamps.xcprivacy"

if [ "$FAILURES" -eq 0 ]; then
  echo "✓ all passed"
  exit 0
fi
echo "✗ ${FAILURES} failed"
exit 1
