#!/bin/bash
# Checks how the optional network libraries are linked.
#
# Usage:
#   verify_network_libraries.sh <binary>...                 # built binaries
#   verify_network_libraries.sh --binaries <Binaries directory>   # each slice of each one built
#
# The second is for CI: restored from cache, the binaries skipped the check
# made while building them, and still have to be checked. A machine that has
# built none of them has nothing to check, and passes.
#
# For each binary:
#   1. It is a dynamic library, loaded by its own place in its framework,
#      @rpath/Umbel<Name>.framework/…: the name is the project's, so that
#      another copy of the library in an app cannot meet it.
#   2. It depends on the system's libraries and on nothing else. What it
#      links of other people's — OpenSSL — is in it statically, and a library
#      under the LGPL is a dynamic library of its own that nothing else here
#      links, so that it can be replaced and relinked. No absolute path into
#      a build directory or Homebrew is left.
set -euo pipefail

fail() { echo "✗ network libraries check failed: $1" >&2; exit 1; }

# The optional libraries, by the name of the xcframework.
OPTIONAL=(UmbelSRT UmbelSSH2 UmbelRIST UmbelSMB2 UmbelNFS)

# Dependency lines are the indented ones. A universal binary prints one header
# line per architecture; those are not dependencies.
deps() { otool -L "$1" | awk '/^\t/ {print $1}' | sort -u; }

allowed_system() {
  case "$1" in
    /usr/lib/*|/System/Library/*) return 0 ;;
    *) return 1 ;;
  esac
}

check_binary() {
  local binary="$1"
  [ -f "$binary" ] || fail "no $binary"
  file "$binary" | grep -q "dynamically linked shared library" || fail "$binary is not a dynamic library"
  local own
  own="$(otool -D "$binary" | tail -n 1)"
  case "$own" in
    @rpath/Umbel*.framework/*) ;;
    *) fail "$binary: install name is not @rpath/Umbel<Name>.framework/…: $own" ;;
  esac
  local dep
  while IFS= read -r dep; do
    # A library lists itself first.
    [ "$dep" = "$own" ] && continue
    allowed_system "$dep" || fail "$binary depends on what it may not: $dep"
  done < <(deps "$binary")
  echo "✓ network libraries check passed: $binary"
}

if [ "${1:-}" = "--binaries" ]; then
  binaries="${2:?usage: verify_network_libraries.sh --binaries <directory>}"
  for name in "${OPTIONAL[@]}"; do
    [ -d "$binaries/$name.xcframework" ] || continue
    for slice in "$binaries/$name.xcframework"/*/; do
      # A framework's top-level binary; on macOS a link into Versions/A.
      [ -f "$slice/$name.framework/$name" ] || continue
      check_binary "$slice/$name.framework/$name"
    done
  done
  exit 0
fi

[ "$#" -gt 0 ] || { echo "usage: verify_network_libraries.sh <binary>... | --binaries <directory>" >&2; exit 1; }
for binary in "$@"; do check_binary "$binary"; done
