#!/bin/bash
# Verify that every framework embedded in an app archive has a matching,
# usable dSYM in the archive's dSYMs directory.
set -uo pipefail

archive="${1:?usage: $0 <app.xcarchive>}"
[ "$#" -eq 1 ] || { echo "usage: $0 <app.xcarchive>" >&2; exit 2; }
[ -d "$archive/Products/Applications" ] && [ -d "$archive/dSYMs" ] || {
  echo "✗ not an app archive with dSYMs: $archive" >&2
  exit 1
}

failures=0
count=0
fail() { echo "✗ $1" >&2; failures=$((failures + 1)); }
uuids() { xcrun dwarfdump --uuid "$1" 2>/dev/null | awk '{print $2 " " $3}' | sort; }

check_framework() {
  local framework="$1" name binary dsym dwarf binary_uuids dsym_uuids arch size prior
  prior="$failures"
  name="$(basename "$framework" .framework)"
  binary="$framework/$name"
  dsym="$archive/dSYMs/$name.framework.dSYM"
  dwarf="$dsym/Contents/Resources/DWARF/$name"
  count=$((count + 1))

  [ -f "$binary" ] || { fail "$framework has no $name binary"; return; }
  [ -f "$dwarf" ] || { fail "$name has no archive dSYM binary"; return; }
  binary_uuids="$(uuids "$binary")"
  dsym_uuids="$(uuids "$dwarf")"
  [ -n "$binary_uuids" ] && [ "$binary_uuids" = "$dsym_uuids" ] || {
    fail "$name binary and dSYM UUID/architecture pairs differ"
    return
  }

  for arch in $(xcrun lipo -archs "$binary" 2>/dev/null); do
    size="$(xcrun otool -arch "$arch" -l "$dwarf" 2>/dev/null | awk '
      /sectname __debug_info$/ { in_info = 1; next }
      in_info && $1 == "size" { print $2; exit }
    ')"
    if [ -z "$size" ] || [[ "$size" =~ ^0x0+$ ]] || [ "$size" = 0 ]; then
      fail "$name dSYM has no DWARF debug information for $arch"
      continue
    fi
    if ! xcrun dwarfdump --verify --quiet --arch "$arch" "$dwarf"; then
      fail "$name dSYM has invalid DWARF information for $arch"
      continue
    fi
    if ! grep -m 1 -q 'DW_TAG_subprogram' \
        < <(xcrun dwarfdump --debug-info --arch "$arch" "$dwarf" 2>/dev/null); then
      fail "$name dSYM has no function debug records for $arch"
    fi
  done
  [ "$failures" -ne "$prior" ] || echo "✓ $name: $binary_uuids"
}

while IFS= read -r -d '' framework; do
  check_framework "$framework"
done < <(find "$archive/Products/Applications" -type d -name '*.framework' -print0)
[ "$count" -gt 0 ] || fail "$archive has no embedded frameworks"
[ "$failures" -eq 0 ] || exit 1
echo "✓ archive symbols: $count embedded frameworks"
