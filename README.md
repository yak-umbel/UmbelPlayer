# UmbelPlayer

English | [简体中文](README.zh-CN.md)

A standalone playback framework for Apple platforms: a playback core, a picture-in-picture integration layer, and its own builds of FFmpeg and the subtitle libraries.
It is developed, verified and released through its own examples and test projects, and does not depend on any particular app or on that app's acceptance results.

It currently covers iOS / iPadOS and native macOS. Mac Catalyst, tvOS and visionOS have no complete slices of the binary dependencies yet and are not supported.

## Status

The core has the main capabilities that everyday playback and integration into a host app need; a complete default player interface and more platforms are still to come.

The current source version is `0.3.0`, still a pre-release (`0.x`: public interfaces may change). The [release checklist](docs/release-checklist.md) records what has been verified and what still awaits manual checks; the [changelog](CHANGELOG.md) lists each version's changes. For now `UmbelUI` mainly wraps picture in picture; controls, gestures and settings are up to the host.

The documents below are currently in Chinese.

- [Platforms and capabilities](docs/support.md): the actual binaries, conditional support and known limits.
- [Integration guide](docs/integration.md): building, rendering, lifecycle, subtitles, audio and data sources.
- [Subtitles, previews and playback interfaces](docs/playback-controls.md): dual subtitles, external SUP files, timeline previews, position, cache extraction and capability queries.
- [Verification and release checklist](docs/release-checklist.md): the evidence so far and what remains before delivery.

## Package layout

The Swift package exposes one dynamic library product, **`UmbelCore`**, which contains two modules, `UmbelCore` and `UmbelUI`.
For picture in picture, also `import UmbelUI`; no second product is needed. The optional network modules whose libraries have been built (`Tools/BuildNetwork/build.sh`) are in the same product,
imported with `import Umbel<Name>Source`; see the [integration guide](docs/integration.md).

| Module | Depends on | Purpose |
|---|---|---|
| `UmbelCore` | FFmpeg / ASS support layers, AVFoundation, VideoToolbox, Metal | The playback core, with no UIKit / AppKit dependency |
| `UmbelUI` | `UmbelCore`, the system UI frameworks | Picture-in-picture wrapper |
| `UmbelFFmpegSupport` / `UmbelASSSupport` | The matching xcframeworks | Internal C interface wrappers and type bridging |

## Development

Requires macOS, Xcode (with the iOS SDK) and a Swift 6 toolchain. The dependencies are local `Binaries/*.xcframework` bundles, not kept in git; a fresh checkout builds the three dependency products first:

```bash
brew install meson ninja pkg-config nasm
Tools/BuildFFmpeg/build.sh
Tools/BuildLibass/build.sh
git config core.hooksPath Tools/githooks
Tools/ci.sh
```

Build details are in [FFmpeg](Tools/BuildFFmpeg/README.md) and [subtitle libraries](Tools/BuildLibass/README.md) (both in Chinese).
The name guard checks against a local list, `.git/info/umbel-names`, which is not committed; contributors set up their own.
Common individual checks:

```bash
Tools/swift.sh build
Tools/swift.sh test
Tools/check_independence.sh
python3 Tools/check_names.py tree
Tools/check_binaries.sh --all Binaries
```

Release archives and dSYM checks are described in the [archive notes](Tools/ArchiveConsumer/README.md).
Build caches live in `tmp/` and are reused; `python3 Tools/clean_builds.py` previews what could be cleaned,
and deleting needs an explicit `--delete`. Directories, retention rules and size reminders are in [build storage](docs/build-storage.md) (in Chinese).
The standalone examples are for [native macOS](Examples/UmbelPlay/UmbelPlay.swift) and [iOS / iPadOS](Examples/UmbelPlayiOS/Sources/PlayerViewController.swift).

## License

Copyright (C) 2026 yak-umbel

The project's own code is released under the GNU Lesser General Public License, version 3 only (LGPL-3.0-only); its text is in [COPYING.LESSER](COPYING.LESSER).
That license adds permissions to the GNU General Public License, version 3, whose text is in [COPYING](COPYING). The license texts are what bind.

Future major versions may be released under different terms; versions already released are not affected. Other licensing options will be announced later.
Third-party components are under the licenses listed in [LICENSES.md](LICENSES.md) (in Chinese).

## Name

Umbel: a flower cluster whose stalks all spread from one point, like the ribs of an umbrella.
