#!/bin/bash
# Builds the C libraries behind the optional network modules from pinned
# sources into xcframeworks under Binaries/, named as the project's own so
# that another copy of a library in an app cannot meet them. Each is built
# static, then linked into a dynamic library exporting its own interface only
# (Tools/link_dylib.sh), its debug information in a dSYM.
#
# Usage: Tools/BuildNetwork/build.sh [module...]     (default: every module)
#   srt   UmbelSRT.xcframework    SRT, MPL-2.0, with OpenSSL (Apache-2.0)
#   sftp  UmbelSSH2.xcframework   libssh2, BSD-3-Clause, with OpenSSL (Apache-2.0)
#   rist  UmbelRIST.xcframework   librist, BSD-2-Clause, with the Mbed TLS (Apache-2.0) its source carries
#   smb   UmbelSMB2.xcframework   libsmb2, LGPL-2.1+, a dynamic library of its own, its cryptography its own
#   nfs   UmbelNFS.xcframework    libnfs, LGPL-2.1+ (its protocol code BSD-2-Clause), a dynamic library of its own
#
# Licensing (the licensing rules in AGENTS.md):
#   - OpenSSL (Apache-2.0), SRT (MPL-2.0), libssh2 (BSD-3-Clause) and librist
#     (BSD-2-Clause) are permissive enough to be linked into the module's own
#     dynamic library; none is modified.
#   - A library under the LGPL is a dynamic library of its own, as FFmpeg and
#     FriBidi are: the obligation to be relinkable is met by that. libsmb2 is
#     one, and nothing else is linked into it; so is libnfs.
# Tools/verify_network_libraries.sh then checks the linkage; anything out of
# line stops the build.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SOURCES="$HERE/sources"
BUILD="$ROOT/tmp/network-build"
OUT="$ROOT/Binaries"

# shellcheck source=../framework.sh
source "$ROOT/Tools/framework.sh"
# shellcheck source=../link_dylib.sh
source "$ROOT/Tools/link_dylib.sh"

# The same platforms as Tools/BuildFFmpeg/build.sh: name|SDK|architecture|minimum version flag
PLATFORMS=(
  "ios|iphoneos|arm64|-mios-version-min=15.0"
  "iossim|iphonesimulator|arm64,x86_64|-mios-simulator-version-min=15.0"
  "macos|macosx|arm64,x86_64|-mmacosx-version-min=12.0"
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
  for name in "$@"; do
    tarball="$SOURCES/$name-$(version_of "$name").tar.gz"
    if [ ! -f "$tarball" ]; then
      echo "==> downloading $name $(version_of "$name")"
      curl -sSLf -o "$tarball" "$(url_of "$name")"
    fi
    # Checked every time, not only on download: an old archive left behind
    # can be wrong too.
    echo "$(sha_of "$name")  $tarball" | shasum -a 256 -c - >/dev/null \
      || { echo "✗ $name source archive failed its checksum: $tarball" >&2; exit 1; }
    # Into a directory of our own naming (archives differ in what they call theirs),
    # complete or not there at all.
    if [ ! -d "$(src_dir "$name")" ]; then
      rm -rf "${SOURCES:?}/$name.partial"
      mkdir -p "$SOURCES/$name.partial"
      tar -xzf "$tarball" -C "$SOURCES/$name.partial" --strip-components=1
      mv "$SOURCES/$name.partial" "$(src_dir "$name")"
    fi
  done
}

# Debug information for the dSYMs, its paths made to name no local directory.
# Given to the compiler through the environment, not as a flag: OpenSSL
# records the flags it was built with in the library, and these name this
# machine's directories.
export CCC_OVERRIDE_OPTIONS="+-ffile-prefix-map=$HERE=/umbel/network +-ffile-prefix-map=$BUILD=/umbel/network-build"
DEBUG_FLAGS=(-g)

jobs() { sysctl -n hw.ncpu; }

# OpenSSL's own target for each slice.
openssl_target() {
  case "$1:$2" in
    ios:arm64) echo ios64-xcrun ;;
    iossim:arm64) echo iossimulator-arm64-xcrun ;;
    iossim:x86_64) echo iossimulator-x86_64-xcrun ;;
    macos:arm64) echo darwin64-arm64-cc ;;
    macos:x86_64) echo darwin64-x86_64-cc ;;
    *) echo "✗ no OpenSSL target for $1 / $2" >&2; return 1 ;;
  esac
}

# OpenSSL for what links it in: static libraries and headers, in the slice's
# prefix. Configured for a prefix that names no real directory, which
# OpenSSL compiles into the library, and installed elsewhere.
build_openssl() {
  local name="$1" arch="$2" min_flag="$3" prefix="$4"
  [ -f "$prefix/lib/libcrypto.a" ] && return 0
  local work="$BUILD/work-$arch-$name-openssl" stage="$BUILD/stage-$arch-$name-openssl"
  rm -rf "${work:?}" "${stage:?}"
  mkdir -p "$work"
  ( cd "$work"
    "$(src_dir openssl)/Configure" "$(openssl_target "$name" "$arch")" \
      no-shared no-tests no-apps no-docs no-module no-dso no-engine no-comp no-ssl3 \
      --prefix=/umbel/net --openssldir=/umbel/net/ssl --libdir=lib \
      "$min_flag" "${DEBUG_FLAGS[@]}" >configure.log 2>&1
    make -j"$(jobs)" build_libs >make.log 2>&1
    make install_dev DESTDIR="$stage" >install.log 2>&1 )
  cp -R "$stage/umbel/net/." "$prefix/"
}

# CMake's cross-compilation arguments for a slice, one to a line.
cmake_platform_args() {
  local name="$1" sdk="$2" arch="$3" min_flag="$4"
  local version="${min_flag#*=}"
  printf '%s\n' "-DCMAKE_OSX_SYSROOT=$(xcrun --sdk "$sdk" --show-sdk-path)" \
    "-DCMAKE_OSX_ARCHITECTURES=$arch" "-DCMAKE_OSX_DEPLOYMENT_TARGET=$version"
  [ "$name" = macos ] || echo "-DCMAKE_SYSTEM_NAME=iOS"
}

build_srt() {
  local name="$1" sdk="$2" arch="$3" min_flag="$4" prefix="$5"
  cmake_build srt "$name" "$sdk" "$arch" "$min_flag" "$prefix" \
    -DENABLE_SHARED=OFF -DENABLE_STATIC=ON -DENABLE_APPS=OFF -DENABLE_UNITTESTS=OFF -DENABLE_EXAMPLES=OFF \
    -DENABLE_ENCRYPTION=ON -DUSE_ENCLIB=openssl-evp -DUSE_OPENSSL_PC=OFF
}

build_libssh2() {
  local name="$1" sdk="$2" arch="$3" min_flag="$4" prefix="$5"
  # No compression: the servers that offer it do not need it, and it would
  # link zlib.
  cmake_build libssh2 "$name" "$sdk" "$arch" "$min_flag" "$prefix" \
    -DBUILD_SHARED_LIBS=OFF -DBUILD_STATIC_LIBS=ON -DBUILD_EXAMPLES=OFF -DBUILD_TESTING=OFF \
    -DCRYPTO_BACKEND=OpenSSL -DENABLE_ZLIB_COMPRESSION=OFF -DCLEAR_MEMORY=ON
}

# librist by Meson, cross-compiled for the slice. Its encryption needs a
# source of random numbers for the keys' nonces, which only Mbed TLS or GnuTLS
# give it: without one the pre-shared key encryption cannot start at all. The
# Mbed TLS (Apache-2.0, of the two licenses it offers) is the copy in librist's
# own source, so there is no other archive to pin, and it is not exported:
# only librist's names go out. lz4 and cJSON are the copies in its source
# (BSD-2-Clause, MIT). No command-line tools, no tests.
build_librist() {
  local name="$1" sdk="$2" arch="$3" min_flag="$4" prefix="$5"
  local work="$BUILD/work-$arch-$name-librist" cross="$BUILD/cross-$arch-$name.ini"
  rm -rf "${work:?}"
  local sdk_path cpu_family flags
  sdk_path="$(xcrun --sdk "$sdk" --show-sdk-path)"
  case "$arch" in arm64) cpu_family=aarch64 ;; x86_64) cpu_family=x86_64 ;; *) echo "✗ no Meson CPU for $arch" >&2; return 1 ;; esac
  flags="'-arch', '$arch', '-isysroot', '$sdk_path', '$min_flag', '-g'"
  cat > "$cross" <<CROSS
[binaries]
c = ['$(xcrun --sdk "$sdk" --find clang)']
ar = '$(xcrun --sdk "$sdk" --find ar)'
strip = '$(xcrun --sdk "$sdk" --find strip)'
pkg-config = '/usr/bin/false'

[built-in options]
c_args = [$flags]
c_link_args = [$flags]

[host_machine]
system = 'darwin'
cpu_family = '$cpu_family'
cpu = '$arch'
endian = 'little'

[properties]
needs_exe_wrapper = true
CROSS
  meson setup "$work" "$(src_dir librist)" --cross-file "$cross" --prefix "$prefix" --buildtype release \
    -Ddefault_library=static -Dbuilt_tools=false -Dtest=false -Dbuiltin_lz4=true -Dbuiltin_cjson=true \
    -Dbuiltin_mbedtls=true -Duse_mbedtls=true -Duse_gnutls=false >"$work.configure.log" 2>&1 \
    || { echo "✗ librist configure failed for $name / $arch; see $work.configure.log" >&2; return 1; }
  meson compile -C "$work" >"$work.build.log" 2>&1 \
    || { echo "✗ librist build failed for $name / $arch; see $work.build.log" >&2; return 1; }
  meson install -C "$work" >/dev/null 2>&1 || { echo "✗ librist install failed for $name / $arch" >&2; return 1; }
  # Built as a library of its own beside librist, which does not carry it.
  cp "$work/contrib/mbedtls/libmbedcrypto.a" "$prefix/lib/" \
    || { echo "✗ librist's Mbed TLS was not built for $name / $arch" >&2; return 1; }
}

# libsmb2: no Kerberos or GSSAPI (the NTLM and guest logins its own code does
# are what is offered), no examples. Its AES, MD4, MD5 and SHA are its own, so
# there is no OpenSSL in it.
build_libsmb2() {
  local name="$1" sdk="$2" arch="$3" min_flag="$4" prefix="$5"
  cmake_build libsmb2 "$name" "$sdk" "$arch" "$min_flag" "$prefix" \
    -DBUILD_SHARED_LIBS=OFF -DENABLE_EXAMPLES=OFF -DENABLE_LIBKRB5=OFF -DENABLE_GSSAPI=OFF
}

# libnfs: NFS version 3 and 4.0 by itself, over TCP, with AUTH_SYS: no
# Kerberos, no TLS (which it has on Linux only), no NFSv4.2, no threads, no
# programs. Which libraries CMake may find is switched off by name, so that a
# GSSAPI or GnuTLS of this machine's — of another architecture — is never found.
# Its protocol code is BSD-2-Clause and the library LGPL-2.1+, in one library.
build_libnfs() {
  local name="$1" sdk="$2" arch="$3" min_flag="$4" prefix="$5"
  cmake_build libnfs "$name" "$sdk" "$arch" "$min_flag" "$prefix" \
    -DBUILD_SHARED_LIBS=OFF -DENABLE_TESTS=OFF -DENABLE_UTILS=OFF -DENABLE_EXAMPLES=OFF -DENABLE_DOCUMENTATION=OFF \
    -DENABLE_MULTITHREADING=OFF -DENABLE_NFS4_2=OFF -DENABLE_TLS=OFF \
    -DCMAKE_DISABLE_FIND_PACKAGE_GSSAPI=ON -DCMAKE_DISABLE_FIND_PACKAGE_GnuTLS=ON
}

# One library by CMake, against the slice's OpenSSL, installed into its prefix.
cmake_build() {
  local lib="$1" name="$2" sdk="$3" arch="$4" min_flag="$5" prefix="$6"; shift 6
  local work="$BUILD/work-$arch-$name-$lib"
  rm -rf "${work:?}"
  local platform=() line
  while IFS= read -r line; do platform+=("$line"); done < <(cmake_platform_args "$name" "$sdk" "$arch" "$min_flag")
  cmake -S "$(src_dir "$lib")" -B "$work" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$prefix" "${platform[@]}" \
    -DCMAKE_FIND_ROOT_PATH="$prefix" -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=BOTH -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=BOTH \
    -DCMAKE_C_FLAGS="${DEBUG_FLAGS[*]}" -DCMAKE_CXX_FLAGS="${DEBUG_FLAGS[*]}" \
    -DOPENSSL_ROOT_DIR="$prefix" -DOPENSSL_USE_STATIC_LIBS=TRUE "$@" >"$work.configure.log" 2>&1 \
    || { echo "✗ $lib configure failed for $name / $arch; see $work.configure.log" >&2; return 1; }
  cmake --build "$work" -j"$(jobs)" >"$work.build.log" 2>&1 \
    || { echo "✗ $lib build failed for $name / $arch; see $work.build.log" >&2; return 1; }
  cmake --install "$work" >/dev/null
}

# What differs between the modules, by name.
module_framework() { case "$1" in srt) echo UmbelSRT ;; sftp) echo UmbelSSH2 ;; rist) echo UmbelRIST ;; smb) echo UmbelSMB2 ;; nfs) echo UmbelNFS ;; esac; }
module_library() { case "$1" in srt) echo srt ;; sftp) echo libssh2 ;; rist) echo librist ;; smb) echo libsmb2 ;; nfs) echo libnfs ;; esac; }
module_pattern() { case "$1" in srt) echo '^_srt_' ;; sftp) echo '^_libssh2_' ;; rist) echo '^_rist_' ;; smb) echo '^_smb2_' ;; nfs) echo '^_nfs_' ;; esac; }
module_privacy() { case "$1" in srt) echo PrivacyInfo-SRT.xcprivacy ;; sftp) echo PrivacyInfo-SSH2.xcprivacy ;; rist) echo PrivacyInfo-RIST.xcprivacy ;; smb) echo PrivacyInfo-SMB2.xcprivacy ;; nfs) echo PrivacyInfo-NFS.xcprivacy ;; esac; }
# Whether the module links OpenSSL; librist, libsmb2 and libnfs carry the crypto they need, or none.
module_needs_openssl() { case "$1" in rist|smb|nfs) return 1 ;; *) return 0 ;; esac; }
# The static library, and what it needs beyond OpenSSL's crypto, after it.
module_inputs() {
  local prefix="$1"
  case "$2" in
    srt) echo "$prefix/lib/libsrt.a $prefix/lib/libcrypto.a -lc++" ;;
    sftp) echo "$prefix/lib/libssh2.a $prefix/lib/libcrypto.a" ;;
    rist) echo "$prefix/lib/librist.a $prefix/lib/libmbedcrypto.a" ;;
    smb) echo "$prefix/lib/libsmb2.a" ;;
    nfs) echo "$prefix/lib/libnfs.a" ;;
  esac
}
# The public headers, where the build installed them.
module_headers() {
  local prefix="$1"
  case "$2" in
    srt) echo "$prefix/include/srt" ;;
    sftp) echo "$prefix/include" ;;
    rist) echo "$prefix/include/librist" ;;
    smb) echo "$prefix/include/smb2" ;;
    nfs) echo "$prefix/include/nfsc" ;;
  esac
}

build_slice() {
  local module="$1" name="$2" sdk="$3" arch="$4" min_flag="$5"
  local library framework prefix sdk_path inputs
  library="$(module_library "$module")"
  framework="$(module_framework "$module")"
  prefix="$BUILD/$arch-$name"
  echo "==> building $module / $name / $arch"
  mkdir -p "$prefix"
  if module_needs_openssl "$module"; then build_openssl "$name" "$arch" "$min_flag" "$prefix"; fi
  "build_$library" "$name" "$sdk" "$arch" "$min_flag" "$prefix"

  sdk_path="$(xcrun --sdk "$sdk" --show-sdk-path)"
  # Only the library's own names go out; the crypto it links in stays inside.
  export_list "$prefix/$module-exports.txt" "$(module_pattern "$module")" "$prefix/lib/lib$(basename "$library" | sed 's/^lib//').a"
  # shellcheck disable=SC2046
  link_dylib "$prefix/$framework-$module" "@rpath/$(framework_binary_path "$framework" "$name")" \
    "$(version_of "$library")" "$prefix/$module-exports.txt" "$arch" "$sdk_path" "$min_flag" \
    $(module_inputs "$prefix" "$module")
}

merge_platform() {
  local module="$1" name="$2" archs="$3" min_flag="$4"
  local library framework merged
  library="$(module_library "$module")"
  framework="$(module_framework "$module")"
  merged="$BUILD/merged-$name-$module"
  rm -rf "${merged:?}"
  mkdir -p "$merged/lib" "$merged/include" "$merged/frameworks"
  IFS=',' read -ra arch_list <<< "$archs"
  local headers
  headers="$(module_headers "$BUILD/${arch_list[0]}-$name" "$module")"
  if [ "$module" = sftp ]; then
    cp "$headers"/libssh2*.h "$merged/include/"
  else
    cp "$headers"/*.h "$merged/include/"
  fi
  # The headers include each other as <smb2/…> or <nfsc/…>, a folder a framework
  # does not have: only that path is changed, to the framework's, in these copies.
  case "$module" in
    smb) sed -i '' 's#<smb2/#<UmbelSMB2/#g' "$merged"/include/*.h ;;
    nfs) sed -i '' 's#<nfsc/#<UmbelNFS/#g' "$merged"/include/*.h ;;
  esac

  local a inputs=()
  for a in "${arch_list[@]}"; do inputs+=("$BUILD/$a-$name/$framework-$module"); done
  if [ "${#inputs[@]}" -eq 1 ]; then cp "${inputs[0]}" "$merged/lib/$framework"; else lipo -create "${inputs[@]}" -output "$merged/lib/$framework"; fi
  # While the object files it points at are still here.
  split_debug "$merged/lib/$framework" "$merged/$framework.framework.dSYM"
  "$ROOT/Tools/verify_network_libraries.sh" "$merged/lib/$framework"
  # The library's headers, included as <$framework/name.h>; they include each
  # other by bare name, so nothing is rewritten.
  make_framework "$name" "$framework" "$(version_of "$library")" "${min_flag#*=}" \
    "$merged/lib/$framework" "$merged/include" "$merged/frameworks" "$HERE/$(module_privacy "$module")"
}

assemble_xcframework() {
  local lib="$1"; shift
  local merged xcf_args=()
  for merged in "$@"; do
    xcf_args+=(-framework "$merged/frameworks/$lib.framework" -debug-symbols "$merged/$lib.framework.dSYM")
  done
  echo "==> assembling $lib.xcframework"
  rm -rf "${OUT:?}/${lib:?}.xcframework"
  xcodebuild -create-xcframework "${xcf_args[@]}" -output "$OUT/$lib.xcframework" >/dev/null
}

build_module() {
  local module="$1"
  case "$module" in srt|sftp|rist|smb|nfs) ;; *) echo "✗ no module $module (known: srt, sftp, rist, smb, nfs)" >&2; exit 1 ;; esac
  local library framework
  library="$(module_library "$module")"
  framework="$(module_framework "$module")"
  if module_needs_openssl "$module"; then fetch_sources openssl "$library"; else fetch_sources "$library"; fi
  local entry name sdk archs min_flag arch merged_dirs=()
  for entry in "${PLATFORMS[@]}"; do
    IFS='|' read -r name sdk archs min_flag <<< "$entry"
    IFS=',' read -ra arch_list <<< "$archs"
    for arch in "${arch_list[@]}"; do build_slice "$module" "$name" "$sdk" "$arch" "$min_flag"; done
    merge_platform "$module" "$name" "$archs" "$min_flag"
    merged_dirs+=("$BUILD/merged-$name-$module")
  done
  assemble_xcframework "$framework" "${merged_dirs[@]}"
  echo "✓ $module ($library $(version_of "$library")) built: $OUT/$framework.xcframework"
}

main() {
  local modules=("$@")
  [ "${#modules[@]}" -gt 0 ] || modules=(srt sftp rist smb nfs)
  local tools=(cmake ninja) module
  for module in "${modules[@]}"; do [ "$module" != rist ] || tools+=(meson); done
  for tool in "${tools[@]}"; do
    command -v "$tool" >/dev/null || { echo "✗ $tool missing: brew install $tool" >&2; exit 1; }
  done
  mkdir -p "$BUILD" "$OUT"
  for module in "${modules[@]}"; do build_module "$module"; done
}

main "$@"
python3 -B "$ROOT/Tools/clean_builds.py" --check || true
