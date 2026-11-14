#!/bin/bash
# Structure guard.
#
# Rule 1: no Swift file longer than MAX_LINES lines
# Rule 2: UmbelCore touches no FFmpeg C symbol (Apple's AVFoundation is not one)
# Rule 3: no mutable global state (stored static var)
# Rule 4: Sources/<target>/<subdirectory>/ has Tests/<target>Tests/<subdirectory>/
# Rule 5: comments in English; Sources, Examples, the package manifest and the
#         repository's settings in English throughout
#
# Write ${VAR} whenever a variable is followed by non-ASCII text: the bash 3.2
# that macOS ships takes the first byte of a multibyte character into the
# name, and with set -u that is fatal.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCES="$ROOT/Sources"
TESTS="$ROOT/Tests"
MAX_LINES=400
FAIL=0

report() {
  echo "✗ $1"
  FAIL=1
}

# ── Rule 1: file length ─────────────────────────────────
if [ -d "$SOURCES" ]; then
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    n=$(wc -l < "$f" | tr -d ' ')
    if [ "$n" -gt "$MAX_LINES" ]; then
      report "file too long: ${f} has ${n} lines, the limit is ${MAX_LINES}. Split it by responsibility. Do not raise the limit, and do not widen private to internal to move code into an extension in another file: that trades encapsulation for line count."
    fi
  done < <(find "$SOURCES" -name '*.swift' 2>/dev/null)
fi

# ── Rule 2: FFmpeg stays behind its boundary ────────────
# FFmpeg's symbols only. AVFoundation's types (AVAudioEngine and the like)
# are legitimate UmbelCore dependencies; a broad AV[A-Z] would catch them.
FFMPEG_PATTERN='^[[:space:]]*import[[:space:]]+FFmpeg|AVFormatContext|AVPacket|AVStream|AVCodec|AVIOContext|AVRational|AVDictionary|AVFrame|AVERROR|\bav_[a-z]|\bavformat_|\bavcodec_|\bavio_'
CORE="$SOURCES/UmbelCore"
if [ -d "$CORE" ]; then
  if hits=$(grep -rInE "$FFMPEG_PATTERN" "$CORE" 2>/dev/null); then
    report "FFmpeg symbols in UmbelCore (FFmpeg types stay inside UmbelFFmpegSupport):"
    echo "$hits" | sed 's/^/    /'
  fi
fi

# ── Rule 3: mutable global state ────────────────────────
# Only a stored static var counts; a computed one is behaviour, not state.
#
# What decides it is whether "{" or "=" comes first after "static var":
#   static var name: String { "x" }   → "{" first: computed, allowed
#   static var counter = 0            → "=" first: stored, refused
#   static var counter: Int           → neither: stored, refused
# "Allowed if the line has a {" would not do: in enum A { static var counter
# = 0 } on one line, the "{" is the enum's, and the real offence slips by.
if [ -d "$SOURCES" ]; then
  hits=$(
    grep -rInE 'static[[:space:]]+var[[:space:]]' "$SOURCES" 2>/dev/null | awk '
      {
        idx = match($0, /static[ \t]+var[ \t]/)
        if (idx == 0) next
        rest = substr($0, idx + RLENGTH)
        eq = index(rest, "=")
        br = index(rest, "{")
        if (br > 0 && (eq == 0 || br < eq)) next
        print
      }
    '
  )
  if [ -n "$hits" ]; then
    report "mutable global state (coupling the compiler cannot see; inject dependencies instead):"
    echo "$hits" | sed 's/^/    /'
  fi
fi

# ── Rule 4: a test directory for each ───────────────────
# Only subdirectories inside a target are held to it, not targets themselves:
# otherwise a target not yet written would trip the guard on day one, and a
# guard that cries wolf ends up loosened or ignored.
#
# `include` is exempt: SwiftPM's directory for a C or Objective-C target's
# public headers holds declarations, not code with tests of its own.
if [ -d "$SOURCES" ]; then
  for target_dir in "$SOURCES"/*/; do
    [ -d "$target_dir" ] || continue
    target="$(basename "$target_dir")"
    for sub_dir in "$target_dir"*/; do
      [ -d "$sub_dir" ] || continue
      sub="$(basename "$sub_dir")"
      [ "$sub" = "include" ] && continue
      expected="$TESTS/${target}Tests/${sub}"
      if [ ! -d "$expected" ]; then
        report "missing test directory: ${sub_dir} needs ${expected}"
      fi
    done
  done
fi

# ── Rule 5: English ─────────────────────────────────────
# Sources and Examples, the package manifest and the repository's settings:
# no Chinese, Japanese or Korean text anywhere — what the library, its
# example and its build say is in English. Tests and Tools: none in comments;
# test data in strings may be in any language.
cjk_rule() {
  local mode="$1" what="$2"; shift 2
  local present=()
  for path in "$@"; do
    [ -e "$path" ] && present+=("$path")
  done
  [ "${#present[@]}" -eq 0 ] && return
  local hits
  if ! hits=$(python3 "$ROOT/Tools/find_cjk.py" "$mode" "${present[@]}"); then
    report "$what"
    echo "$hits" | sed 's/^/    /'
  fi
}
cjk_rule --everywhere "text not in English in Sources or Examples:" "$SOURCES" "$ROOT/Examples"
cjk_rule --everywhere "text not in English in the manifest or the repository's settings:" \
  "$ROOT/Package.swift" "$ROOT/.github" "$ROOT/.gitignore" "$ROOT/Binaries/.gitkeep"
cjk_rule --comments "comments not in English in Tests or Tools:" "$TESTS" "$ROOT/Tools"

if [ "$FAIL" -eq 0 ]; then
  echo "✓ structure check passed"
fi
exit "$FAIL"
