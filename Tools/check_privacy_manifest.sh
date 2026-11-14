#!/bin/bash
# Privacy manifest guard.
#
# Apple asks an app, and each SDK in it, to declare why it uses the system
# interfaces on its "required reason" list. This finds the ones a binary
# imports, or the package's own sources name, and fails when the manifest
# beside them does not declare their category. The list is Apple's, kept
# here as a table; add to it when Apple does.
#
# Usage:
#   check_privacy_manifest.sh --binary <binary> <manifest>
#   check_privacy_manifest.sh --sources <directory> <manifest>
#   check_privacy_manifest.sh --all      # UmbelCore's sources, and every built framework
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Imported C symbols, by category.
binary_category() {
  case "$1" in
    _stat|_fstat|_fstatat|_lstat|_getattrlist|_getattrlistbulk|_fgetattrlist|_getattrlistat) echo FileTimestamp ;;
    _mach_absolute_time) echo SystemBootTime ;;
    _statfs|_statvfs|_fstatfs|_fstatvfs) echo DiskSpace ;;
  esac
}

# Names in Swift sources, by category, as an extended regex each.
SOURCE_PATTERNS=(
  'FileTimestamp|\b(creationDate|modificationDate|fileModificationDate|contentModificationDateKey|creationDateKey)\b'
  'SystemBootTime|\b(systemUptime|mach_absolute_time)\b'
  'DiskSpace|\b(volumeAvailableCapacityKey|volumeAvailableCapacityForImportantUsageKey|volumeAvailableCapacityForOpportunisticUsageKey|volumeTotalCapacityKey|systemFreeSize|systemSize|statfs|statvfs)\b'
  'UserDefaults|\bUserDefaults\b'
  'ActiveKeyboards|\bactiveInputModes\b'
)

declared() {
  grep -o 'NSPrivacyAccessedAPICategory[A-Za-z]*' "$1" | sed 's/NSPrivacyAccessedAPICategory//' | sort -u
}

require() {
  local what="$1" category="$2" manifest="$3"
  if ! declared "$manifest" | grep -qx "$category"; then
    echo "✗ $what uses $category interfaces; $manifest does not declare them" >&2
    return 1
  fi
}

check_manifest_file() {
  [ -f "$1" ] || { echo "✗ no privacy manifest: $1" >&2; return 1; }
  plutil -lint "$1" >/dev/null || { echo "✗ not a valid property list: $1" >&2; return 1; }
}

check_binary() {
  local binary="$1" manifest="$2" status=0 symbol category
  check_manifest_file "$manifest" || return 1
  while IFS= read -r symbol; do
    category="$(binary_category "$symbol")"
    [ -n "$category" ] || continue
    require "$binary ($symbol)" "$category" "$manifest" || status=1
  done < <(nm -uj "$binary" 2>/dev/null | sort -u)
  return $status
}

check_sources() {
  local dir="$1" manifest="$2" status=0 entry category pattern
  check_manifest_file "$manifest" || return 1
  for entry in "${SOURCE_PATTERNS[@]}"; do
    category="${entry%%|*}"
    pattern="${entry#*|}"
    if grep -rqE --include='*.swift' "$pattern" "$dir"; then
      require "$dir" "$category" "$manifest" || status=1
    fi
  done
  return $status
}

check_all() {
  local status=0 slice framework name binary manifest
  check_sources "$ROOT/Sources/UmbelCore" "$ROOT/Sources/UmbelCore/PrivacyInfo.xcprivacy" || status=1
  for slice in "$ROOT"/Binaries/Umbel*.xcframework/*/; do
    for framework in "$slice"*.framework; do
      [ -d "$framework" ] || continue
      name="$(basename "$framework" .framework)"
      if [ -d "$framework/Versions/A" ]; then
        binary="$framework/Versions/A/$name"
        manifest="$framework/Versions/A/Resources/PrivacyInfo.xcprivacy"
      else
        binary="$framework/$name"
        manifest="$framework/PrivacyInfo.xcprivacy"
      fi
      check_binary "$binary" "$manifest" || status=1
    done
  done
  [ "$status" -eq 0 ] && echo "✓ privacy manifests cover what is used"
  return $status
}

case "${1:-}" in
  --binary) check_binary "${2:?binary}" "${3:?manifest}" ;;
  --sources) check_sources "${2:?directory}" "${3:?manifest}" ;;
  --all) check_all ;;
  *) echo "usage: $0 --binary <binary> <manifest> | --sources <directory> <manifest> | --all" >&2; exit 1 ;;
esac
