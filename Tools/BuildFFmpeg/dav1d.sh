#!/bin/bash
# Sourced by build.sh. BSD-2-Clause dav1d is static inside UmbelFFmpeg;
# none of its symbols enter the framework's public export list.

read -r DAV1D_VERSION DAV1D_SHA256 DAV1D_URL < "$HERE/DAV1D_VERSION"
DAV1D_SRC="$HERE/sources/dav1d-$DAV1D_VERSION"

fetch_dav1d() {
  local archive="$HERE/sources/dav1d-$DAV1D_VERSION.tar.xz"
  mkdir -p "$HERE/sources"
  if [ ! -f "$archive" ]; then
    curl -fLsS "$DAV1D_URL" -o "$archive.download"
    mv "$archive.download" "$archive"
  fi
  echo "$DAV1D_SHA256  $archive" | shasum -a 256 -c - >/dev/null \
    || { echo "✗ dav1d source checksum failed" >&2; exit 1; }
  [ -d "$DAV1D_SRC" ] || tar -xf "$archive" -C "$HERE/sources"
  cmp "$DAV1D_SRC/COPYING" "$ROOT/Sources/UmbelCore/Notices/Texts/dav1d.txt" \
    || { echo "✗ bundled dav1d license differs from upstream" >&2; exit 1; }
}

build_dav1d() {
  local name="$1" sdk_path="$2" arch="$3" min_flag="$4"
  local work="$BUILD/dav1d-work-$name-$arch"
  local prefix="$BUILD/dav1d-$arch-$name"
  local cross="$BUILD/dav1d-cross-$name-$arch.txt" family subsystem
  [ "$arch" = arm64 ] && family=aarch64 || family=x86_64
  case "$name" in ios) subsystem=ios ;; iossim) subsystem=ios-simulator ;; *) subsystem=macos ;; esac
  rm -rf "$work" "$prefix"
  local flags="'-arch', '$arch', '-isysroot', '$sdk_path', '$min_flag'"
  cat > "$cross" <<CROSS
[binaries]
c = '$(xcrun -find clang)'
ar = '$(xcrun -find ar)'
strip = '$(xcrun -find strip)'
pkg-config = 'pkg-config'

[built-in options]
c_args = [$flags, '-g', '-ffile-prefix-map=$ROOT=/umbel/root']
c_link_args = [$flags]

[properties]
needs_exe_wrapper = true

[host_machine]
system = 'darwin'
subsystem = '$subsystem'
kernel = 'xnu'
cpu_family = '$family'
cpu = '$arch'
endian = 'little'
CROSS
  PKG_CONFIG_LIBDIR="" PKG_CONFIG_PATH="" meson setup "$work" "$DAV1D_SRC" \
    --cross-file "$cross" --prefix /umbel --libdir lib --buildtype release \
    --default-library static -Db_staticpic=true -Db_ndebug=true \
    -Dbitdepths=8,16 -Denable_asm=true -Denable_tools=false -Denable_tests=false \
    -Denable_examples=false -Denable_docs=false -Dxxhash_muxer=disabled
  ninja -C "$work"
  DESTDIR="$prefix" meson install -C "$work"
}
