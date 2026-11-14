#!/bin/bash
# Exercise the archive gate against real Mach-O binaries and dSYMs.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$HERE/../check_archive_symbols.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAILURES=0

expect() {
  local label="$1" wanted="$2"; shift 2
  "$@" >"$TMP/result" 2>&1
  local got=$?
  if [ "$got" -eq "$wanted" ]; then
    echo "  ✓ $label"
  else
    echo "  ✗ $label: expected $wanted, got $got"
    cat "$TMP/result"
    FAILURES=$((FAILURES + 1))
  fi
}

make_binary() {
  local name="$1" source="$2" debug="$3"
  mkdir -p "$TMP/$name"
  printf 'int archive_probe(void) { return %s; }\n' "$source" > "$TMP/$name/probe.c"
  local flags=(-c -arch arm64)
  [ "$debug" = yes ] && flags+=(-g)
  xcrun clang "${flags[@]}" "$TMP/$name/probe.c" -o "$TMP/$name/probe.o"
  local objects=("$TMP/$name/probe.o")
  if [ "$debug" = data ]; then
    printf 'int archive_marker = %s;\n' "$source" > "$TMP/$name/marker.c"
    xcrun clang -c -g -arch arm64 "$TMP/$name/marker.c" -o "$TMP/$name/marker.o"
    objects+=("$TMP/$name/marker.o")
  fi
  xcrun clang -dynamiclib -arch arm64 -install_name \
    "@rpath/ArchiveProbe.framework/Versions/A/ArchiveProbe" \
    "${objects[@]}" -o "$TMP/$name/ArchiveProbe"
  xcrun dsymutil "$TMP/$name/ArchiveProbe" -o "$TMP/$name/ArchiveProbe.framework.dSYM"
}

ARCHIVE="$TMP/ArchiveProbe.xcarchive"
FRAMEWORK="$ARCHIVE/Products/Applications/ArchiveProbe.app/Contents/Frameworks/ArchiveProbe.framework"
DSYM="$ARCHIVE/dSYMs/ArchiveProbe.framework.dSYM"
make_binary good 7 yes
mkdir -p "$FRAMEWORK/Versions/A" "$ARCHIVE/dSYMs"
cp "$TMP/good/ArchiveProbe" "$FRAMEWORK/Versions/A/ArchiveProbe"
ln -s Versions/A/ArchiveProbe "$FRAMEWORK/ArchiveProbe"
cp -R "$TMP/good/ArchiveProbe.framework.dSYM" "$DSYM"

echo "test_check_archive_symbols"
expect "matching Release framework and debug symbols pass" 0 "$CHECK" "$ARCHIVE"

IOS_ARCHIVE="$TMP/IOSArchive.xcarchive"
IOS_FRAMEWORK="$IOS_ARCHIVE/Products/Applications/ArchiveProbe.app/Frameworks/ArchiveProbe.framework"
mkdir -p "$IOS_FRAMEWORK" "$IOS_ARCHIVE/dSYMs"
cp "$TMP/good/ArchiveProbe" "$IOS_FRAMEWORK/ArchiveProbe"
cp -R "$TMP/good/ArchiveProbe.framework.dSYM" "$IOS_ARCHIVE/dSYMs/"
expect "iOS app framework layout passes" 0 "$CHECK" "$IOS_ARCHIVE"

mv "$DSYM" "$TMP/saved.dSYM"
expect "missing dSYM fails" 1 "$CHECK" "$ARCHIVE"
mv "$TMP/saved.dSYM" "$DSYM"

make_binary other 8 yes
rm -rf "$DSYM"
cp -R "$TMP/other/ArchiveProbe.framework.dSYM" "$DSYM"
expect "mismatched UUID fails" 1 "$CHECK" "$ARCHIVE"

make_binary nodebug 9 no
cp "$TMP/nodebug/ArchiveProbe" "$FRAMEWORK/Versions/A/ArchiveProbe"
rm -rf "$DSYM"
cp -R "$TMP/nodebug/ArchiveProbe.framework.dSYM" "$DSYM"
expect "matching dSYM with empty debug information fails" 1 "$CHECK" "$ARCHIVE"

make_binary dataonly 10 data
cp "$TMP/dataonly/ArchiveProbe" "$FRAMEWORK/Versions/A/ArchiveProbe"
rm -rf "$DSYM"
cp -R "$TMP/dataonly/ArchiveProbe.framework.dSYM" "$DSYM"
expect "nonempty dSYM without function records fails" 1 "$CHECK" "$ARCHIVE"

cp "$TMP/good/ArchiveProbe" "$FRAMEWORK/Versions/A/ArchiveProbe"
rm -rf "$DSYM"
cp -R "$TMP/good/ArchiveProbe.framework.dSYM" "$DSYM"
DWARF="$DSYM/Contents/Resources/DWARF/ArchiveProbe"
offset="$(xcrun otool -l "$DWARF" | awk '
  /sectname __debug_info$/ { in_info = 1; next }
  in_info && $1 == "offset" { print $2; exit }
')"
printf '\xff' | dd of="$DWARF" bs=1 seek="$offset" conv=notrunc 2>/dev/null
expect "corrupt DWARF with matching UUID fails" 1 "$CHECK" "$ARCHIVE"

rm -rf "$DSYM"
cp -R "$TMP/good/ArchiveProbe.framework.dSYM" "$DSYM"
cp "$TMP/good/ArchiveProbe" "$FRAMEWORK/Versions/A/ArchiveProbe"
mkdir -p "$ARCHIVE/Products/Applications/ArchiveProbe.app/Contents/Frameworks/Other.framework"
cp "$TMP/good/ArchiveProbe" "$ARCHIVE/Products/Applications/ArchiveProbe.app/Contents/Frameworks/Other.framework/Other"
expect "every embedded framework needs symbols" 1 "$CHECK" "$ARCHIVE"

if [ "$FAILURES" -eq 0 ]; then
  echo "✓ all passed"
  exit 0
fi
echo "✗ $FAILURES failed"
exit 1
