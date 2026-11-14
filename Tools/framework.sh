#!/bin/bash
# Wraps a dynamic library as a framework. Sourced by the build scripts.
#
# A framework is the only form of dynamic library an app for iOS may carry,
# and an xcframework cannot mix frameworks with plain libraries, so every
# platform gets frameworks. Each framework keeps its own library's headers:
# FFmpeg's include each other as "libavutil/…", which the compiler finds as
# libavutil.framework's headers through the framework search path.
#
# macOS frameworks are versioned bundles (Versions/A, linked from the top);
# the others are flat.

# Where the frameworks' bundle identifiers start: the project's, not the
# signing account of whoever builds an app with them.
FRAMEWORK_ID_PREFIX="io.github.yak-umbel.umbel"

# framework_binary_path <name> <platform>: the binary's path in its
# framework, as an install name after @rpath/ has to be.
framework_binary_path() {
  local name="$1" platform="$2"
  if [ "$platform" = macos ]; then
    echo "$name.framework/Versions/A/$name"
  else
    echo "$name.framework/$name"
  fi
}

# write_framework_plist <name> <platform> <version> <minimum OS>
write_framework_plist() {
  local name="$1" platform="$2" version="$3" minimum="$4"
  local supported minimum_key
  case "$platform" in
    ios) supported=iPhoneOS; minimum_key=MinimumOSVersion ;;
    iossim) supported=iPhoneSimulator; minimum_key=MinimumOSVersion ;;
    macos) supported=MacOSX; minimum_key=LSMinimumSystemVersion ;;
    *) echo "✗ unknown platform: $platform" >&2; return 1 ;;
  esac
  cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>$name</string>
  <key>CFBundleIdentifier</key><string>$FRAMEWORK_ID_PREFIX.$name</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>$name</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$version</string>
  <key>CFBundleSupportedPlatforms</key><array><string>$supported</string></array>
  <key>$minimum_key</key><string>$minimum</string>
</dict>
</plist>
PLIST
}

# rewrite_includes <headers root> <directory>...
#   Makes the headers' includes of one another relative to themselves:
#   #include "libavutil/x.h" or <libavutil/x.h>, libavutil among the
#   directories named, becomes "../libavutil/x.h". Found that way they no
#   longer depend on a framework being named as their directory is — nor
#   on a disk that ignores case. Only the include lines change; LICENSES.md
#   says so, as the LGPL asks of a changed file.
rewrite_includes() {
  local root="$1"; shift
  local dirs
  dirs="$(IFS='|'; echo "$*")"
  find "$root" -name '*.h' -print0 | xargs -0 sed -i '' -E \
    "s@^([[:space:]]*#[[:space:]]*include[[:space:]]*)[<\"](($dirs)/[^\">]+)[\">]@\\1\"../\\2\"@"
}

# make_framework <platform> <name> <version> <minimum OS> <dylib> <headers|-> <out dir> [privacy manifest]
#
# The dylib's install name must already be @rpath/ plus its path in the
# framework: what loads it looks there. Its signature, broken by
# install_name_tool, is made again over the whole bundle.
#
# The privacy manifest, when given, goes where the system looks for it: at
# the top of an iOS framework, among a macOS framework's resources.
make_framework() {
  local platform="$1" name="$2" version="$3" minimum="$4" dylib="$5" headers="$6" out="$7"
  local privacy="${8:-}"
  local want have
  want="@rpath/$(framework_binary_path "$name" "$platform")"
  have="$(otool -D "$dylib" | tail -n 1)"
  if [ "$have" != "$want" ]; then
    echo "✗ $dylib has install name $have, not $want" >&2
    return 1
  fi

  local fw="$out/$name.framework" contents
  rm -rf "$fw"
  if [ "$platform" = macos ]; then
    contents="$fw/Versions/A"
    mkdir -p "$contents/Resources"
    write_framework_plist "$name" "$platform" "$version" "$minimum" > "$contents/Resources/Info.plist"
    ln -s A "$fw/Versions/Current"
    ln -s "Versions/Current/$name" "$fw/$name"
    ln -s Versions/Current/Resources "$fw/Resources"
  else
    contents="$fw"
    mkdir -p "$contents"
    write_framework_plist "$name" "$platform" "$version" "$minimum" > "$contents/Info.plist"
  fi
  cp "$dylib" "$contents/$name"
  if [ "$headers" != - ]; then
    cp -R "$headers" "$contents/Headers"
    [ "$platform" = macos ] && ln -s Versions/Current/Headers "$fw/Headers"
  fi
  if [ -n "$privacy" ]; then
    if [ "$platform" = macos ]; then
      cp "$privacy" "$contents/Resources/PrivacyInfo.xcprivacy"
    else
      cp "$privacy" "$contents/PrivacyInfo.xcprivacy"
    fi
  fi
  # Replacing the dylib's own signature is expected, and not worth a line.
  codesign --force --sign - "$contents" 2>&1 | { grep -v 'replacing existing signature' || true; } >&2
  return "${PIPESTATUS[0]}"
}
