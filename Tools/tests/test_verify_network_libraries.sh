#!/bin/bash
# Cases for Tools/verify_network_libraries.sh.
#
# clang builds the smallest stand-in dylibs on the spot, each breaking one
# rule. A guard that let any of them through would prove nothing by passing
# the real binaries.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../verify_network_libraries.sh"
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

# A library under the name its framework gives it, linking what it is told.
make_lib() {
  local dir="$1" install="$2"; shift 2
  mkdir -p "$dir"
  echo 'int probe(void) { return 1; }' > "$dir/p.c"
  clang -dynamiclib "$dir/p.c" -o "$dir/UmbelProbe" -install_name "$install" "$@"
}

echo "test_verify_network_libraries"

make_lib "$TMP/clean" @rpath/UmbelProbe.framework/UmbelProbe -lc++
expect_exit "system libraries only, under the project's name, pass" 0 "$TMP/clean/UmbelProbe"

make_lib "$TMP/macos" @rpath/UmbelProbe.framework/Versions/A/UmbelProbe
expect_exit "a macOS framework's place is a place in a framework" 0 "$TMP/macos/UmbelProbe"

# What an app may not have: a library at an absolute path outside the system.
mkdir -p "$TMP/extra"
echo 'int other_probe(void) { return 2; }' > "$TMP/extra/o.c"
clang -dynamiclib "$TMP/extra/o.c" -o "$TMP/extra/libother.dylib" -install_name "$TMP/extra/libother.dylib"
make_lib "$TMP/extra" @rpath/UmbelProbe.framework/UmbelProbe -L"$TMP/extra" -lother
expect_exit "a dependency outside the system is refused" 1 "$TMP/extra/UmbelProbe"

# OpenSSL loaded as a dynamic library, as an app's other copy would be.
mkdir -p "$TMP/ssl"
echo 'int ssl_probe(void) { return 3; }' > "$TMP/ssl/s.c"
clang -dynamiclib "$TMP/ssl/s.c" -o "$TMP/ssl/libcrypto.dylib" -install_name @rpath/libcrypto.3.dylib
make_lib "$TMP/ssl" @rpath/UmbelProbe.framework/UmbelProbe -L"$TMP/ssl" -lcrypto
expect_exit "a library loaded through @rpath by an upstream name is refused" 1 "$TMP/ssl/UmbelProbe"

make_lib "$TMP/upstreamname" @rpath/libprobe.dylib
expect_exit "the upstream name, which another copy may carry, is refused" 1 "$TMP/upstreamname/UmbelProbe"

make_lib "$TMP/notframework" /usr/local/lib/UmbelProbe
expect_exit "an absolute install name is refused" 1 "$TMP/notframework/UmbelProbe"

mkdir -p "$TMP/static"
echo 'int probe(void) { return 1; }' > "$TMP/static/p.c"
clang -c "$TMP/static/p.c" -o "$TMP/static/p.o"
ar rcs "$TMP/static/libprobe.a" "$TMP/static/p.o"
cp "$TMP/static/libprobe.a" "$TMP/static/UmbelProbe"
expect_exit "not a dynamic library is refused" 1 "$TMP/static/UmbelProbe"

expect_exit "a missing library is refused (nothing passes silently)" 1 "$TMP/nowhere/UmbelProbe"
expect_exit "no argument is refused" 1

# --binaries: nothing built is nothing to check.
mkdir -p "$TMP/empty"
expect_exit "a directory with none of the libraries passes" 0 --binaries "$TMP/empty"
# One built, as the build leaves it, and broken.
mkdir -p "$TMP/built/UmbelSRT.xcframework/macos-arm64_x86_64/UmbelSRT.framework"
cp "$TMP/extra/UmbelProbe" "$TMP/built/UmbelSRT.xcframework/macos-arm64_x86_64/UmbelSRT.framework/UmbelSRT"
expect_exit "a built library with a stray dependency is refused" 1 --binaries "$TMP/built"
cp "$TMP/clean/UmbelProbe" "$TMP/built/UmbelSRT.xcframework/macos-arm64_x86_64/UmbelSRT.framework/UmbelSRT"
expect_exit "the same slice, clean, passes" 0 --binaries "$TMP/built"
# The second library is looked for as well.
mkdir -p "$TMP/built2/UmbelSSH2.xcframework/macos-arm64_x86_64/UmbelSSH2.framework"
cp "$TMP/extra/UmbelProbe" "$TMP/built2/UmbelSSH2.xcframework/macos-arm64_x86_64/UmbelSSH2.framework/UmbelSSH2"
expect_exit "a second built library with a stray dependency is refused" 1 --binaries "$TMP/built2"

[ "$FAILURES" -eq 0 ] && echo "all passed"
exit $FAILURES
