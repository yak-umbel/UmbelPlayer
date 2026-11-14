#!/bin/bash
# Cases for Tools/package_binaries.sh, on a stand-in xcframework.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../package_binaries.sh"
# shellcheck source=../framework.sh
source "$HERE/../framework.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAILURES=0

check() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo "  ✓ $label"
  else
    echo "  ✗ $label"
    FAILURES=$((FAILURES + 1))
  fi
}

echo "test_package_binaries"

echo 'int demo(void) { return 7; }' > "$TMP/demo.c"
xcrun clang -dynamiclib -target arm64-apple-macos12.0 -isysroot "$(xcrun --sdk macosx --show-sdk-path)" \
  -install_name "@rpath/$(framework_binary_path UmbelDemo macos)" "$TMP/demo.c" -o "$TMP/UmbelDemo"
make_framework macos UmbelDemo 1.0.0 12.0 "$TMP/UmbelDemo" - "$TMP/fw"
mkdir -p "$TMP/bin"
xcodebuild -create-xcframework -framework "$TMP/fw/UmbelDemo.framework" -output "$TMP/bin/UmbelDemo.xcframework" >/dev/null

"$SCRIPT" 1.0.0 "$TMP/bin" >/dev/null 2>&1
OUT="$TMP/bin/release/1.0.0"
check "a zip for the xcframework" test -f "$OUT/UmbelDemo.xcframework.zip"
line="$(grep '^UmbelDemo.xcframework.zip ' "$OUT/CHECKSUMS" 2>/dev/null)"
sum="$(echo "$line" | awk '{print $2}')"
check "its checksum is the zip's SHA-256, as Swift Package Manager computes it" \
  test -n "$sum" -a "$sum" = "$(shasum -a 256 "$OUT/UmbelDemo.xcframework.zip" 2>/dev/null | awk '{print $1}')"
check "unsigned without an identity" test "$(echo "$line" | awk '{print $3}')" = unsigned
check "the zip unpacks to the xcframework" \
  bash -c "cd '$TMP' && mkdir un && cd un && ditto -x -k '$OUT/UmbelDemo.xcframework.zip' . && test -f UmbelDemo.xcframework/Info.plist"

UMBEL_SIGN_IDENTITY=- "$SCRIPT" 1.0.1 "$TMP/bin" >/dev/null 2>&1
check "signed with an identity" \
  test "$(awk '/^UmbelDemo.xcframework.zip /{print $3}' "$TMP/bin/release/1.0.1/CHECKSUMS" 2>/dev/null)" = signed
check "the xcframework carries the signature" codesign -dv "$TMP/bin/UmbelDemo.xcframework"

if [ "$FAILURES" -eq 0 ]; then
  echo "✓ all passed"
  exit 0
fi
echo "✗ ${FAILURES} failed"
exit 1
