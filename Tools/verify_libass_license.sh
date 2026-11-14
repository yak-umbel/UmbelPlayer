#!/bin/bash
# Checks how the libass binaries are linked.
#
# Usage:
#   verify_libass_license.sh <UmbelASS binary> <UmbelFriBidi binary>
#   verify_libass_license.sh --binaries <Binaries directory>   # each slice of the xcframeworks
#
# The second is for CI: restored from cache, the binaries skipped the check
# made while building them, and still have to be checked.
#
# Three things to show:
#   1. FriBidi (LGPL) is a library of its own, UmbelFriBidi, which UmbelASS
#      loads through @rpath by its place in its framework: it can be relinked.
#   2. libass depends on system libraries and FriBidi only: FreeType and
#      HarfBuzz are linked in statically, there is no fontconfig, and no
#      absolute path into a local build directory or Homebrew is left.
#   3. Fonts come from CoreText: it links the CoreText framework.
set -euo pipefail

fail() { echo "✗ libass license check failed: $1" >&2; exit 1; }

if [ "${1:-}" = "--binaries" ]; then
  binaries="${2:?usage: verify_libass_license.sh --binaries <directory>}"
  found=false
  # A framework's top-level binary; on macOS a link into Versions/A.
  for slice in "$binaries"/UmbelASS.xcframework/*/; do
    [ -f "$slice/UmbelASS.framework/UmbelASS" ] || continue
    found=true
    "$0" "$slice/UmbelASS.framework/UmbelASS" \
      "$binaries/UmbelFriBidi.xcframework/$(basename "$slice")/UmbelFriBidi.framework/UmbelFriBidi" || exit 1
  done
  $found || fail "no UmbelASS.xcframework slices under $binaries"
  exit 0
fi

ass="${1:?usage: verify_libass_license.sh <UmbelASS binary> <UmbelFriBidi binary>}"
fribidi="${2:?usage: verify_libass_license.sh <UmbelASS binary> <UmbelFriBidi binary>}"

[ -f "$ass" ] || fail "no $ass"
[ -f "$fribidi" ] || fail "no $fribidi (FriBidi has to be a library of its own)"
file "$fribidi" | grep -q "dynamically linked shared library" \
  || fail "UmbelFriBidi is not a dynamic library"

# Dependency lines are the indented ones. A universal binary prints one header
# line per architecture; those are not dependencies.
deps() { otool -L "$1" | awk '/^\t/ {print $1}' | sort -u; }

allowed_system() {
  case "$1" in
    /usr/lib/*|/System/Library/*) return 0 ;;
    *) return 1 ;;
  esac
}

found_fribidi=false
found_coretext=false
while IFS= read -r dep; do
  case "$dep" in
    @rpath/UmbelASS.framework/*) ;;
    @rpath/UmbelFriBidi.framework/*) found_fribidi=true ;;
    */CoreText.framework/*) found_coretext=true ;;
    *) allowed_system "$dep" || fail "UmbelASS depends on what it may not: $dep" ;;
  esac
done < <(deps "$ass")

$found_fribidi || fail "UmbelASS does not load UmbelFriBidi through @rpath"
$found_coretext || fail "UmbelASS does not link CoreText: the wrong font provider"

while IFS= read -r dep; do
  case "$dep" in
    @rpath/UmbelFriBidi.framework/*) ;;
    *) allowed_system "$dep" || fail "UmbelFriBidi depends on what it may not: $dep" ;;
  esac
done < <(deps "$fribidi")

echo "✓ libass license check passed: $ass"
