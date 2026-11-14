#!/bin/bash
# Cases for Tools/link_dylib.sh.
#
# A small static library is built on the spot — one public function, one
# internal — and linked the way the FFmpeg and libass builds link theirs.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../link_dylib.sh
source "$HERE/../link_dylib.sh"
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

echo "test_link_dylib"

SYSROOT="$(xcrun --sdk macosx --show-sdk-path)"
mkdir -p "$TMP/src"
echo 'int demo_helper(void) { return 7; }' > "$TMP/src/helper.c"
echo 'int demo_helper(void); int demo_answer(void) { return demo_helper() * 6; }' > "$TMP/src/answer.c"
# Compiled from inside the mapped directory, as the builds compile: the
# working directory goes into the debug information too.
for f in helper answer; do
  (cd "$TMP" && xcrun clang -c -g -arch arm64 -isysroot "$SYSROOT" -mmacosx-version-min=12.0 \
    -ffile-prefix-map="$TMP=/umbel/demo" "$TMP/src/$f.c" -o "$TMP/$f.o")
done
xcrun ar rcs "$TMP/libdemo.a" "$TMP/helper.o" "$TMP/answer.o"

export_list "$TMP/exports" '^_demo_answer$' "$TMP/libdemo.a"
check "the list names what matches, one to a line" test "$(cat "$TMP/exports")" = "_demo_answer"
check "a pattern nothing matches fails" \
  bash -c "source '$HERE/../link_dylib.sh'; ! export_list '$TMP/none' '^_nothing_' '$TMP/libdemo.a'"

link_dylib "$TMP/UmbelDemo" "@rpath/UmbelDemo.framework/Versions/A/UmbelDemo" 1.2.3 \
  "$TMP/exports" arm64 "$SYSROOT" -mmacosx-version-min=12.0 "$TMP/libdemo.a"
check "a dynamic library" bash -c "file '$TMP/UmbelDemo' | grep -q 'dynamically linked shared library'"
check "the install name given" \
  test "$(otool -D "$TMP/UmbelDemo" | tail -1)" = "@rpath/UmbelDemo.framework/Versions/A/UmbelDemo"
check "only the listed symbol is exported" test "$(nm -gUj "$TMP/UmbelDemo")" = "_demo_answer"
check "the version given" bash -c "otool -L '$TMP/UmbelDemo' | grep -q 'current version 1.2.3'"

uuid_before="$(dwarfdump --uuid "$TMP/UmbelDemo" | awk '{print $2}')"
split_debug "$TMP/UmbelDemo" "$TMP/UmbelDemo.framework.dSYM"
check "a dSYM is made" test -f "$TMP/UmbelDemo.framework.dSYM/Contents/Resources/DWARF/UmbelDemo"
check "the binary keeps its UUID" test "$(dwarfdump --uuid "$TMP/UmbelDemo" | awk '{print $2}')" = "$uuid_before"
check "the dSYM has the binary's UUID" \
  test "$(dwarfdump --uuid "$TMP/UmbelDemo.framework.dSYM" | awk '{print $2}')" = "$uuid_before"
check "the dSYM holds the functions' debug information" \
  bash -c "dwarfdump --debug-info '$TMP/UmbelDemo.framework.dSYM' | grep -q demo_helper"
check "the binary no longer points at object files" bash -c "! nm -a '$TMP/UmbelDemo' | grep -q ' OSO '"
check "the exported symbol survives stripping" test "$(nm -gUj "$TMP/UmbelDemo")" = "_demo_answer"
# The first line of dwarfdump's output is the path of the file it reads.
check "no local path in the dSYM" \
  bash -c "! dwarfdump --debug-info --debug-line '$TMP/UmbelDemo.framework.dSYM' | tail -n +2 \
    | grep -qE '${HOME%/*}/|/private/|/var/folders/'"

# FFmpeg compiles some sources into more than one of its libraries (its
# Vulkan helpers go into libavutil, libavcodec and libswscale alike). Linked
# as static libraries are, only the copy first needed is taken.
mkdir -p "$TMP/dup"
echo 'int demo_shared(void) { return 1; }' > "$TMP/dup/shared.c"
echo 'int demo_shared(void); int demo_first(void) { return demo_shared(); }' > "$TMP/dup/first.c"
echo 'int demo_shared(void); int demo_second(void) { return demo_shared() + 1; }' > "$TMP/dup/second.c"
for f in shared first second; do
  (cd "$TMP" && xcrun clang -c -arch arm64 -isysroot "$SYSROOT" -mmacosx-version-min=12.0 \
    "$TMP/dup/$f.c" -o "$TMP/dup/$f.o")
done
xcrun ar rcs "$TMP/dup/libone.a" "$TMP/dup/first.o" "$TMP/dup/shared.o"
xcrun ar rcs "$TMP/dup/libtwo.a" "$TMP/dup/second.o" "$TMP/dup/shared.o"
export_list "$TMP/dup/exports" '^_demo_(first|second)$' "$TMP/dup/libone.a" "$TMP/dup/libtwo.a"
check "a source compiled into two of the libraries links once" \
  link_dylib "$TMP/dup/UmbelDup" "@rpath/UmbelDup.framework/UmbelDup" 1.0 "$TMP/dup/exports" arm64 \
    "$SYSROOT" -mmacosx-version-min=12.0 "$TMP/dup/libone.a" "$TMP/dup/libtwo.a"
check "both listed functions are there" \
  test "$(nm -gUj "$TMP/dup/UmbelDup" | tr '\n' ' ')" = "_demo_first _demo_second "

if [ "$FAILURES" -eq 0 ]; then
  echo "✓ all passed"
  exit 0
fi
echo "✗ ${FAILURES} failed"
exit 1
