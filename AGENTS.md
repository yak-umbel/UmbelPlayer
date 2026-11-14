# AGENTS.md

UmbelPlayer 的权威开发指引。人和自动化工具同等适用。

## 这是什么

Apple 平台的独立播放器框架。**它不是任何 App 的一部分**，即使某个 App 是它目前唯一的使用者。
自有代码以 LGPL-3.0-only 发布（`COPYING.LESSER`、`COPYING`），版权集中持有，以便将来另行提供商业授权；
未来大版本可能采用不同许可。

## 三条铁律

违反任何一条的改动一律不接受，无论收益多大。

### 1. 独立性

- `UmbelCore` / `UmbelUI` **不得** import 任何宿主 App 的模块。
- **不得**读取宿主环境变量（任何宿主前缀的环境变量）。
- **不得**在代码、注释、测试、文档中假设某个特定宿主 App 的存在。
- 外部数据只能经 `UmbelSource` 协议注入；本包自带的默认实现同样实现该协议，由使用方显式创建，引擎不按地址猜来源（有哪些，见 `docs/support.md`）。
- `UmbelCore` **不得** `import UIKit` / `import AppKit`（界面代码属于 `UmbelUI`）。
- `swift test` 必须在不接触任何宿主仓库的情况下跑完。
- 对象音频的系统播放接口封装在 `Sources/UmbelCore/ObjectAudio/PlayerItemTimeline.swift`，
  用于音频播放及时间线适配；对应集成测试放在 `Tests/UmbelCoreTests/ObjectAudio/`。
  常规播放管线通过时间线抽象接入，不直接依赖该系统播放接口；会话的声音走法（引擎解码或系统播放器、交接与退回）
  由 `Sources/UmbelCore/Playback/AudioPath.swift` 负责。

强制手段：`Tools/check_independence.sh`（进 CI），以及 `Tools/check_names.py`：宿主名等不得入库的
名称由它对照本地名单检查，名单放在 `.git/info/umbel-names`，不入库；`Tools/githooks/` 在提交与推送前运行它
（`git config core.hooksPath Tools/githooks`）。

### 2. 来源清白

- **不得**复制任何第三方播放器的代码、类划分、方法签名、常量、魔数或注释。
  尤其注意 copyleft 项目（GPL 许可的播放器框架）。
- 架构**思想**可自由借鉴（分层方式、VideoToolbox / Metal / `AVSampleBufferDisplayLayer` 路径、
  把码流交给系统已授权解码器）——思想不受著作权保护，表达受保护。
- 命名从**职责**推导，禁止映射式改名（不允许把他人的 `XxxPlayerItem` 改成 `UmbelPlayerItem`）。
- 撰写本项目代码时**不打开**第三方 copyleft 播放器源码。设计从需求推导，不从他人目录树推导。
- 入库的代码、注释、测试、文档与提交信息**不提**其他播放器或播放内核的名称，也不写与它们的对照数据；
  借鉴的做法只写做法本身与理由。本地不入库的笔记不受此限。

### 3. 许可合规

- FFmpeg **必须**按 LGPL 构建：不传 `--enable-gpl`，不传 `--enable-nonfree`，
  不链接 libx264 / libx265 / libxvid / postproc 等 GPL 组件。
- 发布前校验 `CONFIG_GPL == 0 && CONFIG_NONFREE == 0`，且 `avutil_license()` 返回
  `LGPL version 2.1 or later`。**校验失败即阻断发布。**
- 新增依赖必须同步更新 `LICENSES.md`。不接受许可不明的依赖，也不接受与本项目 LGPL-3.0-only 不兼容的依赖
  （例如只限 GPL 第 2 版的组件）。
- **商标**：代码、面向用户的文本、API 名称、文档中不得出现受保护的音视频技术商标及其 logo
  （名单在本地，由 `Tools/check_names.py` 检查）。
  使用中性技术名：`DV P8.1`、`E-AC-3 (JOC)`、`HDR 动态元数据`、`直通输出 / Passthrough`。
- 专利红线：不自研 E-AC-3 JOC 的对象渲染、不自研 AC-4 解码器（两者均只做 passthrough）。
  DV Profile 5 的软件处理由编译开关 `UMBEL_ENABLE_SOFTWARE_DOVI` 控制，**默认关闭**。

## 项目结构

```
Sources/UmbelCore/          内核。无 UI 依赖
Sources/UmbelUI/            默认界面（UIKit / AppKit / SwiftUI）
Sources/UmbelFFmpegSupport/ FFmpeg Swift 侧封装
Binaries/                   FFmpeg xcframework（不入 git）
Tools/BuildFFmpeg/          FFmpeg 构建脚本（LGPL 配置）
Tools/check_independence.sh 独立性守卫
Examples/UmbelDemo/         独立示例 App
docs/design/                设计文档
```

## 常用命令

```bash
Tools/swift.sh build
Tools/swift.sh test
Tools/check_independence.sh
```

## 开发约定

- 直接在 `main` 上开发，不新建 worktree。
- 不自动创建 git 提交；改动留在工作区，由项目所有者决定何时提交。
- 本项目的临时脚本、实验副本、构建与测试产物、日志和报告统一放在项目 `tmp/` 下；不主动写入 `/private/tmp/`。`tmp/` 不入库。
- 日常 Swift 构建、测试和运行使用 `Tools/swift.sh build|test|run`，复用 `tmp/swift-build/`；Xcode 临时构建放在 `tmp/xcode-derived/`，不按日期或任务重复保留整套缓存。
- Release 归档使用 `Tools/archive_release_symbols.sh`，默认保留到 `tmp/releases/`；脚本退出时清理其独占的中间构建目录，保留归档、dSYM 和日志。
- 实验副本只复制必要的源码、脚本和补丁，不复制 `.git/`、`.build/`、`tmp/`、`videos/` 或整套依赖二进制；需要相同版本二进制时只读共用。
- 清理前运行 `python3 Tools/clean_builds.py` 预览，确认后用 `--delete`；默认只处理 7 天无修改的专用缓存目录，运行中的构建会阻止删除。不得把整个 `tmp/`、`.build/` 或未被 Git 跟踪的文件一概删除。详情见 `docs/build-storage.md`。
- 公开 API 遵循语义化版本，破坏性变更只在大版本发生。
