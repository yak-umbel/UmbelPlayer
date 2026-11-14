#!/bin/bash
# Packs the built binaries for publishing: each xcframework zipped, with the
# checksum Swift Package Manager checks a downloaded binary against — what
# binaryTarget(url:checksum:) will name. Publishes nothing.
#
# Signed first when UMBEL_SIGN_IDENTITY names a signing identity, so an app
# can see who built them; "-" signs ad hoc, for tests.
#
# Usage: Tools/package_binaries.sh <version> [<Binaries directory>]
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
version="${1:?usage: $0 <version> [<Binaries directory>]}"
binaries="${2:-$ROOT/Binaries}"
out="$binaries/release/$version"
rm -rf "$out"
mkdir -p "$out"
: > "$out/CHECKSUMS"

found=false
for xcf in "$binaries"/Umbel*.xcframework; do
  [ -d "$xcf" ] || continue
  found=true
  name="$(basename "$xcf")"
  state=unsigned
  if [ -n "${UMBEL_SIGN_IDENTITY:-}" ]; then
    if [ "$UMBEL_SIGN_IDENTITY" = - ]; then
      codesign --force --sign - "$xcf"
    else
      codesign --force --timestamp --sign "$UMBEL_SIGN_IDENTITY" "$xcf"
    fi
    state=signed
  fi
  ditto -c -k --keepParent "$xcf" "$out/$name.zip"
  # The same SHA-256 `swift package compute-checksum` gives, without needing
  # a package around the file.
  checksum="$(shasum -a 256 "$out/$name.zip" | awk '{print $1}')"
  echo "$name.zip $checksum $state" >> "$out/CHECKSUMS"
done
$found || { echo "✗ no Umbel*.xcframework under $binaries" >&2; exit 1; }
[ -n "${UMBEL_SIGN_IDENTITY:-}" ] || echo "note: not signed (UMBEL_SIGN_IDENTITY unset)"
echo "✓ packed into $out"
