#!/bin/bash
# Links static libraries into one dynamic library that exports only the
# names a list allows, and parts its debug information into a dSYM.
# Sourced by the build scripts.
#
# One library of our own name, in place of several of the upstream names:
# an app may carry another copy of FFmpeg or libass under those, and two
# frameworks that differ only in case are one path on a Mac's disk. What it
# exports is listed name by name, so internal symbols never show, and no
# wildcard lets one in unnoticed.

# export_list <out> <extended regex> <static library>...
#   The external symbols the libraries define whose names match, sorted, one
#   to a line. Fails when none do: a pattern that matches nothing is a typo.
export_list() {
  local out="$1" pattern="$2"; shift 2
  nm -gUj "$@" 2>/dev/null | grep -E "$pattern" | sort -u > "$out"
  if [ ! -s "$out" ]; then
    echo "✗ no symbol in $* matches $pattern" >&2
    return 1
  fi
}

# link_dylib <out> <install name> <version> <export list> <arch> <sysroot>
#            <minimum version flag> <static library or linker argument>...
#   Each name on the list is required (-u), so the members that define them
#   come in, and what those need after them, as when static libraries are
#   linked into a program. Loading every member instead would fail: FFmpeg
#   compiles some sources into more than one of its libraries. What follows
#   the static libraries names what they link against: -l, -framework, a
#   dylib. Room is left for install names rewritten later.
link_dylib() {
  local out="$1" install="$2" version="$3" exports="$4" arch="$5" sysroot="$6" min_flag="$7"
  shift 7
  local required=() symbol
  while IFS= read -r symbol; do required+=("-Wl,-u,$symbol"); done < "$exports"
  xcrun clang -dynamiclib -arch "$arch" -isysroot "$sysroot" "$min_flag" \
    "${required[@]}" "$@" \
    -install_name "$install" \
    -current_version "$version" -compatibility_version "$version" \
    -Wl,-exported_symbols_list,"$exports" \
    -Wl,-headerpad_max_install_names \
    -o "$out"
}

# split_debug <dylib> <dSYM>
#   The debug information into a dSYM, read from the object files the
#   binary points at, then taken out of the binary. The UUID that ties the
#   two stays; so do the exported symbols.
split_debug() {
  local dylib="$1" dsym="$2"
  rm -rf "$dsym"
  xcrun dsymutil "$dylib" -o "$dsym"
  xcrun strip -S -x "$dylib"
}
