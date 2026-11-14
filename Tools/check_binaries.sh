#!/bin/bash
# Checks a built xcframework is fit to hand to an app: for each slice, the
# binary is where its install name says, exports only its own names, has a
# dSYM of the same UUID with debug information in it, names no local path,
# and carries an Info.plist and a privacy manifest.
#
# Usage:
#   check_binaries.sh <xcframework> <extended regex of exported names>
#   check_binaries.sh --all <Binaries directory>
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=framework.sh
source "$HERE/framework.sh"

# Where a local build would leave its traces: the directory the home
# directories are in, or macOS's temporary and private ones.
LOCAL_PATH="(${HOME%/*}/|/private/|/var/folders/)"
FAIL=0
fail() { echo "✗ $1" >&2; FAIL=1; }

# How many lines of standard input match: read to the end, never stopping at
# the first match as grep -q does — under pipefail that makes the command
# writing into the pipe fail, and a check reads it the wrong way round.
matches() { grep -cE "$1" || true; }

# The architectures of a binary whose __debug_info section is not empty, one
# to a line: read from the load commands, which takes no time where dumping
# a real library's debug information takes a minute.
debug_info_archs() {
  otool -l "$1" | awk '
    /\(architecture / { arch = $NF; sub(/\):$/, "", arch) }
    /sectname __debug_info$/ { want = 1; next }
    want && $1 == "size" { if ($2 !~ /^0x0+$/) print (arch == "" ? "single" : arch); want = 0 }
  ' | sort -u
}

# One "UUID (architecture)" to a line.
uuids() { dwarfdump --uuid "$1" 2>/dev/null | awk '{print $2 " " $3}' | sort; }

check_slice() {
  local slice="$1" name="$2" pattern="$3"
  local framework="$slice/$name.framework" platform=ios
  [ -d "$framework/Versions/A" ] && platform=macos
  local inside binary plist privacy
  inside="$(framework_binary_path "$name" "$platform")"
  binary="$slice/$inside"
  if [ "$platform" = macos ]; then
    plist="$framework/Versions/A/Resources/Info.plist"
    privacy="$framework/Versions/A/Resources/PrivacyInfo.xcprivacy"
  else
    plist="$framework/Info.plist"
    privacy="$framework/PrivacyInfo.xcprivacy"
  fi
  [ -f "$binary" ] || { fail "$slice: no binary $inside"; return; }
  [ "$(otool -D "$binary" | tail -n 1)" = "@rpath/$inside" ] || fail "$binary: install name is not @rpath/$inside"
  local stray
  stray="$(nm -gUj "$binary" 2>/dev/null | sort -u | grep -vE "$pattern" | head -3)"
  [ -z "$stray" ] || fail "$binary exports names outside $pattern: $(echo "$stray" | tr '\n' ' ')"
  local dsym="$slice/dSYMs/$name.framework.dSYM"
  if [ ! -d "$dsym" ]; then
    fail "$slice: no dSYMs/$name.framework.dSYM"
  else
    [ "$(uuids "$binary")" = "$(uuids "$dsym")" ] || fail "$dsym: UUIDs differ from the binary's"
    local dwarf archs
    dwarf="$dsym/Contents/Resources/DWARF/$name"
    archs="$(lipo -archs "$binary" 2>/dev/null | tr ' ' '\n' | grep -c .)"
    [ "$(debug_info_archs "$dwarf" | grep -c .)" -eq "$archs" ] \
      || fail "$dsym holds no debug information for every architecture"
    # Directory and file names are strings in the DWARF sections.
    [ "$(strings -a "$dwarf" | matches "$LOCAL_PATH")" -eq 0 ] || fail "$dsym names a local path"
  fi
  [ "$(strings "$binary" | matches "$LOCAL_PATH")" -eq 0 ] || fail "$binary names a local path"
  # What it loads: the system's, or the project's own through @rpath. Anything
  # else is a library the app's machines may not have.
  local dep
  while IFS= read -r dep; do
    case "$dep" in
      /System/Library/*|/usr/lib/*|@rpath/Umbel*) ;;
      *) fail "$binary loads what is neither the system's nor the project's: $dep" ;;
    esac
  done < <(otool -L "$binary" | awk '/^\t/ {print $1}' | sort -u)
  local key
  for key in CFBundleIdentifier CFBundleShortVersionString CFBundleExecutable; do
    /usr/libexec/PlistBuddy -c "Print :$key" "$plist" >/dev/null 2>&1 || fail "$plist: no $key"
  done
  [ -f "$privacy" ] || fail "$framework: no PrivacyInfo.xcprivacy"
}

check_xcframework() {
  local xcf="$1" pattern="$2" name slice found=false
  name="$(basename "$xcf" .xcframework)"
  [ -d "$xcf" ] || { fail "no $xcf"; return; }
  for slice in "$xcf"/*/; do
    [ -d "$slice/$name.framework" ] || continue
    found=true
    check_slice "${slice%/}" "$name" "$pattern"
  done
  $found || fail "$xcf has no slices"
}

if [ "${1:-}" = "--all" ]; then
  dir="${2:?usage: $0 --all <Binaries directory>}"
  check_xcframework "$dir/UmbelFFmpeg.xcframework" '^_(av|avcodec|avformat|avio|avutil|avsubtitle|swr|swresample|sws|swscale)_'
  check_xcframework "$dir/UmbelASS.xcframework" '^_ass_'
  check_xcframework "$dir/UmbelFriBidi.xcframework" '^_fribidi_'
  # The optional network libraries, where they have been built.
  [ -d "$dir/UmbelSRT.xcframework" ] && check_xcframework "$dir/UmbelSRT.xcframework" '^_srt_'
  [ -d "$dir/UmbelSSH2.xcframework" ] && check_xcframework "$dir/UmbelSSH2.xcframework" '^_libssh2_'
  [ -d "$dir/UmbelRIST.xcframework" ] && check_xcframework "$dir/UmbelRIST.xcframework" '^_rist_'
  [ -d "$dir/UmbelSMB2.xcframework" ] && check_xcframework "$dir/UmbelSMB2.xcframework" '^_smb2_'
  [ -d "$dir/UmbelNFS.xcframework" ] && check_xcframework "$dir/UmbelNFS.xcframework" '^_nfs_'
else
  check_xcframework "${1:?usage: $0 <xcframework> <pattern> | --all <directory>}" "${2:?pattern}"
fi
[ "$FAIL" -eq 0 ] && echo "✓ binaries check passed"
exit $FAIL
