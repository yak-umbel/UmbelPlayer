#!/bin/bash
# Cases for Tools/framework.sh.
#
# clang builds a stand-in dylib on the spot; each platform's framework is
# made from it and checked for the shape an app, the code signature and
# xcodebuild -create-xcframework expect.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

# A dylib for a platform, its install name where the framework keeps it.
make_dylib() {
  local platform="$1" target="$2"
  mkdir -p "$TMP/$platform/headers"
  echo 'int demo(void) { return 7; }' > "$TMP/$platform/demo.c"
  echo 'int demo(void);' > "$TMP/$platform/headers/demo.h"
  xcrun clang -dynamiclib -target "$target" "$TMP/$platform/demo.c" \
    -isysroot "$(xcrun --sdk "$(sdk_of "$platform")" --show-sdk-path)" \
    -install_name "@rpath/$(framework_binary_path libdemo "$platform")" \
    -o "$TMP/$platform/libdemo.dylib"
}

sdk_of() {
  case "$1" in
    ios) echo iphoneos ;;
    iossim) echo iphonesimulator ;;
    macos) echo macosx ;;
  esac
}

plist_value() { /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null; }

echo "test_framework"

check "the binary sits at the top of an iOS framework" \
  test "$(framework_binary_path libdemo ios)" = "libdemo.framework/libdemo"
check "the binary sits in Versions/A of a macOS framework" \
  test "$(framework_binary_path libdemo macos)" = "libdemo.framework/Versions/A/libdemo"

make_dylib ios arm64-apple-ios15.0
make_framework ios libdemo 1.2.3 15.0 "$TMP/ios/libdemo.dylib" "$TMP/ios/headers" "$TMP/ios/out"
fw="$TMP/ios/out/libdemo.framework"
check "iOS: binary, headers and Info.plist at the top" \
  test -f "$fw/libdemo" -a -f "$fw/Headers/demo.h" -a -f "$fw/Info.plist"
check "iOS: the bundle names its binary" test "$(plist_value "$fw/Info.plist" CFBundleExecutable)" = libdemo
check "iOS: a framework bundle" test "$(plist_value "$fw/Info.plist" CFBundlePackageType)" = FMWK
check "iOS: the bundle identifier is the project's" \
  test "$(plist_value "$fw/Info.plist" CFBundleIdentifier)" = "$FRAMEWORK_ID_PREFIX.libdemo"
check "iOS: the library's version" test "$(plist_value "$fw/Info.plist" CFBundleShortVersionString)" = 1.2.3
check "iOS: the minimum OS the app store asks for" test "$(plist_value "$fw/Info.plist" MinimumOSVersion)" = 15.0
check "iOS: the platform" test "$(plist_value "$fw/Info.plist" CFBundleSupportedPlatforms:0)" = iPhoneOS
check "iOS: signed as a whole" codesign --verify --strict "$fw"

make_dylib iossim arm64-apple-ios15.0-simulator
make_framework iossim libdemo 1.2.3 15.0 "$TMP/iossim/libdemo.dylib" - "$TMP/iossim/out"
check "simulator: no headers when none are given" test ! -e "$TMP/iossim/out/libdemo.framework/Headers"
check "simulator: the platform" \
  test "$(plist_value "$TMP/iossim/out/libdemo.framework/Info.plist" CFBundleSupportedPlatforms:0)" = iPhoneSimulator

make_dylib macos arm64-apple-macos12.0
make_framework macos libdemo 1.2.3 12.0 "$TMP/macos/libdemo.dylib" "$TMP/macos/headers" "$TMP/macos/out"
fw="$TMP/macos/out/libdemo.framework"
check "macOS: a versioned bundle, Current pointing at A" test "$(readlink "$fw/Versions/Current")" = A
check "macOS: the top-level binary is a link into it" test "$(readlink "$fw/libdemo")" = Versions/Current/libdemo
check "macOS: headers and resources linked from the top" \
  test -f "$fw/Headers/demo.h" -a -f "$fw/Resources/Info.plist"
check "macOS: the minimum system" \
  test "$(plist_value "$fw/Resources/Info.plist" LSMinimumSystemVersion)" = 12.0
check "macOS: signed as a whole" codesign --verify --strict "$fw"

# FFmpeg's headers include one another as "libavutil/x.h": rewritten
# relative, they are found inside a framework of any name.
mkdir -p "$TMP/h/libdemoutil" "$TMP/h/libdemocodec"
printf '#include "libdemoutil/b.h"\n#define A_VALUE B_VALUE\n' > "$TMP/h/libdemoutil/a.h"
printf '#define B_VALUE 7\n' > "$TMP/h/libdemoutil/b.h"
printf '#include <stdint.h>\n#include <libdemoutil/a.h>\nstatic const int64_t demo_value = A_VALUE;\n' \
  > "$TMP/h/libdemocodec/c.h"
rewrite_includes "$TMP/h" libdemoutil libdemocodec
check "quoted includes become relative" grep -q '#include "../libdemoutil/b.h"' "$TMP/h/libdemoutil/a.h"
check "angled includes become relative" grep -q '#include "../libdemoutil/a.h"' "$TMP/h/libdemocodec/c.h"
check "other includes stay" grep -q '#include <stdint.h>' "$TMP/h/libdemocodec/c.h"

echo '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict/></plist>' > "$TMP/privacy.xcprivacy"
# A framework named unlike its header directories, as UmbelFFmpeg is.
xcrun clang -dynamiclib -target arm64-apple-macos12.0 "$TMP/macos/demo.c" \
  -isysroot "$(xcrun --sdk macosx --show-sdk-path)" \
  -install_name "@rpath/$(framework_binary_path UmbelDemo macos)" -o "$TMP/macos/UmbelDemo.dylib"
make_framework macos UmbelDemo 1.2.3 12.0 "$TMP/macos/UmbelDemo.dylib" "$TMP/h" "$TMP/named" "$TMP/privacy.xcprivacy"
echo '#include <UmbelDemo/libdemocodec/c.h>
int main(void) { return (int)demo_value - 7; }' > "$TMP/use.c"
check "found through the framework alone, whatever its name" \
  xcrun clang -fsyntax-only -F "$TMP/named" "$TMP/use.c"
check "macOS: the privacy manifest among the resources" \
  test -f "$TMP/named/UmbelDemo.framework/Versions/A/Resources/PrivacyInfo.xcprivacy"
check "macOS: still signed as a whole" codesign --verify --strict "$TMP/named/UmbelDemo.framework"
make_framework ios libdemo 1.2.3 15.0 "$TMP/ios/libdemo.dylib" - "$TMP/ios/withprivacy" "$TMP/privacy.xcprivacy"
check "iOS: the privacy manifest at the top" \
  test -f "$TMP/ios/withprivacy/libdemo.framework/PrivacyInfo.xcprivacy"

check "one xcframework takes the three" xcodebuild -create-xcframework \
  -framework "$TMP/ios/out/libdemo.framework" \
  -framework "$TMP/iossim/out/libdemo.framework" \
  -framework "$TMP/macos/out/libdemo.framework" \
  -output "$TMP/libdemo.xcframework"

# The macOS library, its install name in Versions/A, wrapped for iOS.
check "a library whose install name is not its place in the framework is refused" \
  bash -c "source '$HERE/../framework.sh';
    ! make_framework ios libdemo 1.2.3 15.0 '$TMP/macos/libdemo.dylib' - '$TMP/wrong'"

if [ "$FAILURES" -eq 0 ]; then
  echo "✓ all passed"
  exit 0
fi
echo "✗ ${FAILURES} failed"
exit 1
