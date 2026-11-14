#!/bin/bash
# Build independent unsigned Release app archives and check their embedded
# framework symbols. The output directory is kept for inspection.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v xcodebuild >/dev/null && xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1 || {
  echo "✗ Xcode with the iOS device SDK is required" >&2
  exit 1
}
for name in UmbelFFmpeg UmbelASS UmbelFriBidi; do
  [ -d "$ROOT/Binaries/$name.xcframework" ] || {
    echo "✗ missing Binaries/$name.xcframework" >&2
    exit 1
  }
done
[ "$#" -le 1 ] || { echo "usage: $0 [output-directory]" >&2; exit 2; }
mkdir -p "$ROOT/tmp/releases" "$ROOT/tmp/xcode-derived" "$ROOT/tmp/process"
export TMPDIR="$ROOT/tmp/process/"
OUTPUT="${1:-$(mktemp -d "$ROOT/tmp/releases/archive.XXXXXX")}"
mkdir -p "$OUTPUT"
OUTPUT="$(cd "$OUTPUT" && pwd)"
[ ! -e "$OUTPUT/Consumer" ] && [ ! -e "$OUTPUT/UmbelPlayer" ] || {
  echo "✗ output directory already contains a consumer or package link: $OUTPUT" >&2
  exit 1
}
cp -R "$ROOT/Tools/ArchiveConsumer" "$OUTPUT/Consumer"
ln -s "$ROOT" "$OUTPUT/UmbelPlayer"

# Only this invocation owns WORK. Archives and logs stay in OUTPUT, even
# on failure; the intermediate build data is removed on exit.
WORK="$(mktemp -d "$ROOT/tmp/xcode-derived/archive.XXXXXX")"
finish() {
  local status=$?
  rm -rf "$WORK"
  python3 -B "$ROOT/Tools/clean_builds.py" --check >&2 || true
  exit "$status"
}
trap finish EXIT

archive_one() {
  local platform="$1" destination="$2" archive
  archive="$OUTPUT/$platform.xcarchive"
  echo "Building $platform Release archive: $archive"
  if ! xcodebuild archive \
      -project "$OUTPUT/Consumer/ArchiveConsumer.xcodeproj" \
      -scheme ArchiveConsumer -configuration Release \
      -destination "$destination" -archivePath "$archive" \
      -derivedDataPath "$WORK/DerivedData" \
      CODE_SIGNING_ALLOWED=NO DEBUG_INFORMATION_FORMAT=dwarf-with-dsym \
      >"$OUTPUT/$platform.log" 2>&1; then
    echo "✗ $platform archive failed; build log: $OUTPUT/$platform.log" >&2
    grep -m 8 -E 'error:|fatal error:|\([0-9]+ failures?\)' "$OUTPUT/$platform.log" | cut -c 1-300 >&2 || true
    return 1
  fi
  local name
  for name in UmbelCore UmbelFFmpeg UmbelASS UmbelFriBidi; do
    if ! find "$archive/Products/Applications" -type d -name "$name.framework" -print -quit | grep -q .; then
      echo "✗ $platform archive does not embed $name.framework" >&2
      return 1
    fi
  done
  "$ROOT/Tools/check_archive_symbols.sh" "$archive"
}

archive_one ios 'generic/platform=iOS'
archive_one macos 'generic/platform=macOS'
echo "✓ Release archives and logs: $OUTPUT"
