#!/bin/bash
# FFmpeg license guard, static: see the licensing rules in AGENTS.md.
#
# Usage: Tools/verify_ffmpeg_license.sh <directory holding config.h>
#        Tools/verify_ffmpeg_license.sh --binary <built binary>
#        Tools/verify_ffmpeg_license.sh --binaries <Binaries directory>
#
# Checks the license macros of an FFmpeg build. CONFIG_GPL or CONFIG_NONFREE
# at 1 would keep this project from being distributed closed-source, so both
# are refused. A missing config.h is refused too: compliance that cannot be
# shown is not compliance, and nothing passes silently.
#
# Write ${VAR} whenever a variable is followed by non-ASCII text: the bash
# 3.2 that macOS ships takes the first byte of a multibyte character into the
# name, and with set -u that is fatal.
set -uo pipefail

# A built binary: FFmpeg keeps its license string and its configure line in
# it. For CI, where the binaries come from a cache and skipped the check made
# while building them.
check_binary() {
  local bin="$1" config
  [ -f "$bin" ] || { echo "✗ no ${bin}" >&2; return 1; }
  # "libavutil license: LGPL version 2.1 or later", one for each library in
  # it: every one has to say so.
  local licenses
  licenses="$(strings "$bin" | grep -E '^lib[a-z]+ license: ')"
  if [ -z "$licenses" ] || echo "$licenses" | grep -qvE ' license: LGPL version 2\.1 or later$'; then
    echo "✗ ${bin} does not say LGPL version 2.1 or later throughout" >&2
    return 1
  fi
  config="$(strings "$bin" | grep -m 1 -- '--enable-cross-compile')"
  if [ -z "$config" ]; then
    echo "✗ ${bin} carries no configure line to check" >&2
    return 1
  fi
  if echo "$config" | grep -qE -- '--enable-(gpl|nonfree)'; then
    echo "✗ ${bin} was configured with GPL or nonfree parts: not to be released" >&2
    return 1
  fi
  echo "✓ FFmpeg license check passed: ${bin}"
}

case "${1:-}" in
  --binary)
    check_binary "${2:?usage: $0 --binary <binary>}"
    exit $?
    ;;
  --binaries)
    found=false
    for slice in "${2:?usage: $0 --binaries <directory>}"/UmbelFFmpeg.xcframework/*/; do
      bin="${slice}UmbelFFmpeg.framework/UmbelFFmpeg"
      [ -f "$bin" ] || continue
      found=true
      check_binary "$bin" || exit 1
    done
    $found || { echo "✗ no UmbelFFmpeg.xcframework slices under ${2}" >&2; exit 1; }
    exit 0
    ;;
esac

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <directory holding config.h>" >&2
  exit 1
fi

CONFIG_H="$1/config.h"

if [ ! -f "$CONFIG_H" ]; then
  echo "✗ no $CONFIG_H: the license cannot be verified, refused" >&2
  exit 1
fi

read_macro() {
  local name="$1"
  local line
  line=$(grep -E "^#define[[:space:]]+$name[[:space:]]+" "$CONFIG_H" | head -1)
  if [ -z "$line" ]; then
    echo "missing"
    return
  fi
  echo "$line" | awk '{print $3}'
}

GPL=$(read_macro CONFIG_GPL)
NONFREE=$(read_macro CONFIG_NONFREE)
FAIL=0

if [ "$GPL" != "0" ]; then
  echo "✗ CONFIG_GPL = ${GPL} (must be 0). Do not build with --enable-gpl." >&2
  FAIL=1
fi

if [ "$NONFREE" != "0" ]; then
  echo "✗ CONFIG_NONFREE = ${NONFREE} (must be 0). Do not build with --enable-nonfree." >&2
  FAIL=1
fi

if [ "$FAIL" -ne 0 ]; then
  echo "✗ FFmpeg license check failed: not to be released." >&2
  exit 1
fi

echo "✓ FFmpeg license check passed (CONFIG_GPL=0, CONFIG_NONFREE=0)"
exit 0
