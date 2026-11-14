#!/bin/bash
# Cases for Tools/check_binaries.sh: a one-slice xcframework made the way the
# builds make theirs, then spoiled one way at a time.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../check_binaries.sh"
# shellcheck source=../link_dylib.sh
source "$HERE/../link_dylib.sh"
# shellcheck source=../framework.sh
source "$HERE/../framework.sh"
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

SYSROOT="$(xcrun --sdk macosx --show-sdk-path)"
PRIVACY="$TMP/privacy.xcprivacy"
echo '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict/></plist>' > "$PRIVACY"

# make_xcf <dir> <export regex> <install name> <with dSYM: yes|no> <map paths: yes|no> [functions]
#   Compiled from inside <dir>, as the builds compile inside their own. With
#   thousands of functions its debug information outgrows a pipe's buffer,
#   as a real library's does.
make_xcf() {
  local dir="$1" pattern="$2" install="$3" dsym="$4" map="$5" count="${6:-0}"
  mkdir -p "$dir"
  printf 'int demo_helper(void) { return 7; }\nint demo_answer(void) { return demo_helper() * 6; }\n' > "$dir/demo.c"
  local i
  for ((i = 0; i < count; i++)); do echo "int demo_filler_$i(int x) { return x + $i; }"; done >> "$dir/demo.c"
  local flags=(-c -arch arm64 -isysroot "$SYSROOT" -mmacosx-version-min=12.0)
  # NODEBUG=1: compiled without debug information, as a build that dropped -g.
  [ -n "${NODEBUG:-}" ] || flags+=(-g)
  [ "$map" = yes ] && flags+=(-ffile-prefix-map="$TMP=/umbel/demo")
  (cd "$dir" && xcrun clang "${flags[@]}" "$dir/demo.c" -o "$dir/demo.o")
  xcrun ar rcs "$dir/libdemo.a" "$dir/demo.o"
  export_list "$dir/exports" "$pattern" "$dir/libdemo.a"
  link_dylib "$dir/UmbelDemo" "$install" 1.2.3 "$dir/exports" arm64 "$SYSROOT" -mmacosx-version-min=12.0 "$dir/libdemo.a"
  split_debug "$dir/UmbelDemo" "$dir/UmbelDemo.framework.dSYM"
  make_framework macos UmbelDemo 1.2.3 12.0 "$dir/UmbelDemo" - "$dir/fw" "$PRIVACY"
  local args=(-framework "$dir/fw/UmbelDemo.framework")
  [ "$dsym" = yes ] && args+=(-debug-symbols "$dir/UmbelDemo.framework.dSYM")
  xcodebuild -create-xcframework "${args[@]}" -output "$dir/UmbelDemo.xcframework" >/dev/null
}

RIGHT="@rpath/UmbelDemo.framework/Versions/A/UmbelDemo"
echo "test_check_binaries"

make_xcf "$TMP/good" '^_demo_answer$' "$RIGHT" yes yes
expect "a sound xcframework passes" 0 "$SCRIPT" "$TMP/good/UmbelDemo.xcframework" '^_demo_answer$'
expect "an export outside the pattern fails" 1 "$SCRIPT" "$TMP/good/UmbelDemo.xcframework" '^_other_'

make_xcf "$TMP/nodsym" '^_demo_answer$' "$RIGHT" no yes
expect "a slice without its dSYM fails" 1 "$SCRIPT" "$TMP/nodsym/UmbelDemo.xcframework" '^_demo_answer$'

# make_framework refuses the binary, so there is no xcframework to pass.
make_xcf "$TMP/badname" '^_demo_answer$' "/usr/local/lib/UmbelDemo.dylib" yes yes 2>/dev/null
expect "an install name outside the framework fails" 1 "$SCRIPT" "$TMP/badname/UmbelDemo.xcframework" '^_demo_answer$'

# Built without the prefix map: the dSYM names the local directory.
make_xcf "$TMP/path" '^_demo_answer$' "$RIGHT" yes no
expect "a local path in the dSYM fails" 1 "$SCRIPT" "$TMP/path/UmbelDemo.xcframework" '^_demo_answer$'

# Built without -g: a dSYM is made, but holds nothing to read a crash by.
NODEBUG=1 make_xcf "$TMP/nodebug" '^_demo_answer$' "$RIGHT" yes yes 2>/dev/null
expect "a dSYM without debug information fails" 1 "$SCRIPT" "$TMP/nodebug/UmbelDemo.xcframework" '^_demo_answer$'

# A framework whose privacy manifest went missing.
cp -R "$TMP/good" "$TMP/noprivacy"
rm "$TMP/noprivacy/UmbelDemo.xcframework/macos-arm64/UmbelDemo.framework/Versions/A/Resources/PrivacyInfo.xcprivacy"
expect "a framework without its privacy manifest fails" 1 "$SCRIPT" "$TMP/noprivacy/UmbelDemo.xcframework" '^_demo_answer$'

# Real libraries: debug information far larger than a pipe holds, the
# checks reading all of it.
make_xcf "$TMP/large" '^_demo_answer$' "$RIGHT" yes yes 4000
expect "a large sound xcframework passes" 0 "$SCRIPT" "$TMP/large/UmbelDemo.xcframework" '^_demo_answer$'
make_xcf "$TMP/largepath" '^_demo_answer$' "$RIGHT" yes no 4000
expect "a large one naming a local path fails" 1 "$SCRIPT" "$TMP/largepath/UmbelDemo.xcframework" '^_demo_answer$'

# A library linked against one outside the system and the project's own:
# on a machine without it, the app would not load.
mkdir -p "$TMP/foreign"
echo 'int foreign_probe(void) { return 3; }' > "$TMP/foreign/f.c"
xcrun clang -dynamiclib -arch arm64 -isysroot "$SYSROOT" -mmacosx-version-min=12.0 "$TMP/foreign/f.c" \
  -install_name /opt/homebrew/lib/libforeign.dylib -o "$TMP/foreign/libforeign.dylib"
mkdir -p "$TMP/deps"
printf 'int foreign_probe(void);\nint demo_answer(void) { return foreign_probe(); }\n' > "$TMP/deps/demo.c"
(cd "$TMP/deps" && xcrun clang -c -g -arch arm64 -isysroot "$SYSROOT" -mmacosx-version-min=12.0 \
  -ffile-prefix-map="$TMP=/umbel/demo" "$TMP/deps/demo.c" -o "$TMP/deps/demo.o")
xcrun ar rcs "$TMP/deps/libdemo.a" "$TMP/deps/demo.o"
export_list "$TMP/deps/exports" '^_demo_answer$' "$TMP/deps/libdemo.a"
link_dylib "$TMP/deps/UmbelDemo" "$RIGHT" 1.2.3 "$TMP/deps/exports" arm64 "$SYSROOT" -mmacosx-version-min=12.0 \
  "$TMP/deps/libdemo.a" "$TMP/foreign/libforeign.dylib"
split_debug "$TMP/deps/UmbelDemo" "$TMP/deps/UmbelDemo.framework.dSYM"
make_framework macos UmbelDemo 1.2.3 12.0 "$TMP/deps/UmbelDemo" - "$TMP/deps/fw" "$PRIVACY"
xcodebuild -create-xcframework -framework "$TMP/deps/fw/UmbelDemo.framework" \
  -debug-symbols "$TMP/deps/UmbelDemo.framework.dSYM" -output "$TMP/deps/UmbelDemo.xcframework" >/dev/null
expect "a dependency outside the system and the project fails" 1 "$SCRIPT" "$TMP/deps/UmbelDemo.xcframework" '^_demo_answer$'

if [ "$FAILURES" -eq 0 ]; then
  echo "✓ all passed"
  exit 0
fi
echo "✗ ${FAILURES} failed"
exit 1
