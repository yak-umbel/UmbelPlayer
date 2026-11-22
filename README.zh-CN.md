# UmbelPlayer

[English](README.md) | 简体中文

Apple 平台的独立播放器框架：播放内核、画中画接入层、自建 FFmpeg 与字幕依赖分发。
本项目通过自有示例与测试工程独立开发、验证和发布，不依赖任何特定应用或其验收结果。

当前交付范围为 iOS / iPadOS 与原生 macOS。Mac Catalyst、tvOS、visionOS 尚无完整二进制依赖切片，不属于当前支持范围。

## 状态

已具备日常播放与宿主接入所需的主要内核能力；完整的默认播放器界面和更多平台仍待推进。

当前源码版本为 `0.4.0`，仍是预发布版本（`0.x`，公开接口可能调整）；验收记录与仍待人工验证的项目见 [发布清单](docs/release-checklist.md)。各版本变化见 [变更记录](CHANGELOG.md)。`UmbelUI` 目前主要提供画中画封装，控制栏、手势与设置界面由宿主实现。

- [平台与能力范围](docs/support.md)：实际二进制、条件支持与已知限制。
- [接入指南](docs/integration.md)：构建、渲染、生命周期、字幕、音频和数据源。
- [字幕、预览与播放接口](docs/playback-controls.md)：双字幕、外挂 SUP、进度预览、位置、缓存提取与能力查询契约。
- [验收与发布清单](docs/release-checklist.md)：已有证据和交付前待办。

## 包结构

Swift Package 公开一个动态库产品 **`UmbelCore`**，其中包含 `UmbelCore` 和 `UmbelUI` 两个模块。
使用画中画时额外 `import UmbelUI`，无需添加第二个产品。构建过库的可选网络模块（`Tools/BuildNetwork/build.sh`）也在这个产品里，
用 `import Umbel<名>Source` 引入，见[接入指南](docs/integration.md)。

| 模块 | 依赖 | 用途 |
|---|---|---|
| `UmbelCore` | FFmpeg / ASS 支持层、AVFoundation、VideoToolbox、Metal | 播放内核，无 UIKit / AppKit 依赖 |
| `UmbelUI` | `UmbelCore`、系统界面框架 | 画中画封装 |
| `UmbelFFmpegSupport` / `UmbelASSSupport` | 对应 xcframework | 内部 C 接口封装与类型桥接 |

## 开发

需要 macOS、Xcode（含 iOS SDK）与 Swift 6 工具链。依赖使用本地 `Binaries/*.xcframework`，不入 git；全新检出需先构建三个依赖产物：

```bash
brew install meson ninja pkg-config nasm
Tools/BuildFFmpeg/build.sh
Tools/BuildLibass/build.sh
git config core.hooksPath Tools/githooks
Tools/ci.sh
```

构建细节见 [FFmpeg](Tools/BuildFFmpeg/README.md) 和 [字幕依赖](Tools/BuildLibass/README.md)。
名称守卫使用本地 `.git/info/umbel-names` 名单；贡献者需单独配置，该名单不入库。
常用单项检查：

```bash
Tools/swift.sh build
Tools/swift.sh test
Tools/check_independence.sh
python3 Tools/check_names.py tree
Tools/check_binaries.sh --all Binaries
```

Release 归档与 dSYM 检查见 [归档说明](Tools/ArchiveConsumer/README.md)。
构建缓存统一放在 `tmp/` 并复用；预览清理候选使用 `python3 Tools/clean_builds.py`，
实际删除需显式加 `--delete`。目录、保留规则与容量提醒见 [构建空间管理](docs/build-storage.md)。
独立示例为 [原生 macOS](Examples/UmbelPlay/UmbelPlay.swift) 和 [iOS / iPadOS](Examples/UmbelPlayiOS/Sources/PlayerViewController.swift)。

## 许可

Copyright (C) 2026 yak-umbel

自有代码以 GNU 宽通用公共许可证第 3 版（LGPL-3.0-only）发布，原文见 [COPYING.LESSER](COPYING.LESSER)；
该许可在 GNU 通用公共许可证第 3 版之上增加许可，后者原文见 [COPYING](COPYING)。具体义务以许可原文为准。

以后的大版本可能采用不同的许可条款，已发布的版本不受影响。其他授权方式日后公布。
第三方组件分别适用 [LICENSES.md](LICENSES.md) 所列许可。

## 名称

Umbel（伞形花序）：所有花梗自同一点发散，如伞骨张开。
