# BuildLibass

从固定版本源码构建 libass 及其依赖，产出 xcframework 至 `../../Binaries/`。

```bash
Tools/BuildLibass/build.sh
```

中间构建产物复用 `tmp/libass-build/`，下载源码保留在本目录的 `sources/`。
成品在 `Binaries/`；清理中间产物不会移除成品，见 [空间管理](../../docs/build-storage.md)。

## 组成与许可

| 库 | 许可 | 链接方式 | 产物 |
|---|---|---|---|
| libass | ISC | 动态库 | `UmbelASS.xcframework`（`UmbelASS.framework`，含头文件 `ass.h`、`ass_types.h`；模块 `LibASS` 在包内 `Sources/LibASS/`，写法 `<UmbelASS/ass.h>`） |
| FreeType | FTL（选用） | 静态并入 UmbelASS | — |
| HarfBuzz | MIT | 静态并入 UmbelASS | — |
| FriBidi | **LGPL-2.1+** | **单独的动态库** | `UmbelFriBidi.xcframework`（`UmbelFriBidi.framework`） |

各组件先编成静态库，再由 `Tools/link_dylib.sh` 链成两个动态库：UmbelASS 只导出 `ass_` 开头的名字，
UmbelFriBidi 只导出 `fribidi_` 开头的名字；两者都带 dSYM 和隐私清单。名字是本项目自己的，理由与
FFmpeg 相同：App 里可能另有一份 libass 或 FriBidi，上游的名字只差大小写就会在 Mac 的磁盘上撞上。
UmbelASS 按 `@rpath/UmbelFriBidi.framework/…` 加载 FriBidi。

FriBidi 单独成库的理由与 FFmpeg 相同：LGPL 的可重链义务靠动态库满足。
各平台都打成动态 framework，理由见 `Tools/BuildFFmpeg/README.md`「产物形状」。
FreeType 选 FTL 而非 GPLv2；FTL 的致谢要求见仓库根目录 `LICENSES.md`。

## 版本与校验

版本、源码包 SHA256、下载地址都在 `VERSIONS`，脚本只读该文件。
升级依赖时，同时更新 `Sources/UmbelCore/Notices/` 的许可原文和版本表；`ThirdPartyNoticeTests` 会核对。
每次构建都重新校验源码包，不只在下载时。

## 配置要点

- 字体由 CoreText 提供，**不用 fontconfig**
- FreeType 不带 HarfBuzz（避免循环依赖）；HarfBuzz 只要整形核心，其余特性全部关闭
- HarfBuzz 默认构建不依赖 C++ 标准库，静态并入 UmbelASS 时不需要链接 libc++
- 调试信息用 `-g` 编译，`-ffile-prefix-map` 把本机路径换成 `/umbel/libass`
- 切片矩阵、`@rpath` install_name、ad-hoc 签名、dSYM 与 `Tools/BuildFFmpeg` 一致
- 构建后由 `Tools/verify_libass_license.sh` 复验链接关系，失败即中止

## 构建前置

```bash
brew install meson ninja nasm
```

`nasm` 用于 libass 在 x86_64 上的汇编优化。

## 一个坑

macOS 自带的是 bash 3.2，没有关联数组；脚本按名字从 `VERSIONS` 取字段，
不要改成 `declare -A`。
