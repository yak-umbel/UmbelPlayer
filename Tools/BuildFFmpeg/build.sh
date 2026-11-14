#!/bin/bash
# Builds FFmpeg in its LGPL configuration into Binaries/UmbelFFmpeg.xcframework:
# the five libraries built static, then linked into one dynamic library under
# the project's own name, exporting FFmpeg's public interface only, with its
# debug information in a dSYM beside it. Its headers are in the framework, a
# directory to a library, their includes of one another made relative
# (Tools/framework.sh says why); the module `import FFmpeg` finds is declared
# in the package, Sources/FFmpeg.
#
# Licensing (the licensing rules in AGENTS.md):
#   - no --enable-gpl
#   - no --enable-nonfree
#   - none of the GPL components: libx264, libx265, libxvid, postproc
#   - one dynamic library, UmbelFFmpeg, made of the five static ones: still
#     a library of its own that can be replaced and relinked, as LGPL §6 asks;
#     linking FFmpeg statically into an app would instead oblige handing over
#     the app's object files.
# As soon as configure writes config.h, Tools/verify_ffmpeg_license.sh checks
# it, so a build out of line wastes no time compiling.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
VERSION="$(cat "$HERE/FFMPEG_VERSION")"
SRC="$HERE/sources/ffmpeg-$VERSION"
BUILD="$ROOT/tmp/ffmpeg-build"
OUT="$ROOT/Binaries"

# shellcheck source=../framework.sh
source "$ROOT/Tools/framework.sh"
# shellcheck source=../link_dylib.sh
source "$ROOT/Tools/link_dylib.sh"
# shellcheck source=dav1d.sh
source "$HERE/dav1d.sh"

LIBS=(libavcodec libavformat libavutil libswresample libswscale)
NAME=UmbelFFmpeg
# FFmpeg's public names; its internal ff_ and avpriv_ ones stay inside.
EXPORTS='^_(av|avcodec|avformat|avio|avutil|avsubtitle|swr|swresample|sws|swscale)_'
PRIVACY="$HERE/PrivacyInfo.xcprivacy"
# Without autodetection configure looks for iconv in the C library alone, as
# on Linux; Apple's is libiconv. Given to configure, which does not write it
# into the pkg-config files, so given to the link here as well.
EXTRA_LIBS=-liconv

# Platforms: name|SDK|architectures (comma separated)|minimum version flag
# tvOS, visionOS and Mac Catalyst come in a later milestone, not here.
PLATFORMS=(
  "ios|iphoneos|arm64|-mios-version-min=15.0"
  "iossim|iphonesimulator|arm64,x86_64|-mios-simulator-version-min=15.0"
  "macos|macosx|arm64,x86_64|-mmacosx-version-min=12.0"
)

fetch_source() {
  if [ -d "$SRC" ]; then
    echo "==> sources already present: $SRC"
    return
  fi
  echo "==> fetching FFmpeg $VERSION"
  mkdir -p "$HERE/sources"
  git clone --depth 1 --branch "$VERSION" \
    https://github.com/FFmpeg/FFmpeg.git "$SRC"
}

configure_flags() {
  local arch="$1" sdk_path="$2" min_flag="$3" target_os="$4"
  # GPL and nonfree are off by default in FFmpeg. Their enable flags are not
  # passed here, and verify_ffmpeg_license.sh checks the build afterwards,
  # rather than relying on remembering not to pass them.
  # A prefix that names no local directory: configure's line is kept in the
  # binary. The build installs under DESTDIR instead.
  echo "--prefix=/umbel"
  echo "--enable-cross-compile"
  echo "--target-os=darwin"
  echo "--arch=$arch"
  echo "--sysroot=$sdk_path"
  echo "--cc=$(xcrun -find clang)"
  echo "--enable-static"
  echo "--disable-shared"
  echo "--disable-programs"
  echo "--disable-doc"
  echo "--disable-htmlpages"
  echo "--disable-manpages"
  echo "--disable-podpages"
  echo "--disable-txtpages"
  # No --disable-postproc: libpostproc, FFmpeg's only GPL-only library, was
  # removed upstream in FFmpeg 9 and configure no longer knows the option.
  # Do not add it back.
  echo "--disable-avdevice"
  echo "--disable-avfilter"
  # Nothing found on the build machine by chance: configure looks for
  # libraries it knows wherever they are installed, and on a Mac with X11,
  # xcb or SDL from a package manager it linked them in — a dependency the
  # binary then needs on every machine. What is used is named instead: the
  # system's zlib, bzip2, iconv and TLS, and its hardware decoders.
  echo "--disable-autodetect"
  echo "--enable-zlib"
  echo "--enable-bzlib"
  echo "--enable-iconv"
  echo "--extra-libs=$EXTRA_LIBS"
  echo "--enable-securetransport"
  echo "--enable-videotoolbox"
  echo "--enable-audiotoolbox"
  echo "--enable-libdav1d"
  echo "--pkg-config=$(command -v pkg-config)"
  echo "--enable-pic"
  echo "--enable-runtime-cpudetect"
  # Debug information for the dSYM, its paths made to name no local
  # directory.
  echo "--extra-cflags=$min_flag -arch $arch -g -ffile-prefix-map=$SRC=/umbel/ffmpeg -ffile-prefix-map=$BUILD=/umbel/build"
  # Room in the headers for the longer install names each binary gets inside
  # its framework, rewritten after the build.
  echo "--extra-ldflags=$min_flag -arch $arch -Wl,-headerpad_max_install_names"
}

build_slice() {
  local name="$1" sdk="$2" arch="$3" min_flag="$4"
  local sdk_path
  sdk_path="$(xcrun --sdk "$sdk" --show-sdk-path)"
  build_dav1d "$name" "$sdk_path" "$arch" "$min_flag"
  local dav1d_prefix="$BUILD/dav1d-$arch-$name"
  local prefix="$BUILD/$arch-$name"

  echo "==> building $name / $arch"
  rm -rf "$prefix"
  mkdir -p "$prefix"

  local workdir="$BUILD/work-$name-$arch"
  rm -rf "$workdir"
  mkdir -p "$workdir"
  pushd "$workdir" >/dev/null

  local flags=()
  while IFS= read -r line; do flags+=("$line"); done < <(
    configure_flags "$arch" "$sdk_path" "$min_flag" "$name"
  )

  PKG_CONFIG_LIBDIR="$dav1d_prefix/umbel/lib/pkgconfig" PKG_CONFIG_PATH="" \
    PKG_CONFIG_SYSROOT_DIR="$dav1d_prefix" "$SRC/configure" "${flags[@]}"

  # configure keeps its own command line in config.h, and the binary keeps it
  # from there (avutil_configuration()): the prefix maps above name the build
  # root, which is replaced so no local directory goes into the binary.
  sed -i '' "s#$ROOT#/umbel/root#g" config.h

  # License guard: config.h is checked as soon as configure writes it, and a
  # failure stops the whole build.
  "$ROOT/Tools/verify_ffmpeg_license.sh" "$workdir"

  make -j"$(sysctl -n hw.ncpu)"
  make install DESTDIR="$prefix"
  popd >/dev/null

  # This architecture's one dynamic library, from the five static ones.
  local root="$prefix/umbel" libs=() lib flag private=()
  for lib in "${LIBS[@]}"; do libs+=("$root/lib/$lib.a"); done
  export_list "$prefix/exports.txt" "$EXPORTS" "${libs[@]}"
  libs+=("$dav1d_prefix/umbel/lib/libdav1d.a")
  while IFS= read -r flag; do private+=("$flag"); done < <(private_link_flags "$root/lib/pkgconfig")
  link_dylib "$prefix/$NAME" "@rpath/$(framework_binary_path "$NAME" "$name")" "${VERSION#n}" \
    "$prefix/exports.txt" "$arch" "$sdk_path" "$min_flag" "${libs[@]}" ${private[@]+"${private[@]}"} $EXTRA_LIBS
}

# What the static libraries link against, as their pkg-config files say:
# system libraries and frameworks, in order, each once. A static build puts
# them on the Libs line, a shared one on Libs.private; both are read. FFmpeg's
# own libraries are left out — they are linked in whole.
private_link_flags() {
  local dir="$1"
  sed -nE 's/^Libs(\.private)?: //p' "$dir"/*.pc | tr ' ' '\n' | awk '
    $0 == "" { next }
    pending { key = "-framework " $0; if (!(key in seen)) { seen[key] = 1; print "-framework"; print $0 } pending = 0; next }
    $0 == "-framework" { pending = 1; next }
    $0 ~ /^-l(av|sw)/ { next }
    $0 == "-ldav1d" { next }
    $0 ~ /^-L/ { next }
    !($0 in seen) { seen[$0] = 1; print $0 }
  '
}

lipo_arch_group() {
  local name="$1" archs="$2" min_flag="$3"
  local merged="$BUILD/merged-$name"
  rm -rf "$merged"
  mkdir -p "$merged/lib" "$merged/include" "$merged/frameworks"

  IFS=',' read -ra arch_list <<< "$archs"
  local first="${arch_list[0]}"
  # The five libraries install into one prefix, so this include directory holds
  # the whole header tree, a directory to a library.
  cp -R "$BUILD/$first-$name/umbel/include/." "$merged/include/"

  local a inputs=()
  for a in "${arch_list[@]}"; do inputs+=("$BUILD/$a-$name/$NAME"); done
  if [ "${#inputs[@]}" -eq 1 ]; then
    cp "${inputs[0]}" "$merged/lib/$NAME"
  else
    lipo -create "${inputs[@]}" -output "$merged/lib/$NAME"
  fi

  # While the object files it points at are still here.
  split_debug "$merged/lib/$NAME" "$merged/$NAME.framework.dSYM"
  rewrite_includes "$merged/include" "${LIBS[@]}"
  make_framework "$name" "$NAME" "${VERSION#n}" "${min_flag#*=}" \
    "$merged/lib/$NAME" "$merged/include" "$merged/frameworks" "$PRIVACY"
}

main() {
  for tool in meson ninja pkg-config nasm; do
    command -v "$tool" >/dev/null || { echo "✗ missing build tool: $tool" >&2; exit 1; }
  done
  fetch_source
  fetch_dav1d
  mkdir -p "$BUILD" "$OUT"

  local entry name sdk archs min_flag arch
  local merged_dirs=()
  for entry in "${PLATFORMS[@]}"; do
    IFS='|' read -r name sdk archs min_flag <<< "$entry"
    IFS=',' read -ra arch_list <<< "$archs"
    for arch in "${arch_list[@]}"; do
      build_slice "$name" "$sdk" "$arch" "$min_flag"
    done
    lipo_arch_group "$name" "$archs" "$min_flag"
    merged_dirs+=("$BUILD/merged-$name")
  done

  local lib merged xcf_args=()
  echo "==> assembling $NAME.xcframework"
  for merged in "${merged_dirs[@]}"; do
    xcf_args+=(-framework "$merged/frameworks/$NAME.framework" -debug-symbols "$merged/$NAME.framework.dSYM")
  done
  rm -rf "$OUT/$NAME.xcframework"
  # The five libraries' own xcframeworks, from before they became one.
  for lib in "${LIBS[@]}"; do rm -rf "$OUT/$lib.xcframework"; done
  xcodebuild -create-xcframework "${xcf_args[@]}" -output "$OUT/$NAME.xcframework"

  echo "==> final license check"
  for entry in "${PLATFORMS[@]}"; do
    IFS='|' read -r name _ archs _ <<< "$entry"
    IFS=',' read -ra arch_list <<< "$archs"
    for arch in "${arch_list[@]}"; do
      "$ROOT/Tools/verify_ffmpeg_license.sh" "$BUILD/work-$name-$arch"
    done
  done

  "$ROOT/Tools/verify_ffmpeg_license.sh" --binaries "$OUT"

  echo "✓ FFmpeg $VERSION built: $OUT/$NAME.xcframework"
}

main "$@"
python3 -B "$ROOT/Tools/clean_builds.py" --check || true
