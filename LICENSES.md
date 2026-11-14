# 第三方依赖许可清单

UmbelPlayer 自有代码：Copyright (C) 2026 yak-umbel，以 LGPL-3.0-only 发布，原文见
[COPYING.LESSER](COPYING.LESSER) 与 [COPYING](COPYING)。下表只列第三方依赖。

新增任何依赖时必须在此登记。未登记的依赖不得合入。

| 依赖 | 版本 | 许可 | 用途 | 是否可选 | 状态 |
|---|---|---|---|---|---|
| FFmpeg | n9.0.2 | LGPL v2.1+ | 解复用 / 解码 / 重采样 | 否 | M0 接入；五个库合成一个动态库 `UmbelFFmpeg`，可替换、可重链 |
| libass | 0.17.5 | ISC | ASS/SSA 字幕完整特效渲染 | 否 | M2 第 8 片接入，动态库 `UmbelASS` |
| FreeType | 2.14.3 | FTL（选用；与 GPLv2 双许可） | libass 的字形光栅化 | 否 | 静态并入 `UmbelASS` |
| HarfBuzz | 14.5.0 | MIT（Old MIT） | libass 的文字整形 | 否 | 静态并入 `UmbelASS` |
| FriBidi | 1.0.17 | LGPL v2.1+ | libass 的双向文字排序 | 否 | **独立的动态库** `UmbelFriBidi`，同 FFmpeg 的可重链要求 |
| dav1d | 1.5.4 | BSD-2-Clause | AV1 软解回退 | 否 | 静态并入动态库 `UmbelFFmpeg`，符号不对外导出 |
| SRT | 1.5.7 | MPL-2.0 | SRT 直播流 | **是**（可选模块 `UmbelSRTSource`） | 不修改；动态库 `UmbelSRT`；MPL 要求的源码获取方式写在模块随带的许可原文里 |
| libssh2 | 1.11.1 | BSD-3-Clause | SFTP 文件读取 | **是**（可选模块 `UmbelSFTPSource`） | 不修改；动态库 `UmbelSSH2`；上游发布签名而非校验和，已按 Daniel Stenberg 公布的密钥验过 |
| OpenSSL | 3.5.9 | Apache-2.0 | SRT 的加密（口令加密与认证加密）、libssh2 的密码学 | **是**（随 `UmbelSRTSource`、`UmbelSFTPSource`） | 各自静态并入动态库 `UmbelSRT`、`UmbelSSH2`，符号不对外导出；长期支持到 2030-04-08 |
| librist | 0.2.20 | BSD-2-Clause | RIST 直播流 | **是**（可选模块 `UmbelRISTSource`） | 不修改；动态库 `UmbelRIST`；上游不发布校验和与签名，`VERSIONS` 里是 GitLab 发布标签归档的校验和 |
| Mbed TLS | 3.6.6 | Apache-2.0（与 GPL-2.0+ 双许可，**选用 Apache-2.0**） | librist 的加密（预共享密钥的随机数与 AES） | **是**（随 `UmbelRISTSource`） | 用 librist 源码里自带的那份，静态并入 `UmbelRIST`，符号不对外导出；没有单独的源码包要固定 |
| lz4 | 1.10.0 | BSD-2-Clause | librist 的可选压缩 | **是**（随 `UmbelRISTSource`） | librist 源码里自带的那份，并入 `UmbelRIST` |
| cJSON | 1.7.13 | MIT | librist 的统计信息 | **是**（随 `UmbelRISTSource`） | 同上 |
| libsmb2 | 6.3.0 | LGPL-2.1+ | SMB 文件读取 | **是**（可选模块 `UmbelSMBSource`） | **独立的动态库** `UmbelSMB2`，里面没有别的库，同 FFmpeg、FriBidi 的可重链要求；不修改；AES/MD4/MD5/SHA 是它自带的，没有 OpenSSL，不带 Kerberos；上游不发布校验和与签名，`VERSIONS` 里是 GitHub 发布标签归档的校验和 |
| libnfs | 8.0.0 | LGPL-2.1+（库）；协议定义与由它生成的代码 BSD-2-Clause | NFS 文件读取 | **是**（可选模块 `UmbelNFSSource`） | **独立的动态库** `UmbelNFS`，里面没有别的库，满足可重链要求；不修改；不带 Kerberos、TLS、NFSv4.2；上游不发布校验和与签名，`VERSIONS` 里是 GitHub 发布标签归档的校验和 |
| libdovi | 待定 | MIT | DV Profile 5 软件回退 | **是，默认关闭** | 见下 |

## 构建约束

FFmpeg 必须按 LGPL 构建：

- 不传 `--enable-gpl`
- 不传 `--enable-nonfree`
- 不启用 libx264 / libx265 / libxvid / postproc 等 GPL 组件

发布前校验：`CONFIG_GPL == 0 && CONFIG_NONFREE == 0`，失败即阻断。
成品另由 `Tools/verify_ffmpeg_license.sh --binaries` 复验：每个库的许可字符串都是
`LGPL version 2.1 or later`，configure 那一行没有 GPL 和 nonfree。

**对 FFmpeg 头文件的改动**：构建时把已安装头文件里互相引用的 `#include` 改写为相对路径
（`"libavutil/x.h"` → `"../libavutil/x.h"`），只改包含行，内容不动；这是对 LGPL 库文件的改动，特此注明。

libass 及其依赖由 `Tools/BuildLibass/build.sh` 从固定版本源码构建，源码包校验 SHA256；
`Tools/verify_libass_license.sh` 复验链接关系：FriBidi 必须是独立动态库 `UmbelFriBidi` 并经 `@rpath`
引用，`UmbelASS` 除系统库与 FriBidi 外不得有其他依赖（没有 fontconfig），字体来自 CoreText。

### FreeType 致谢（FTL 要求）

FreeType 按 FreeType License（FTL）使用。FTL 要求在产品文档中致谢，发布物须带上：

> Portions of this software are copyright © 2026 The FreeType Project
> (https://freetype.org). All rights reserved.

## 可选网络模块

每个协议一个可选模块，各带自己的 C 库，只在对应的 xcframework 构建过时才出现在包里（`Package.swift` 检查
`Binaries/Umbel*.xcframework` 是否存在）；模块并在动态产品 `UmbelCore` 里，不用的模块就不要构建它的库。构建由 `Tools/BuildNetwork/build.sh` 做：
固定版本的源码、每次校验 SHA256、各平台切片、只导出自己的名字、dSYM、隐私清单；
`Tools/verify_network_libraries.sh` 复验链接关系（只依赖系统库；LGPL 的库必须是独立动态库）。

- 模块自己带的许可原文由模块提供（`UmbelSRTSource.thirdPartyNotices`、`UmbelSFTPSource.thirdPartyNotices`、`UmbelRISTSource.thirdPartyNotices`、`UmbelSMBSource.thirdPartyNotices`、`UmbelNFSSource.thirdPartyNotices`），不写进 `UmbelCore` 的清单：
  `UmbelCore` 不发行这些库。原文取自固定版本源码包里的许可文件。
- **加密库选 OpenSSL 3.5，没有选 mbedTLS**：mbedTLS 3.6 的支持期只到 2027 年 3 月，4.x 删掉了旧式接口，
  SRT 1.5.7 与 libssh2 1.11.1 都没适配；SRT 的认证加密（AES-GCM）只有 OpenSSL 后端有。
- **librist 不用 OpenSSL**：它的加密只支持 Mbed TLS 或 GnuTLS，而且预共享密钥的随机数（IV）只有这两者能提供——不接任何一个，加密根本起不来（已试过：加密的收发都连不上）。
  所以 `UmbelRIST` 用 librist 源码里自带的 Mbed TLS 3.6.6（只编密码学部分），它支持到 2027 年 3 月，之后随 librist 升级一起换；
  librist 源码里还有 Brad Conte 的 AES/SHA-256（公有领域）与 fast-pbkdf2（CC0），在这个构建里没有用到，仅在许可原文里说明。
- **LGPL 的 libsmb2 怎么满足可重链**：`UmbelSMB2.framework` 是只含 libsmb2 的动态库，`UmbelSMBSource` 通过它的头文件与符号使用它（`Tools/verify_network_libraries.sh` 检查它只依赖系统库、安装名是自己的）。
  App 里要换成自己改过的版本，只需替换这个框架并重新链接，不需要我们的任何源码；构建方法是 `Tools/BuildNetwork/build.sh smb`。许可原文随 `UmbelSMBSource.thirdPartyNotices` 提供，其中写明了这一点与源码获取方式。
- **libnfs 同样**：`UmbelNFS.framework` 是只含 libnfs 的独立动态库，替换它并重新链接即可，构建方法 `Tools/BuildNetwork/build.sh nfs`。
  libnfs 的库部分是 LGPL-2.1+，协议定义（.x 文件）与由它们生成的 `libnfs-raw-*.[ch]` 是 BSD-2-Clause，两份许可原文都在 `UmbelNFSSource.thirdPartyNotices` 里；它的示例程序是 GPL-3，没有构建、没有链接。
- SRT 的源码包没有上游发布的校验和：`VERSIONS` 里的是 GitHub 发布标签归档的校验和，选版本时算出，
  用来防下载内容变化，不是上游担保的值。

## 测试夹具中的第三方素材

只在测试中使用，不随产品分发。

**外部工具**：有的测试要一个真实的服务器或编码器，本机装了才跑，没装就跳过：系统自带的 `sshd`（SFTP）、Homebrew 的 Samba（SMB，GPLv3，`brew install samba`）、
（NFS 的服务器是测试代码里自己写的最小 NFSv3，不需要安装什么）
`mediamtx`、`ffmpeg` 与 `openssl` 命令行。它们只作为独立进程运行，不链接、不随产品分发、不入库；测试里起的服务都只听回环地址，用完即停。

| 素材 | 许可 | 来源 | 位置 |
|---|---|---|---|
| Silkscreen 字体 | SIL OFL 1.1 | github.com/google/fonts（ofl/silkscreen） | `Tests/Fixtures/fonts/`，许可全文 `OFL.txt` 同目录；并作为附件嵌在 `styled_subs.mkv` |

## libdovi 说明

libdovi 的**代码许可**（MIT）是干净的，但它实现的 DV 动态元数据处理
涉及仍在有效期内的专利，且该实现未获得专利持有方授权。

因此由编译开关 `UMBEL_ENABLE_SOFTWARE_DOVI` 控制，**默认关闭**。
是否为某个分发渠道开启，由项目所有者逐次书面决定，不由代码默认值决定。

## 苹果系统框架

AVFoundation / VideoToolbox / AudioToolbox / Metal 等系统框架由 Apple 授权，
使用系统解码器时相关编解码授权由 Apple 承担，本项目无需另行取得。
这是本项目处理 HEVC / DV / 多声道音频的**首选路径**。
