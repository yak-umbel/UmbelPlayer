# BuildFFmpeg

按 **LGPL** 配置构建 FFmpeg，产出多平台 xcframework 至 `../../Binaries/`。

## 硬性配置约束

```
不传：  --enable-gpl
不传：  --enable-nonfree
禁用：  libx264 / libx265 / libxvid / postproc 等 GPL 组件
构建：  组件先编成静态库，再链接为 UmbelFFmpeg 动态库（满足 LGPL 的可重链要求）
```

## 交付要求

- 平台：iOS(device + simulator) / macOS / macCatalyst / tvOS / visionOS，arm64 + x86_64
- 可复现：固定 FFmpeg tag 与各依赖版本，产出 SHA256 清单
- 发布前校验（失败即阻断）：
  - `CONFIG_GPL == 0`
  - `CONFIG_NONFREE == 0`
  - `avutil_license()` 返回 `LGPL version 2.1 or later`

## 状态

M0 已实现。

```bash
Tools/BuildFFmpeg/build.sh
```

中间构建产物复用 `tmp/ffmpeg-build/`，下载源码保留在本目录的 `sources/`。
成品在 `Binaries/`；清理中间产物不会移除成品，见 [空间管理](../../docs/build-storage.md)。

版本固定在 `FFMPEG_VERSION`（当前 `n9.0.2`），脚本只读该文件，不内联版本号。
升级依赖时，同时更新 `Sources/UmbelCore/Notices/` 的许可原文和版本表；`ThirdPartyNoticeTests` 会核对。

AV1 软件解码使用 dav1d 1.5.4（BSD-2-Clause）。`DAV1D_VERSION` 固定版本、官方源码包 URL 和
SHA256，`dav1d.sh` 每次检查归档校验和及随包许可全文，再为同样的五个架构交叉编译。
8 位和高位深实现、汇编优化均开启。它静态并入 `UmbelFFmpeg`，不增加宿主要嵌入的 framework，
`dav1d_` 符号不对外导出。

Swift 解码入口显式选择 AV1 实现：VideoToolbox 设备可用时用 `av1`；否则或明确选择软件时用
`libdav1d`。不能只用 `avcodec_find_decoder(AV_CODEC_ID_AV1)`：接入 dav1d 后默认查找会优先选它，
即使设备有 AV1 硬解也会走软件。

## 产物形状

**一个 xcframework**：`Binaries/UmbelFFmpeg.xcframework`。五个库（avutil、avcodec、avformat、
swresample、swscale）先编成静态库，再由 `Tools/link_dylib.sh` 链成**一个动态库** `UmbelFFmpeg`：

- **名字是本项目自己的**：上游的 `libavcodec` 这类名字，App 里另一份 FFmpeg 也在用；
  两个只差大小写的 framework 在 Mac 的磁盘上就是同一个路径，会互相覆盖
- **只导出 FFmpeg 的公开接口**：`av_`、`avcodec_`、`avformat_`、`avio_`、`avutil_`、`avsubtitle_`、
  `swr_`、`swresample_`、`sws_`、`swscale_` 开头的名字，由脚本从静态库里逐个列出；
  内部的 `ff_`、`avpriv_` 不导出
- **链接方式**：导出表里的每个名字都作为必须解析的符号（`-u`）传给链接器，
  和静态库链进程序时一样，只取需要的成员。不能把所有成员都塞进去：
  FFmpeg 会把同一个源文件（比如 Vulkan 的辅助代码）编进好几个库，全部塞进去就重复定义
- **仍是动态库**：整份 FFmpeg 是一个可以替换、可以重新链接的库，LGPL 的要求不变
- **dSYM**：各组件带调试信息编译（`-g`，并用 `-ffile-prefix-map` 把本机路径换成 `/umbel/…`），
  链好后用 `dsymutil` 分出 dSYM，再去掉二进制里的调试信息；`xcodebuild -create-xcframework
  -debug-symbols` 把 dSYM 放进每个切片的 `dSYMs/`
- **不留本机路径**：`--prefix=/umbel`，安装时用 `DESTDIR`。FFmpeg 会把 configure 那一行存进二进制，
  prefix 要是本机目录就会跟着进去

切片有三个：`ios-arm64`、`ios-arm64_x86_64-simulator`、`macos-arm64_x86_64`。每个切片是一个动态
framework（`Tools/framework.sh` 生成，有测试）：iOS 为扁平包，macOS 为带 `Versions/A` 的分版本包；
`Info.plist` 带版本号与最低系统版本，隐私清单 `PrivacyInfo.xcprivacy` 放在系统找它的地方
（iOS 在包的根，macOS 在 `Resources/`）。为什么是 framework：App Store 不收 iOS 应用里的裸 dylib，
而一个 xcframework 不能混装 framework 与普通库。

**头文件**放在 framework 的 `Headers/` 里，一个库一个子目录（`Headers/libavutil/…`）。FFmpeg 的头文件
互相引用写作 `"libavutil/x.h"`，打包时改写成相对路径 `"../libavutil/x.h"`：这样就不再依赖
framework 的名字，也不依赖磁盘是否区分大小写。只改包含行，内容不动（`LICENSES.md` 已注明）。
包内的写法是 `<UmbelFFmpeg/libavutil/avutil.h>`；`import FFmpeg` 的模块声明不在二进制里，
在包内 `Sources/FFmpeg/`（放在二进制里时，iOS 构建会报两份模块描述 "Multiple commands produce"）。

**检查**：`Tools/check_binaries.sh`（install name、导出表、dSYM 与 UUID、没有本机路径、Info.plist、
隐私清单）、`Tools/verify_ffmpeg_license.sh --binaries`（成品里每个库的许可字符串都是
LGPL 2.1 或更新版本，configure 那一行没有 GPL 和 nonfree）、`Tools/check_privacy_manifest.sh`。

tvOS、visionOS、macCatalyst 切片按 spec §2.3 属 M4，`build.sh` 的 `PLATFORMS` 数组预留了扩展位。

## 构建前置

- Xcode 命令行工具
- `meson`、`ninja`、`pkg-config` —— 构建 dav1d，并只在当前架构的安装目录中查找它
- `nasm` —— x86_64 切片的汇编优化必需。缺失时 configure 会**直接中止**，
  不是降级警告。

```bash
brew install meson ninja pkg-config nasm
```

## 易踩的坑

- **不让 configure 自动探测**：它会把本机碰巧装着的库链进来。这台 Mac 上 Homebrew 装的 X11、xcb、SDL2
  就被链进过 macOS 版，换一台没装它们的 Mac 就加载不起来。现在用 `--disable-autodetect`，
  只显式打开 zlib、bzip2、iconv、Secure Transport、VideoToolbox、AudioToolbox 和固定版本 dav1d；
  `Tools/check_binaries.sh` 也会拒绝系统库和本项目库以外的依赖
- **iconv 要显式链接**：关掉自动探测后，configure 只在 C 库里找 iconv（Linux 的做法），苹果的在 libiconv。
  `-liconv` 既传给 configure，也传给我们自己的链接，因为 configure 不会把它写进 `.pc`
- **configure 那一行会进二进制**：`avutil_configuration()` 返回它，里面有 `-ffile-prefix-map` 的本机路径。
  configure 之后把 `config.h` 里的仓库根目录替换成 `/umbel/root`
- **静态构建的依赖写在 `Libs:` 行**：FFmpeg 共享构建时把系统库写在 `.pc` 的 `Libs.private:`，
  静态构建时写在 `Libs:`。脚本两行都读
- **bash 3.2 的空数组**：`set -u` 下展开空数组 `"${a[@]}"` 会报未绑定变量，
  要写成 `${a[@]+"${a[@]}"}`
- **`--disable-postproc`**：FFmpeg 9 已删除 libpostproc，configure 不再认识该选项，
  传了会中止。它原本是 FFmpeg 里唯一的 GPL-only 库，删除对本项目是好事。
