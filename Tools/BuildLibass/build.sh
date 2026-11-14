#!/bin/bash
# Builds libass and its dependencies from pinned sources into two xcframeworks
# under Binaries/, named as the project's own so that another copy of libass
# or FriBidi in an app cannot meet them: UmbelASS and UmbelFriBidi. Each
# component is built static, then linked into a dynamic library exporting its
# own interface only (Tools/link_dylib.sh), its debug information in a dSYM.
# The module `import LibASS` finds is declared in the package, Sources/LibASS.
#
# Licensing (the licensing rules in AGENTS.md):
#   - FriBidi is LGPL-2.1+: a dynamic library of its own (UmbelFriBidi), as
#     FFmpeg is.
#   - FreeType (under the FTL) and HarfBuzz (MIT) are permissive, linked into
#     UmbelASS statically.
#   - libass (ISC) is the dynamic library UmbelASS.
#   - No fontconfig: CoreText provides the fonts.
# Tools/verify_libass_license.sh then checks the linkage; anything out of line
# stops the build.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SOURCES="$HERE/sources"
BUILD="$ROOT/tmp/libass-build"
OUT="$ROOT/Binaries"

# shellcheck source=../framework.sh
source "$ROOT/Tools/framework.sh"
# shellcheck source=../link_dylib.sh
source "$ROOT/Tools/link_dylib.sh"

# The same platforms as Tools/BuildFFmpeg/build.sh: name|SDK|architecture|minimum version flag|meson subsystem
PLATFORMS=(
  "ios|iphoneos|arm64|-mios-version-min=15.0|ios"
  "iossim|iphonesimulator|arm64,x86_64|-mios-simulator-version-min=15.0|ios-simulator"
  "macos|macosx|arm64,x86_64|-mmacosx-version-min=12.0|macos"
)

# A line of VERSIONS: name version SHA256 URL. The bash 3.2 macOS ships has no
# associative arrays, so fields are looked up by name.
field() { awk -v name="$1" -v col="$2" '$1 == name { print $col }' "$HERE/VERSIONS"; }
version_of() { field "$1" 2; }
sha_of() { field "$1" 3; }
url_of() { field "$1" 4; }

src_dir() { echo "$SOURCES/$1-$(version_of "$1")"; }

fetch_sources() {
  mkdir -p "$SOURCES"
  local name tarball
  for name in fribidi freetype harfbuzz libass; do
    tarball="$SOURCES/$(basename "$(url_of "$name")")"
    if [ ! -f "$tarball" ]; then
      echo "==> downloading $name $(version_of "$name")"
      curl -sSLf -o "$tarball" "$(url_of "$name")"
    fi
    # Checked every time, not only on download: an old archive left behind
    # can be wrong too.
    echo "$(sha_of "$name")  $tarball" | shasum -a 256 -c - >/dev/null \
      || { echo "✗ $name source archive failed its checksum: $tarball" >&2; exit 1; }
    [ -d "$(src_dir "$name")" ] || tar -xf "$tarball" -C "$SOURCES"
  done
}

# meson's cross-compilation description. The link arguments leave room in
# the headers for the longer install names the frameworks need, rewritten
# after the build.
#
# HarfBuzz is C++, but its default build needs no C++ standard library (no
# exceptions, RTTI or libstdc++), so linked into libass it needs no libc++.
write_cross_file() {
  local file="$1" sdk="$2" arch="$3" min_flag="$4" subsystem="$5"
  local sdk_path cpu_family
  sdk_path="$(xcrun --sdk "$sdk" --show-sdk-path)"
  [ "$arch" = arm64 ] && cpu_family=aarch64 || cpu_family=x86_64
  local flags="'-arch', '$arch', '-isysroot', '$sdk_path', '$min_flag'"
  # Debug information for the dSYMs, its paths made to name no local directory.
  local debug="'-g', '-ffile-prefix-map=$HERE=/umbel/libass', '-ffile-prefix-map=$BUILD=/umbel/libass-build'"
  cat > "$file" <<CROSS
[binaries]
c = '$(xcrun -find clang)'
cpp = '$(xcrun -find clang++)'
objc = '$(xcrun -find clang)'
ar = '$(xcrun -find ar)'
strip = '$(xcrun -find strip)'
pkg-config = 'pkg-config'

[built-in options]
c_args = [$flags, $debug]
cpp_args = [$flags, $debug]
objc_args = [$flags, $debug]
c_link_args = [$flags, '-Wl,-headerpad_max_install_names']
cpp_link_args = [$flags, '-Wl,-headerpad_max_install_names']

[properties]
needs_exe_wrapper = true

[host_machine]
system = 'darwin'
subsystem = '$subsystem'
kernel = 'xnu'
cpu_family = '$cpu_family'
cpu = '$arch'
endian = 'little'
CROSS
}

# pkg-config sees this slice's libraries only, not same-named ones from Homebrew.
meson_build() {
  local name="$1" prefix="$2" cross="$3"; shift 3
  local work="$BUILD/work-$(basename "$prefix")-$name"
  rm -rf "$work"
  PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig" PKG_CONFIG_PATH="" \
    meson setup "$work" "$(src_dir "$name")" \
      --cross-file "$cross" --prefix "$prefix" --libdir lib \
      --buildtype release -Db_ndebug=true "$@" >/dev/null
  ninja -C "$work" >/dev/null
  meson install -C "$work" >/dev/null
}

build_slice() {
  local name="$1" sdk="$2" arch="$3" min_flag="$4" subsystem="$5"
  local prefix="$BUILD/$arch-$name"
  echo "==> building $name / $arch"
  rm -rf "$prefix"
  mkdir -p "$prefix"

  local cross="$BUILD/cross-$name-$arch.txt"
  write_cross_file "$cross" "$sdk" "$arch" "$min_flag" "$subsystem"

  meson_build fribidi "$prefix" "$cross" \
    --default-library static -Ddocs=false -Dbin=false -Dtests=false

  meson_build freetype "$prefix" "$cross" \
    --default-library static -Dzlib=system -Dbzip2=disabled -Dpng=disabled \
    -Dharfbuzz=disabled -Dbrotli=disabled -Dtests=disabled

  # HarfBuzz for its shaping core only; everything else off, so no other
  # library is linked in unnoticed.
  local hb_off=()
  local feature
  for feature in glib gobject cairo chafa png zlib icu graphite graphite2 freetype \
                 fontations gdi directwrite coretext harfrust kbts wasm raster vector \
                 gpu gpu_demo subset tests introspection docs utilities benchmark; do
    hb_off+=("-D$feature=disabled")
  done
  meson_build harfbuzz "$prefix" "$cross" --default-library static "${hb_off[@]}"

  meson_build libass "$prefix" "$cross" \
    --default-library static -Dfontconfig=disabled -Ddirectwrite=disabled \
    -Dcoretext=enabled -Dlibunibreak=disabled -Dasm=enabled -Dtest=disabled \
    -Dcompare=disabled -Dprofile=disabled -Dfuzz=disabled -Dcheckasm=disabled

  local sdk_path
  sdk_path="$(xcrun --sdk "$sdk" --show-sdk-path)"
  # FriBidi on its own: LGPL, so a library that can be replaced and relinked.
  export_list "$prefix/fribidi-exports.txt" '^_fribidi_' "$prefix/lib/libfribidi.a"
  link_dylib "$prefix/UmbelFriBidi" "@rpath/$(framework_binary_path UmbelFriBidi "$name")" \
    "$(version_of fribidi)" "$prefix/fribidi-exports.txt" "$arch" "$sdk_path" "$min_flag" \
    "$prefix/lib/libfribidi.a"
  # libass with FreeType and HarfBuzz in it, loading FriBidi through @rpath:
  # the FriBidi dylib is linked against, and its install name is what
  # UmbelASS will look for. The rest of what libass needs, pkg-config says.
  export_list "$prefix/ass-exports.txt" '^_ass_' "$prefix/lib/libass.a"
  local private=() flag
  while IFS= read -r flag; do private+=("$flag"); done < <(
    PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig" PKG_CONFIG_PATH="" \
      pkg-config --static --libs libass | tr ' ' '\n' \
        | grep -vE '^-L|^-l(ass|fribidi|freetype|harfbuzz)$|^$')
  link_dylib "$prefix/UmbelASS" "@rpath/$(framework_binary_path UmbelASS "$name")" \
    "$(version_of libass)" "$prefix/ass-exports.txt" "$arch" "$sdk_path" "$min_flag" \
    "$prefix/lib/libass.a" "$prefix/lib/libfreetype.a" "$prefix/lib/libharfbuzz.a" \
    "$prefix/UmbelFriBidi" ${private[@]+"${private[@]}"}
}

merge_platform() {
  local name="$1" archs="$2" min_flag="$3"
  local merged="$BUILD/merged-$name"
  rm -rf "$merged"
  mkdir -p "$merged/lib" "$merged/include" "$merged/frameworks"

  IFS=',' read -ra arch_list <<< "$archs"
  cp -R "$BUILD/${arch_list[0]}-$name/include/ass" "$merged/include/"

  local lib a inputs
  for lib in UmbelASS UmbelFriBidi; do
    inputs=()
    for a in "${arch_list[@]}"; do inputs+=("$BUILD/$a-$name/$lib"); done
    if [ "${#inputs[@]}" -eq 1 ]; then
      cp "${inputs[0]}" "$merged/lib/$lib"
    else
      lipo -create "${inputs[@]}" -output "$merged/lib/$lib"
    fi
    # While the object files it points at are still here.
    split_debug "$merged/lib/$lib" "$merged/$lib.framework.dSYM"
  done
  "$ROOT/Tools/verify_libass_license.sh" "$merged/lib/UmbelASS" "$merged/lib/UmbelFriBidi"
  # libass's headers, included as <UmbelASS/ass.h>; they include each other
  # by bare name, so nothing is rewritten.
  make_framework "$name" UmbelASS "$(version_of libass)" "${min_flag#*=}" \
    "$merged/lib/UmbelASS" "$merged/include/ass" "$merged/frameworks" "$HERE/PrivacyInfo.xcprivacy"
  make_framework "$name" UmbelFriBidi "$(version_of fribidi)" "${min_flag#*=}" \
    "$merged/lib/UmbelFriBidi" - "$merged/frameworks" "$HERE/PrivacyInfo-FriBidi.xcprivacy"
}

main() {
  for tool in meson ninja pkg-config nasm; do
    command -v "$tool" >/dev/null || { echo "✗ $tool missing: brew install $tool" >&2; exit 1; }
  done
  fetch_sources
  mkdir -p "$BUILD" "$OUT"

  local entry name sdk archs min_flag subsystem arch merged_dirs=()
  for entry in "${PLATFORMS[@]}"; do
    IFS='|' read -r name sdk archs min_flag subsystem <<< "$entry"
    IFS=',' read -ra arch_list <<< "$archs"
    for arch in "${arch_list[@]}"; do
      build_slice "$name" "$sdk" "$arch" "$min_flag" "$subsystem"
    done
    merge_platform "$name" "$archs" "$min_flag"
    merged_dirs+=("$BUILD/merged-$name")
  done

  local lib merged xcf_args
  # The upstream-named xcframeworks, from before the rename.
  rm -rf "$OUT/libass.xcframework" "$OUT/libfribidi.xcframework"
  for lib in UmbelASS UmbelFriBidi; do
    echo "==> assembling $lib.xcframework"
    xcf_args=()
    for merged in "${merged_dirs[@]}"; do
      xcf_args+=(-framework "$merged/frameworks/$lib.framework" -debug-symbols "$merged/$lib.framework.dSYM")
    done
    rm -rf "$OUT/$lib.xcframework"
    xcodebuild -create-xcframework "${xcf_args[@]}" -output "$OUT/$lib.xcframework" >/dev/null
  done
  echo "✓ libass $(version_of libass) built: $OUT/UmbelASS.xcframework, $OUT/UmbelFriBidi.xcframework"
}

main "$@"
python3 -B "$ROOT/Tools/clean_builds.py" --check || true
