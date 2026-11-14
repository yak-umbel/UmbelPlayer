# 0.1 内测验收与发布清单

当前目标是交付可复验的内测版本。此清单不代表版本已发布，也不替代正式对外发布所需的许可与分发决策。
截至 2026-11-09，源码版本为 `0.3.0`（可配置的后向压缩包缓存，标记 `0.3.0`）；当前内测范围为 iOS / iPadOS 与原生 macOS，详见 [能力范围](support.md)，版本变化见 [变更记录](../CHANGELOG.md)。
验证对象是框架的公开接口、输出行为与发布产物，全部通过本项目自有示例或独立测试工程完成。
第三方应用的业务逻辑、界面集成和最终应用归档由接入方负责，不是本项目验收项，也不阻断框架发布。

## 2026-10-22 视频精度与 P8 工作区验证

本轮代码随 `0.1.4` 发布（提交 `bc32f38`）。以下是提交前在工作区上做的验证，真机与模拟器上的实播、对照没有在 `0.1.4` 的最终二进制上重做；`0.1.4` 自己的验证见下文。

最新 P8.1 候选实现与恢复守卫通过完整 CI：1499 项测试、0 失败，45 项针对性回归通过。
Mac 主窗口与画中画的七点 HDR 数字对照均通过（画中画见 `tmp/video-fidelity/p81-completion/mac/PIP-RESULTS.md`），
P8.1 与 P8.4 同一条规则：系统硬解 DV 时默认交系统显示（Mac、iPad 一致），`compatibleBaseLayer` 可改回基础层；
iPad 真机七点实际帧身份复验通过，但高精度动态效果仍无法取证，因此 iPad 上为“默认启用、效果未验证”。
新增代码验证和效果限制见 `tmp/video-fidelity/p81-completion/RESULTS.md`；下表保留较早阶段证据。

| 验证项 | 结果与边界 | 本地证据 |
|---|---|---|
| Mac 完整 CI | 全部通过，1468 项测试，0 失败；结构、独立性、名称、许可、二进制与隐私守卫通过 | `tmp/video-fidelity-ci-final.log` |
| iPad 模拟器 | iPad Pro 11-inch M5 / iOS 26.5，48 项测试，0 失败；兼容基础层带字幕实播、画中画进入退出、0 报告丢帧与渲染错误 | `tmp/video-fidelity-ipad-complete.log`、`tmp/video-fidelity/ipad-playback-summary.json` |
| Mac P8.4 系统路径 | 真实 RPU 样片 10-bit 交付，12 秒原始系统路径与实际画中画开关，无兼容回退和系统解码失败 | `tmp/video-fidelity/report.json`、`tmp/video-fidelity/mac-native-playback-summary.json` |
| iPad 真机视频测试 | iPad Pro 11 英寸（M4）/ iPadOS 26.3.1 (a)，48 项测试，0 失败 | `tmp/video-fidelity-ipad-device.log`、`tmp/video-fidelity-ipad-device.xcresult` |
| iPad 真机实播 | P8.4 原始系统路径主窗口与画中画均为 10-bit `x420`、状态 `submittedToSystem`；连续播放至 30.5 秒结束，另验暂停、seek 与后台画中画，无回退；P8.1 基础层、SDR 10-bit 回归通过；各次播放报告丢帧和渲染错误均为 0 | `tmp/video-fidelity/ipad-device-summary.json`、`tmp/video-fidelity/ipad-device-media-validation.json` |
| 追加长测与高分辨率 | Mac P8.4 与 iPad 带音轨 SDR 10-bit 各完成 30 分钟；Mac 报告丢帧 0，iPad 变速瞬间累计 31 帧、其他时段未增加，均无播放失败或渲染错误；4K HDR 与带音轨 P8.4 短测报告丢帧及渲染错误均为 0，4K 内存峰值 651 MB | `tmp/video-fidelity/extended/extended-summary.json` |
| P8.4 HDR 数字对照 | 本 Mac 内置屏幕七个对齐时刻，项目与系统参考的 HDR 浮点捕获逐字节一致；去除动态元数据的 HLG 对照有可测差异；6314 个画面编码数据及时间戳一致 | `tmp/video-fidelity/extended/reference-comparison.json`、`tmp/video-fidelity/extended/reference-media-validation.json` |
| 数字音画同步对照 | 两路各 27 个闪光/音频脉冲；20 个稳态配对中，相对系统参考的差异中位数 +7.2 ms、最大绝对差异 24.0 ms；捕获链路有共同时间偏移，未作物理设备延迟或主观听感验收 | `tmp/video-fidelity/extended/sync-comparison.json` |

P8.1 选择兼容基础层时（策略要求、或系统不能硬解 DV），其动态元数据未应用与合成画中画的 HDR 到 SDR 映射均有明确诊断。
真机样片的配置记录与 RPU 标记已核对，截短后的全部视频包散列与原始样片对应包一致。
此前模拟器实播的截短样片缺少配置记录，只作为 HLG/RPU 兼容像素路径证据。
缓冲接受与画中画操作通过不等于动态映射观感已完整验收；追加的数字画质结论限定于本 Mac 与七个暂停时刻，
物理显示测量及其他组合仍未覆盖，详见 `tmp/video-fidelity/extended/RESULTS.md`、`tmp/video-fidelity/RESULTS.md` 与能力范围。

追加性能工作仅保留合成画中画的尺寸优化，变速候选未通过联合音画验收，已撤回。

| 追加验证项 | 结果与边界 | 本地证据 |
|---|---|---|
| 保留版本回归 | Mac 完整 CI 1473 项通过；iPad M5 模拟器 95 项通过；解锁后 iPad M4 真机 95 项通过，0 失败；iPhone 16 / iOS 18.6 与 iPhone 17 Pro Max / iOS 26.5 定向测试各 95 项通过 | `tmp/video-fidelity/optimization/ci-retained-final.log`、`tmp/video-fidelity-optimization-retained-sim.xcresult`、`tmp/video-fidelity-optimization-unlocked-device.xcresult`、`tmp/video-fidelity-coverage-iphone16-ios18.xcresult`、`tmp/video-fidelity-coverage-iphone17-ios26.xcresult` |
| 合成画中画内存 | Mac 隔离实验约 259 / 129 MB，均为 RGBAHalf；同场景 iPad 4K HDR / AAC 复测峰值 439 MB，基线 651 MB，报告丢帧/错误 0，RGBAHalf 保留；HDR 到 SDR/色域映射仍明确记录；不是 4K 长测 | `tmp/video-fidelity/optimization/memory-sized-full.json`、`tmp/video-fidelity/optimization/memory-sized-bounded.json`、`tmp/video-fidelity/optimization-unlocked/hdr4k-summary.json` |
| 保留版本真机长测 | SDR 10-bit / 5.1 完成 1800.480 秒，六轮交互、12 次 PiP 状态转换；峰值 323 MB，无持续增长，错误/热状态 0；报告丢帧 22，均首次出现在变速后两秒窗口内，窗口外 0；与基线 31 的差异不作为时钟修复证据 | `tmp/video-fidelity/optimization-unlocked/monitor/ipad-soak-report.md`、`tmp/video-fidelity/optimization-unlocked/monitor/ipad-soak-analysis.json` |
| 追加画质复核 | 复现取样工具把旧预热帧当作 12 秒目标；改为等待双方实际显示缓冲的唯一源帧 RPU 身份、捕获前后复核后，两次独立进程均 7/7 HDR 浮点逐字节一致；无 RPU 控制均有差异；旧失败保留，未修改生产首帧语义 | `tmp/video-fidelity/optimization-unlocked/alignment/FINDINGS.md`、`tmp/video-fidelity/optimization-unlocked/alignment/alignment-summary.json` |
| 变速候选否决 | 显式媒体/主机时间锚定虽消除采样中的大跳变，但扩大 2× 阶段数字音画偏差；仅设置媒体位置的替代方案仍有跳变。30 分钟候选运行与失败捕获只作调查记录，不作为保留版本验收 | `tmp/video-fidelity/optimization/RESULTS.md` |
| P8.1 独立可行性 | 本 Mac 主窗口（固定协议 96/96 同窗口同步捕获）与画中画（七点窗口内部捕获）均与原生参考逐字节一致，同基础画面 HDR10 控制有差异；实际会话 16 项检查通过；iPad 严格同帧效果门槛未满足，实际效果未知；默认与 P8.4 同一条规则（系统硬解 DV 时启用），Mac 已实测，iPad 效果未验证 | `tmp/video-fidelity/p81-completion/mac/PIP-RESULTS.md`、`tmp/video-fidelity/p81-completion/mac/stability-1/stability-report.json`、`tmp/video-fidelity/p81-research/FINDINGS-IPAD.md` |
| 扩大设备与输出覆盖 | mobile MCP 完成 iPhone 16、iPhone 17 Pro Max 与 iPad M5 模拟器的按钮、前后跳转、倍速和横竖屏；iPad PiP 状态切换与后台时钟通过，截图小窗黑色（普通 SDR8 亦如此），图像未通过；无外接 SDR/HDR 显示器在线，其他真机未覆盖 | `tmp/video-fidelity/coverage/RESULTS.md` |

## 已有验证基线

以下是 2026-09-26 工作区的历史验证结果，不能自动作为之后任意提交或二进制的验收结果。
本机原始证据放在被忽略的 `.build/` 下，全新检出不会带有这些文件；交付时需另行保存对应版本的证据包。

| 验证项 | 结果与边界 | 本地证据 |
|---|---|---|
| 仓库完整检查 | `Tools/ci.sh` 通过；932 项测试、0 失败，包含独立性、名称、结构、许可与二进制检查 | `.build/presentation-verification/ci-final.log` |
| iPad 公共 API 验收 | iPad Pro 11-inch M4、iPadOS 26.3.1(a)，5 组通过；实际 Metal 离屏渲染与 AVAudioEngine | `.build/ipad-acceptance/artifacts/final-run/acceptance.json` |
| 字幕位置与截图 | 文字、ASS、位图在暂停时移动与恢复，GPU 像素和截图比对通过；可见画布排除黑边 | `.build/ipad-acceptance/artifacts/final-run/` 中的 PNG 与 JSON |
| PCM 与音频延迟 | 实际 PCM 时间覆盖与样本检查、提取取消、播放不中断、暂停状态保留通过；不代表主观听感无缝 | `.build/ipad-acceptance/README.md` |
| iOS 真机 Release Archive | 四个嵌入动态 framework 的 UUID／架构匹配，调试信息非空，DWARF 校验和函数记录检查通过 | `.build/release-symbols-20260926-final/ios.xcarchive` |
| 原生 macOS Release Archive | 同上，覆盖 arm64 与 x86_64 | `.build/release-symbols-20260926-final/macos.xcarchive` |

归档验证使用独立消费工程，并显式设置 `DEBUG_INFORMATION_FORMAT=dwarf-with-dsym`。
其中 `UmbelCore` 的 dSYM 来自实际优化 Release Archive；结论不是从 Debug 构建推断，也不证明任意宿主的 Archive 设置正确。
总记录为 `.build/presentation-verification/README.md`，归档日志为 `.build/release-symbols-20260926-final-validation.log`。

此前 Mac / iPad 的实际 P5 播放已完成验收。上述新增 iPad 检查没有验证原生显示层布局、遮挡区域换算、主观音频延迟听感或 P5 截图颜色。
P5 比例覆盖与截图仍明确报告不支持。

2026-09-27 起在独立示例上补做的验证（`0.1.0-beta.1` 之前的工作区，同样不能自动代表之后的提交）：

| 验证项 | 结果与边界 | 本地证据 |
|---|---|---|
| 仓库完整检查 | `Tools/ci.sh` 通过；1019 项测试、0 失败 | `.build/next-work/ci-round2.log` |
| iOS 模拟器上的引擎测试 | iPhone 16 / iOS 18.6、iPhone 17 / iOS 26.5 各 1014 项：1009 通过、0 失败、5 项因无 EDR 显示或硬件解码跳过 | `.build/iphone-sim/README.md` |
| Mac 独立示例 | 起播与结束（文件、HTTP、HLS）、慢源与断网、播放控制、外挂字幕、字幕位置（真实窗口）、音频延迟、画面能力、seek 到片尾，自动检查全部通过；22.5 分钟连播 0 丢帧 | `.build/mac-acceptance/README.md` |
| iPad 与 iPhone 模拟器上的 iOS 示例 | 播放控制、连续重开、连播（iPad 9.9 分钟、模拟器 5 分钟）0 丢帧；iPhone 竖屏布局 | `.build/ipad-example-run/README.md`、`.build/iphone-sim/README.md` |

这些检查不含主观听感、HDR / DV 的实际观感、画中画操作、iPad 窗口变化和音频会话（来电、耳机），它们仍需人工验收。

2026-09-28 为 `0.1.0` 所做的验证（`0.1.0` 标记所在提交；本机证据在被忽略的 `.build/release-0.1.0/`）：

| 验证项 | 结果与边界 | 本地证据 |
|---|---|---|
| 仓库完整检查 | `Tools/ci.sh` 通过；1144 项测试、0 失败 | `ci.log` |
| 干净检出重建 | 受版本控制文件复制到新目录，`BuildFFmpeg`、`BuildLibass` 从源码构建三个依赖，许可检查通过，`Tools/ci.sh` 1144 项、0 失败；重建产物与所用二进制不逐字节相同（构建含路径与时间），两者 SHA-256 均已记录 | `clean-rebuild.log`、`clean-ci.log`、`manifest.txt` |
| Release Archive | 独立消费工程：iOS arm64、macOS arm64 与 x86_64，四个 framework 的 dSYM UUID 与调试信息检查通过 | `archive.log`、`archives/` |
| iPad 模拟器上的引擎测试 | iPad Pro 11-inch M4 / iOS 18.6 模拟器全部引擎测试 1140 项、0 失败，6 项因模拟器限制跳过；在最后一处系统播放器时间线修复之前运行，之后的改动由上面的仓库完整检查覆盖 | 会话记录 |
| 对象音频（所有者看听） | Mac 与 iPad：系统显示对象音频标签（AirPods）、音画同步、seek／1.5×／2×／暂停、换输出设备、后台与锁屏、画中画、系统代理开启；iPad 无本地网络权限弹窗；沙盒缺权限退回、宿主本机 HTTP 服务共存、网络片源只读一遍 | 本地验收记录 |
| HDR 与 DV（所有者看） | Mac 与 iPad：HDR10、HLG、DV P5、P8.1、P8.4 亮部、暗部与颜色正常；Mac 上 HDR10、HLG 与系统播放器同步对照一致（所用 DV 测试文件系统播放器无法打开，未对照） | 本地验收记录 |
| iPad 窗口变化（所有者看） | 横竖屏、分屏、窗口大小变化，像素路径与 DV P5 系统显示层路径画面完整、居中、黑边正确 | 本地验收记录与部分录屏 |

`0.1.1`（同日，修复暂停时切换画中画可能不返回）：`Tools/ci.sh` 通过，1151 项测试、0 失败；
iPad 模拟器上渲染器与界面测试 78 项通过；iPad 真机暂停状态下三次打开、关闭画中画均正常、位置不变；
iOS 与 macOS Release Archive 四个 framework 的符号检查通过。依赖二进制与 `0.1.0` 逐文件相同（SHA-256 一致），
沿用其干净重建结果。证据在 `.build/release-0.1.1/`。

`0.1.2`（2026-10-10；视频旋转、去隔行、解码背压与 HTTP 来源的修复，见变更记录）：`Tools/ci.sh` 通过，1397 项测试、0 失败，
其中 FFmpeg 许可检查对 iOS 真机、iOS 模拟器、macOS 三个切片的实际二进制都通过（`CONFIG_GPL == 0`、`CONFIG_NONFREE == 0`、
LGPL 2.1 or later）；iOS 与 macOS Release Archive 四个 framework 的符号检查通过。依赖二进制与 `0.1.1` 逐文件相同
（SHA-256 一致），沿用 `0.1.0` 的干净重建结果。iPad Pro 11-inch M4 真机上播放两个隔行样片（H.264 MBAFF TS 24 s、
1080i TS 60 s，均含快照与画中画）：丢帧 0、显示错误 0、拒收与损坏 0；这次在 `2ae665c` 上运行，其后的提交只改了一个测试
和 4:2:2／4:4:4 隔行源的转换，两个样片都是 4:2:0，不经过该转换，后者由单元测试、Mac 上的端到端检查与 iPhone 16、iPhone 17
模拟器上的隔行相关 35 项测试覆盖。iPhone 真机未验。证据在 `.build/release-0.1.2/`。

`0.1.3`（2026-10-20；首帧与跳转画面信号、seek 时放弃正在进行的读取、断网容忍、被截断文件的尾包，见变更记录）：
`Tools/ci.sh` 通过，1427 项测试、0 失败，其中 FFmpeg 许可检查对 iOS 真机、iOS 模拟器、macOS 三个切片的实际二进制都通过
（`CONFIG_GPL == 0`、`CONFIG_NONFREE == 0`、LGPL 2.1 or later），libass 许可检查三个切片通过；iOS 与 macOS Release Archive
四个 framework 的符号检查通过。依赖二进制未改动：`Binaries/` 下没有文件的修改时间晚于 `0.1.2` 的记录（均在 2026-09-25／26），
沿用 `0.1.0` 的干净重建结果；这次没有与 `0.1.2` 的哈希逐一对照（当时的汇总算法没有留下），另存了一份逐文件 SHA-256 的汇总供下次对照。
断网容忍在 iPad Pro 11-inch M4 真机上验过：断网约 40 秒后恢复，播放在原位置续上；断网超过耐心（60 秒）则在约 61–65 秒后以
`notConnectedToInternet` 失败，再 seek 并播放可重试；这次验收发现并修掉了耐心被翻倍的问题（见变更记录第一条）。
P5 路径的首帧信号在 Mac 上看过画面。证据在 `tmp/releases/0.1.3/`（`ci.log`、`archive.log`、`archives/`、`binaries.txt`、`source.txt`）。

`0.1.4`（2026-10-23；视频精度与 P8.1／P8.4 交系统显示、视频解码器偏好与软解线程数、硬件读到码流头后才拒绝时的软解修复，见变更记录）：
`Tools/ci.sh` 通过，1536 项测试、0 失败，其中 FFmpeg 许可检查对 iOS 真机、iOS 模拟器、macOS 三个切片的实际二进制都通过
（`CONFIG_GPL == 0`、`CONFIG_NONFREE == 0`、LGPL 2.1 or later），libass 许可检查三个切片通过；iOS 与 macOS Release Archive
四个 framework 的符号检查通过。依赖二进制未改动：`Binaries/` 下没有文件的修改时间晚于 2026-09-26；逐文件哈希汇总另存，
用的方法与 `0.1.3` 的不同、没能复现，所以不能与之直接对照。同一棵树上较早的一次整套运行有 23 项失败、22 项跳过，全部是依赖系统音频输出的测试
（对象音频、`PlayerItemTimeline`、引擎音频），当时这台 Mac 的音频系统卡住了（连音量为 0 的试播也不结束）；音频恢复后同一棵树重跑全绿，两份日志都留着。
解码器偏好与软解线程数只在 Mac 上验证，其中包括一个手写的单宏块码流（硬件会拒绝它）；这次没有在真机上跑。
iPad 上 P8.1 的动态元数据效果仍未验证，见 [能力范围](support.md)。
证据在 `tmp/releases/0.1.4/`（`ci.log`、`ci-audio-stuck.log`、`archive.log`、`archives/`、`binaries.txt`、`source.txt`）。

`0.1.5`（2026-10-26；系统播放器路由下缓冲内前跳保留缓存、声音连续性抖动容忍、解码器时间基，见变更记录）：
`Tools/ci.sh` 通过，1569 项测试、0 失败、无跳过，其中 FFmpeg 许可检查对 iOS 真机、iOS 模拟器、macOS 三个切片的实际二进制都通过
（`CONFIG_GPL == 0`、`CONFIG_NONFREE == 0`、LGPL 2.1 or later），libass 许可检查三个切片通过；iOS 与 macOS Release Archive
四个 framework 的符号检查通过。依赖二进制未改动：逐文件哈希汇总的方法同 `0.1.4`，三个值与 `0.1.4` 记录的逐一相同，
三个依赖框架在归档里的 UUID 也与 `0.1.4` 相同，`Binaries/` 下没有文件的修改时间晚于 2026-09-26。
缓冲内前跳另在 Mac 上做了运行验收（`tmp/mac-seek-2d7ae2c/REPORT.md`，修订 `2d7ae2c`）：真实 E-AC-3 JOC 长片（约 3473 秒，1080p H.264，六声道）、
本项目自带的限速服务（2 MiB/s）、`.automatic` 选路、没有测试用的强制路由开关；4 组共 12 次缓存内连续快进全部走 `cache`，HTTP 请求数始终为 3，没有 `demux_seek`；
后退与跳出缓存按预期走 `reread` 并新增请求；声音保持在系统播放器，画面与时钟正常推进。这次验收静音、离屏运行，不覆盖主观听感与音画同步，
回环网络没有真实延迟；iPad 真机没有操作；自动化测试里的保留用例用的是不带对象编码的 E-AC-3，靠测试开关送去系统播放器，真实对象编码内容只在这次 Mac 验收里出现过。
证据在 `tmp/releases/0.1.5/`（`ci.log`、`archive.log`、`archives/`、`binaries.txt`、`source.txt`）。

`0.1.5` 发版后补验（2026-10-26，修订 `a9e1bec`，库代码与标签一致）：iPad Pro 11 英寸（M4）/ iPadOS 26.3.1 (a) 真机上，用项目示例（启动参数 `-buffer-target 20`，示例默认只缓冲 10 秒）
播放一部 120 秒的真实 E-AC-3 (JOC) 小片，本地文件，静音，`.automatic` 选路：最终一次运行 3 组共 9 次缓冲内前跳（每次 10 秒，间隔约 1 秒）全部走 `cache`，没有 `demux_seek`，
声音一直是系统播放器，时钟按 1 倍速推进；后退与跳出缓存各按预期重读一次起一次 `demux_seek`。前两次运行各有一项失败，原因都在驱动脚本（命令通道卡顿使播放头跑到片尾、两条命令间隔不足 0.5 秒被漏读），
修正后重跑；三次合计 21 次落在缓存内的前跳全部是 `cache`。局限：本地文件而非网络源（请求数由 Mac 上的限速服务验收覆盖）、静音、素材短，不覆盖听感、音画同步、60 秒量级的缓冲、后台与画中画，
短距离前跳仍重读。证据在 `tmp/ipad-seek-cache/`（`REPORT.md`、`drive_seekcache.py`、`results-*.json`、`console-final-run.log`）。

`0.1.6`（2026-10-28；DV P5 系统硬解原生像素路径修复持续丢帧、iOS 15／16 不走该路径、iOS 显示驱动线程随停止结束，见变更记录）：
`Tools/ci.sh` 通过，1581 项测试、0 失败，无跳过，其中 FFmpeg 许可检查对 iOS 真机、iOS 模拟器、macOS 三个切片的实际二进制都通过
（`CONFIG_GPL == 0`、`CONFIG_NONFREE == 0`、LGPL 2.1 or later），libass 许可检查三个切片通过，iOS 15 部署目标的编译检查通过；iOS 与 macOS Release Archive
四个 framework 的符号检查通过。依赖二进制未改动：逐文件哈希汇总的方法同 `0.1.5`，三个值与 `0.1.5` 记录的逐一相同，
三个依赖框架在归档里的 UUID 也与 `0.1.5` 相同，`Binaries/` 下没有文件的修改时间晚于 2026-09-26。
同一棵树上第一次整套运行有 1 项失败：`GeneratedSegmentPlaybackTests`（系统播放器的时钟 1 秒只多走了 0.626 秒，期望 1.0 ± 0.2）；原样重跑全绿，两份日志都留着。
这一项没有查出原因：单独冷启动跑 25 次、与其他音频测试一起分组跑 12 次，它都没有再失败；分组跑里另一项 `PlayerItemTimelineTests`
（`testRateChangesDuringASeekKeepItsTargetAndNewestPause`）失败过 1 次，也没有查。自 `0.1.5` 起声音、时钟、时间线的源码没有改动，只修了一个测试：
`ObjectAudioRouteTests` 在播放器说在播放、时钟还没走时取起点，少算约 0.15 秒（`701b4ed`）。
P5 原生像素路径的丢帧数字（0 / 1302 与 0 / 1303，此前同一片源的压缩路径为 441 / 1292）是提交该路径时（`a676319`）在 Mac 上用一个 4K / 25 fps 的本地样片测的，
这个候选上没有重测；其后库代码的改动是 iOS 版本判断（macOS 上行为不变）和合成绘制用的缓冲池挪到单独的类型（不在 P5 原生像素路径上）。
iPad 与 iPhone 真机没有操作；iOS 15 与 16 只做了编译检查。边缘闪烁未解决，见变更记录与 [能力范围](support.md)。
证据在 `tmp/releases/0.1.6/`（`ci.log`、`ci-run1-failed.log`、`archive.log`、`archives/`、`binaries.txt`、`source.txt`）。

`0.1.7`（2026-11-05；适配系统显示层的主 actor 标注，保持后台渲染与旧系统同步提交，见变更记录）：
Xcode 27.2（27B52）下 `Tools/ci.sh` 一次通过，1586 项测试、0 失败、0 跳过；FFmpeg 与 libass 的实际依赖切片许可检查通过，
其中 FFmpeg 满足 `CONFIG_GPL == 0`、`CONFIG_NONFREE == 0`，运行时许可为 `LGPL version 2.1 or later`。
独立进程回归覆盖主线程、`dispatchMain()` 主队列及后台入口，以及嵌套同步调用和错误传播；修复前后失败与通过日志均保留。
同一工具链使用 macOS 26.5 SDK 编译通过；iOS 27.2 SDK 下最低 iOS 15 部署构建通过。
iOS arm64 与 macOS arm64／x86_64 Release Archive 均通过，四个嵌入 framework 的 dSYM 架构、UUID、DWARF 与函数记录检查通过。
三个依赖二进制沿用现有构建，本次没有重建，已保存逐文件 SHA-256 清单及依赖版本。
本轮没有在 iOS 18.6、iOS 26 真机上操作，也没有在旧系统真实显示层上实播；旧系统适配器的线程与提交顺序由测试替身验证，
编译检查不替代这些运行验证。公开接口、最低部署版本与既有能力边界不变，`0.1.6` 的已知限制继续保留。
证据在 `tmp/releases/0.1.7/`（`ci.log`、`ci-summary.txt`、`archive.log`、`archives/`、`ios15-build.log`、`macos-26-sdk-build.log`、
`display-layer-access-before.log`、`display-layer-access-after.log`、`binaries.txt`、`*-files.sha256`、`toolchain.txt`、`source.txt`）。

`0.2.0`（2026-11-06；内置网络来源、五个可选网络模块、`UmbelError.unsupportedScheme`，见变更记录）：
Xcode 27.2（27B52）下 `Tools/ci.sh` 通过，1815 项测试、0 失败、0 跳过（核心 1506；`UmbelFFmpegSupport` 166；可选模块 SRT 16、SFTP 23、RIST 29、SMB 27、NFS 23；`UmbelUI` 14；`UmbelASSSupport` 11），
依赖本机 `sshd`、Samba、`mediamtx`、`ffmpeg`、`openssl` 的测试都在场并运行。FFmpeg 许可检查对 iOS 真机、iOS 模拟器、macOS 三个切片的实际二进制通过
（`CONFIG_GPL == 0`、`CONFIG_NONFREE == 0`、LGPL 2.1 or later），libass 许可检查三个切片通过；五个网络库各三个切片通过 `Tools/verify_network_libraries.sh`
（只依赖系统库、安装名是自己的 `@rpath/Umbel<名>.framework/…`，LGPL 的 libsmb2 与 libnfs 各自是只含它自己的独立动态库）；`Tools/check_package_products.py` 对包清单通过；iOS 15 部署目标的编译检查通过。
iOS 与 macOS（arm64、x86_64）Release Archive 都嵌入 9 个框架（`UmbelCore`、`UmbelFFmpeg`、`UmbelASS`、`UmbelFriBidi` 与 `UmbelSRT`、`UmbelSSH2`、`UmbelRIST`、`UmbelSMB2`、`UmbelNFS`），符号检查通过。
依赖二进制：FFmpeg、libass、FriBidi 没有重建，逐文件哈希汇总的方法同 `0.1.4`，三个值与 `0.1.7` 记录的逐一相同，`Binaries/` 下这三个框架没有文件的修改时间晚于 2026-09-26；
五个网络库是首次随版本发布，由 `Tools/BuildNetwork/build.sh` 从固定版本的源码构建（版本与源码校验和见 `Tools/BuildNetwork/VERSIONS`），八个依赖的汇总值都在证据里，CI 与归档之后逐一核对过没有变化。
打包：HEAD 清单（模块各为独立产品）在 Xcode 的 App 工程里构建失败，报 `Swift package target 'UmbelCore' is linked as a static library … but cannot be built dynamically because there is a package product with the same name`；
模块并进 `UmbelCore` 产品后同一个 App 工程无签名构建 iOS 模拟器版成功，App 里只有一份 `UmbelCore.framework`，五个模块的代码在其中，五个 C 库框架各自嵌入。
iOS 模拟器（iPad Pro 11 英寸 M4 / iOS 18.6）上，`Tools/IOSNetworkSmoke` 跑五个模块的 74 项套件与冒烟测试通过（SRT 16、SMB 4、SFTP 2、RIST 29、NFS 23），iOS 15 的设备切片编译通过。
iPad Pro 11 英寸（M4）/ iPadOS 26.3.1 (a) 真机上，把五个模块嵌进测试 App，签名并运行（经 Wi‑Fi 连 Mac 上临时起的服务器）：SFTP、SMB、NFS、RTSP、RTMP、SRT 读到的字节都正确；
RIST 在没有发送端的端口上按预期报 `connection timed out`（库在真机上运行，对真实发送端未验证）；App 被挤到后台 15 秒与 45 秒后 SMB 读取接着走、0 个错误；
用户回应“本地网络”弹窗之前 TCP 连接立刻失败（errno 65），回应之后正常，已写进接入指南。这轮真机验证用的是与最终清单等价的合并写法（当时的临时包副本），最终清单另以上面的无签名模拟器构建验证；
真机验证之后改的 SRT 日志，在本机对着 mediamtx 的 SRT 服务验证过（修复前 149 行，修复后 0 行，读到的字节数相同），iOS 模拟器套件里的新测试通过，没有在真机上重做。
本轮没有验证：RIST 对真实发送端、本地网络权限被拒的状态、几分钟以上的后台挂起、iOS 15–17 与 macOS 12–13 的真机、蜂窝与 VPN、IPv6、真实的 NAS 与广域网丢包；`0.1.6` 的已知限制继续保留。
证据在 `tmp/releases/0.2.0/`（`ci.log`、`ci-suites.txt`、`archive.log`、`archives/`、`binaries.txt`、`deps/`、`toolchain.txt`、`source.txt`、`candidate-files.sha256`、`candidate.patch`），
真机与模拟器的日志在 `tmp/ios-smoke-device/`（`dev-*.log`、`build.log`）与 `tmp/ios-smoke/`（`verify.log`、`floor-UmbelPlayer.log`）。

`0.3.0`（2026-11-09；可配置的后向压缩包缓存，源码标记）：
Mac 上 `Tools/swift.sh test` 全包通过，1843 项测试、0 失败、0 跳过。覆盖预算淘汰、连续性校验、缓存回放、未命中回退、后退后的音轨与双字幕槽切换、
自动强制字幕选择以及字幕选择／延迟与 seek 的交错。独立性、名称与 Git 差异格式检查通过，独立代码审查未发现剩余必修问题。
证据在 `tmp/backward-cache-review/`（`fix-full-final.log`、`fix-final-focused.log`、`fix-track-selection.log`、`fixes.md`）。
本次没有重建依赖二进制或生成新的 Release Archive，也没有在模拟器／真机上重做播放验收；此前的设备验证不作为本次新缓存功能的实播证据。

已知问题：iOS 上 App 在后台时从画中画小窗还原，还原动画可能短暂（约 0.7 s）显示较早的一帧，见 [能力范围](support.md)。

## 框架独立验收

以下项目在本项目的 iOS / macOS 示例或专用测试工程中，对固定候选和目标设备记录结果。
可以复用与候选版本对应的已有证据，无需为了其他应用重复验收。每项记录设备／系统、媒体特征、操作步骤、实际结果与日志；不适用项写明理由。

- [x] 使用独立媒体夹具与可控 HTTP / HLS 来源验证首帧、声音、缓冲和结束状态，以及网络错误后的停止与恢复。（2026-09-27 Mac 示例）
- [x] 播放／暂停、前后 seek、连续 seek、音轨切换、倍速、静音、退出重开均保持正确状态。（2026-09-27 Mac、iPad 示例；2026-09-28 对象音频路径复验）
- [x] 独立示例在 iPad 横竖屏、分屏及窗口尺寸变化时，原生显示层输出、可见视频区与黑边正确。（2026-09-28 所有者看）
- [x] 用测试遮挡区域驱动字幕位置接口，验证文字、ASS、位图字幕上移／恢复；暂停时即时生效，截图字幕位置与完整画面规则一致。（2026-09-26 iPad、2026-09-27 Mac 真实窗口）
- [x] 外挂字幕显式选中、关闭、切轨和恢复自动选择正确，没有重复字幕层。（2026-09-27 Mac 示例）
- [x] PCM 提取使用实际返回的时间、采样率和声道信息；缓存缺口、过期、seek 清空、输出上限及取消有明确处理，播放不被重置。（2026-09-26 iPad）
- [ ] 播放及暂停时连续调整音频延迟，状态与进度正确；耳机／扬声器实际听感可接受。（状态与进度 2026-09-27 已验；实际听感未验证，所有者决定留待以后）
- [x] `videoCapabilities` 与实际输出路径一致，覆盖无首帧、P5 比例覆盖／截图不支持以及其他路径的可用状态和错误。（2026-09-27 Mac 示例）
- [x] 目标设备上的 SDR、HDR 与支持范围内的 DV 测试媒体实际播放正确；同时记录缩放、字幕和画中画限制。（2026-09-28 所有者看；限制见能力范围）
- [ ] 独立示例按接入契约配置音频会话，验证前后台切换、音频中断、音频路由切换与多声道输出。（前后台、路由切换 2026-09-28 已验；来电等音频中断未验证，所有者决定留待以后）
- [x] 画中画启动、关闭、调整大小、返回主界面与暂停后重开正确；P5 画中画的字幕限制可预期。（2026-09-28 Mac、iPad；从后台还原的短暂旧帧为已知问题）
- [x] 在独立示例中持续播放长片并反复打开／关闭，验证框架的内存、温度、掉帧与音画同步；记录实际测试时长及观察指标。（2026-09-27 Mac 22.5 分钟、iPad 9.9 分钟连播，连续重开）
- [x] iPhone、iPad 与 Mac 的拟支持设备范围有明确记录；旧系统、Intel Mac 等未覆盖项明确标为未验证。（见能力范围）

## 固定内测交付物

- [x] 项目所有者确定内测版本号、变更记录与接收范围，再同步源码版本和版本标记；不要仅靠文档标题视为发版。（2026-09-27：`0.1.0-beta.1`；2026-09-28：`0.1.0`、`0.1.1`；2026-10-10：`0.1.2`；2026-10-20：`0.1.3`；2026-10-23：`0.1.4`；2026-10-26：`0.1.5`；2026-10-28：`0.1.6`；2026-11-05：`0.1.7`。见 [变更记录](../CHANGELOG.md) 与 [能力范围](support.md)。）
- [x] 固定源码修订、三个依赖的构建版本与 SHA-256；工作区有未提交变更时保存差异，保证证据可对应到交付物。（`0.1.0`：标记所在提交，`manifest.txt`）
- [x] 从干净检出完成构建和独立示例接入，确认二进制的获取或源码重建步骤可执行。（`0.1.0`：`clean-rebuild.log`）
- [x] 对固定候选重新运行 `Tools/ci.sh`，保存完整日志；本地名称名单存在且实际启用，新增文件也纳入检查。（`0.1.0`：`ci.log`）
- [x] 为固定候选生成独立消费工程的 iOS 与 macOS Release Archive，验证 `UmbelCore` 和三个依赖的 dSYM：架构／UUID 一致，每架构调试信息非空，DWARF 与函数记录有效；保存归档和校验日志。（`0.1.0`：`archive.log`、`archives/`）
- [x] 保存二进制、dSYM、构建设置、工具链版本、测试日志和设备验收记录；不能只保留截图或单个通过摘要。（`0.1.0`：`.build/release-0.1.0/`）
- [ ] 交付材料附上 [接入指南](integration.md)、[能力范围](support.md)、[接口说明](playback-controls.md) 与已知问题。

复验命令从仓库根目录执行，符号输出目录应为空或尚不存在：

```bash
Tools/ci.sh
Tools/archive_release_symbols.sh
```

完整归档说明见 [Tools/ArchiveConsumer](../Tools/ArchiveConsumer/README.md)。
`archive_release_symbols.sh` 会确认独立消费工程包含四个预期 framework。
`check_archive_symbols.sh` 检查传入 Archive 中所有嵌入 framework 的符号，也可供接入方自行验证应用归档；第三方应用及其额外依赖不在本项目发布验收范围内。

## 正式对外发布前

以下事项不因内测通过而完成，也不在本次文档整理中替项目所有者决定。

- [x] 版权署名 yak-umbel；自有代码以 LGPL-3.0-only 发布（`COPYING.LESSER`、`COPYING`），取代原保留权利声明。
- [ ] 决定商业授权条款、授权范围与联系方式。
- [ ] 决定可复现的二进制分发方式、版本校验与获取流程；当前本地 `Binaries/` 路径不是远程二进制发布方案。
- [ ] 核对 [LICENSES.md](../LICENSES.md)、第三方许可原文、源码与构建材料的提供方式、动态链接和隐私清单；依赖变动后重新验证。
- [ ] 确认 FFmpeg `CONFIG_GPL == 0`、`CONFIG_NONFREE == 0` 且运行时许可为 `LGPL version 2.1 or later`，失败即阻断发布。
- [ ] 评估 macOS 画中画对系统窗口／视图结构的适配，完成目标系统回归并明确分发渠道可接受性。
- [ ] 明确公开支持矩阵与维护范围，完成目标设备稳定性验收；Catalyst、tvOS、visionOS 在切片与验证齐备前保持未支持状态。
