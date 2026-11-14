#!/bin/bash
# Cases for Tools/verify_libass_license.sh.
#
# clang builds the smallest stand-in dylibs on the spot, each breaking one
# rule. A guard that let any of them through would prove nothing by passing
# the real binaries.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../verify_libass_license.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAILURES=0

expect_exit() {
  local label="$1" want="$2"; shift 2
  "$SCRIPT" "$@" >/dev/null 2>&1
  local got=$?
  if [ "$got" -eq "$want" ]; then
    echo "  ✓ $label"
  else
    echo "  ✗ ${label}: expected exit ${want}, got $got"
    FAILURES=$((FAILURES + 1))
  fi
}

# One pair to a directory: UmbelFriBidi, and an UmbelASS that loads it by
# its place in its framework, as the build links them. The files keep the
# plain names -l finds them by; the install names are what count.
make_pair() {
  local dir="$1"; shift
  mkdir -p "$dir"
  echo 'int fribidi_probe(void) { return 1; }' > "$dir/f.c"
  clang -dynamiclib "$dir/f.c" -o "$dir/libfribidi.dylib" \
    -install_name "${FRIBIDI_NAME:-@rpath/UmbelFriBidi.framework/UmbelFriBidi}"
  echo 'int fribidi_probe(void); int ass_probe(void) { return fribidi_probe(); }' > "$dir/a.c"
  clang -dynamiclib "$dir/a.c" -o "$dir/libass.dylib" -install_name @rpath/UmbelASS.framework/UmbelASS \
    -L"$dir" "$@"
}

echo "test_verify_libass_license"

make_pair "$TMP/clean" -lfribidi -framework CoreText
expect_exit "system libraries, FriBidi through @rpath and CoreText pass" 0 "$TMP/clean/libass.dylib" "$TMP/clean/libfribidi.dylib"

# A "fontconfig" installed at an absolute path: a dependency outside the system.
mkdir -p "$TMP/extra"
echo 'int fc_probe(void) { return 2; }' > "$TMP/extra/fc.c"
clang -dynamiclib "$TMP/extra/fc.c" -o "$TMP/extra/libfontconfig.dylib" \
  -install_name "$TMP/extra/libfontconfig.dylib"
make_pair "$TMP/extra" -lfribidi -lfontconfig -framework CoreText
expect_exit "a dependency outside the system is refused" 1 "$TMP/extra/libass.dylib" "$TMP/extra/libfribidi.dylib"

make_pair "$TMP/nocoretext" -lfribidi -framework CoreFoundation
expect_exit "no CoreText is refused" 1 "$TMP/nocoretext/libass.dylib" "$TMP/nocoretext/libfribidi.dylib"

mkdir -p "$TMP/static"
echo 'int fribidi_probe(void) { return 1; }' > "$TMP/static/f.c"
clang -c "$TMP/static/f.c" -o "$TMP/static/f.o"
ar rcs "$TMP/static/libfribidi.a" "$TMP/static/f.o"
echo 'int fribidi_probe(void); int ass_probe(void) { return fribidi_probe(); }' > "$TMP/static/a.c"
clang -dynamiclib "$TMP/static/a.c" -o "$TMP/static/libass.dylib" -install_name @rpath/UmbelASS.framework/UmbelASS \
  "$TMP/static/libfribidi.a" -framework CoreText
cp "$TMP/static/libfribidi.a" "$TMP/static/libfribidi.dylib"
expect_exit "FriBidi linked in statically (LGPL, cannot be relinked) is refused" 1 "$TMP/static/libass.dylib" "$TMP/static/libfribidi.dylib"

# The upstream name, which another copy in an app may carry.
FRIBIDI_NAME=@rpath/libfribidi.dylib make_pair "$TMP/oldname" -lfribidi -framework CoreText
expect_exit "FriBidi loaded by the upstream name is refused" 1 "$TMP/oldname/libass.dylib" "$TMP/oldname/libfribidi.dylib"

expect_exit "missing libraries are refused (nothing passes silently)" 1 "$TMP/nowhere/libass.dylib" "$TMP/nowhere/libfribidi.dylib"

# The pair as the build leaves it: frameworks, loaded by their place in them.
make_framework_pair() {
  local dir="$1"
  mkdir -p "$dir"
  echo 'int fribidi_probe(void) { return 1; }' > "$dir/f.c"
  clang -dynamiclib "$dir/f.c" -o "$dir/libfribidi.dylib" \
    -install_name @rpath/UmbelFriBidi.framework/Versions/A/UmbelFriBidi
  echo 'int fribidi_probe(void); int ass_probe(void) { return fribidi_probe(); }' > "$dir/a.c"
  clang -dynamiclib "$dir/a.c" -o "$dir/libass.dylib" \
    -install_name @rpath/UmbelASS.framework/Versions/A/UmbelASS -L"$dir" -lfribidi -framework CoreText
}
make_framework_pair "$TMP/framework"
expect_exit "FriBidi loaded as a framework through @rpath passes" 0 "$TMP/framework/libass.dylib" "$TMP/framework/libfribidi.dylib"

# --binaries finds each slice's binaries inside the frameworks.
slice="$TMP/binaries/UmbelASS.xcframework/macos-arm64"
mkdir -p "$slice/UmbelASS.framework" "$TMP/binaries/UmbelFriBidi.xcframework/macos-arm64/UmbelFriBidi.framework"
cp "$TMP/framework/libass.dylib" "$slice/UmbelASS.framework/UmbelASS"
cp "$TMP/framework/libfribidi.dylib" "$TMP/binaries/UmbelFriBidi.xcframework/macos-arm64/UmbelFriBidi.framework/UmbelFriBidi"
expect_exit "--binaries checks the frameworks' binaries" 0 --binaries "$TMP/binaries"
cp "$TMP/extra/libass.dylib" "$slice/UmbelASS.framework/UmbelASS"
expect_exit "--binaries refuses a framework slice that breaks a rule" 1 --binaries "$TMP/binaries"
mkdir -p "$TMP/empty/UmbelASS.xcframework/macos-arm64"
expect_exit "--binaries with no frameworks in the slices is refused" 1 --binaries "$TMP/empty"

if [ "$FAILURES" -eq 0 ]; then
  echo "✓ all passed"
  exit 0
fi
echo "✗ ${FAILURES} failed"
exit 1
