# BuildNetwork

从固定版本源码构建可选网络模块背后的 C 库，产出 xcframework 至 `../../Binaries/`。

```bash
Tools/BuildNetwork/build.sh          # 全部模块
Tools/BuildNetwork/build.sh srt      # 只构建 SRT
Tools/BuildNetwork/build.sh sftp     # 只构建 libssh2（SFTP）
Tools/BuildNetwork/build.sh rist     # 只构建 librist（RIST）
Tools/BuildNetwork/build.sh smb      # 只构建 libsmb2（SMB）
Tools/BuildNetwork/build.sh nfs      # 只构建 libnfs（NFS）
```

中间构建产物复用 `tmp/network-build/`，下载源码保留在本目录的 `sources/`。
成品在 `Binaries/`；清理中间产物不会移除成品，见 [空间管理](../../docs/build-storage.md)。
`Package.swift` 只在对应的 xcframework 存在时才声明该模块的目标，并把它并进动态产品 `UmbelCore`；
模块不另出产品（`Tools/check_package_products.py` 守着：Xcode 里的 App 链接不了与动态产品共用目标的产品）。

## 组成与许可

| 模块 | 库 | 许可 | 产物 |
|---|---|---|---|
| `UmbelSRTSource` | SRT 1.5.7 | MPL-2.0（不修改） | `UmbelSRT.xcframework`（`UmbelSRT.framework`，含 `srt.h` 等；模块 `LibSRT` 在包内 `Sources/LibSRT/`，写法 `<UmbelSRT/srt.h>`） |
| | OpenSSL 3.5.9 | Apache-2.0 | 静态并入 UmbelSRT，符号不对外导出 |
| `UmbelSFTPSource` | libssh2 1.11.1 | BSD-3-Clause（不修改） | `UmbelSSH2.xcframework`（`UmbelSSH2.framework`，含 `libssh2.h`、`libssh2_sftp.h`；模块 `LibSSH2` 在包内 `Sources/LibSSH2/`，写法 `<UmbelSSH2/libssh2.h>`） |
| | OpenSSL 3.5.9 | Apache-2.0 | 同一份源码另行静态并入 UmbelSSH2，符号不对外导出 |
| `UmbelRISTSource` | librist 0.2.20 | BSD-2-Clause（不修改） | `UmbelRIST.xcframework`（`UmbelRIST.framework`，含 `librist.h` 等；模块 `LibRIST` 在包内 `Sources/LibRIST/`，写法 `<UmbelRIST/librist.h>`） |
| | Mbed TLS 3.6.6 | Apache-2.0（双许可中选用） | librist 源码里自带的那份，并入 UmbelRIST；librist 不支持 OpenSSL |
| | lz4 1.10.0、cJSON 1.7.13 | BSD-2-Clause、MIT | librist 源码里自带的，并入 UmbelRIST |
| `UmbelSMBSource` | libsmb2 6.3.0 | **LGPL-2.1+**（不修改） | `UmbelSMB2.xcframework`（`UmbelSMB2.framework`，含 `libsmb2.h` 等；模块 `LibSMB2` 在包内 `Sources/LibSMB2/`，写法 `<UmbelSMB2/libsmb2.h>`）；LGPL，所以这个动态库里只有它自己 |
| `UmbelNFSSource` | libnfs 8.0.0 | **LGPL-2.1+**（不修改）；协议代码 BSD-2-Clause | `UmbelNFS.xcframework`（`UmbelNFS.framework`，含 `libnfs.h` 等；模块 `LibNFS` 在包内 `Sources/LibNFS/`，写法 `<UmbelNFS/libnfs.h>`）；LGPL，所以这个动态库里只有它自己 |

每个模块的库先编成静态库（SRT、libssh2 连同 OpenSSL；librist 连同它源码里自带的 Mbed TLS；libsmb2、libnfs 各自单独），再由 `Tools/link_dylib.sh` 链成一个动态库：
只导出自己的名字（`srt_`、`libssh2_`、`rist_`、`smb2_`、`nfs_` 开头），带 dSYM 与隐私清单。名字是本项目自己的，理由与 FFmpeg 相同：
App 里可能另有一份 SRT、libssh2、librist 或 OpenSSL；各模块带的密码学互不暴露，同时选用也不冲突。
各平台都打成动态 framework，切片矩阵、`@rpath` install_name、ad-hoc 签名与 `Tools/BuildFFmpeg` 一致。

## 版本与校验

版本、源码包 SHA256、下载地址都在 `VERSIONS`，脚本只读该文件；每次构建都重新校验源码包。
OpenSSL 的校验和是上游发布的；SRT 上游不发布源码包，其校验和是 GitHub 标签归档的，选版本时算出；
libsmb2 上游也不发布校验和与签名：`VERSIONS` 里是 GitHub 发布标签归档的校验和（同一份下载两次摘要一致），选版本时算出。
libnfs 同样不发布校验和与签名：`VERSIONS` 里是 GitHub 发布标签归档的校验和（同一份下载两次摘要一致），选版本时算出。
libssh2 上游发布签名而非校验和，选版本时已用 Daniel Stenberg 公布的密钥验过签名，`VERSIONS` 里的是验过的那份归档的校验和。
librist 上游既不发布校验和也不发布签名：`VERSIONS` 里是 GitLab 发布标签归档的校验和（同一份下载两次摘要一致），选版本时算出。
升级库时同时更新 `Sources/<模块>/Notices/Texts/` 的许可原文与版本（模块的测试会核对版本与原文）。

## 配置要点

- OpenSSL 用不存在的前缀（`/umbel/net`）配置，装到真实目录时用 `DESTDIR`：OpenSSL 会把安装路径编进库里，
  用真实路径的话库里就有本机路径，`Tools/check_binaries.sh` 会拒收。
- 调试信息里的源码路径靠环境变量 `CCC_OVERRIDE_OPTIONS` 追加 `-ffile-prefix-map`，而不是写进编译参数：
  OpenSSL 会把编译参数记进库里（`OPENSSL_CFLAGS`），那里面就有本机路径。
- librist 用 Meson 交叉编译（每个切片一个 `cross-*.ini`，`pkg-config` 指向 `/usr/bin/false`，免得找到本机 Homebrew 里别的架构的库），
  不装 OpenSSL；它自带的 Mbed TLS 编成 `libmbedcrypto.a`，与 `librist.a` 一起链进动态库。需要 `brew install meson`。
- libsmb2 用 CMake 构建，不装 OpenSSL（AES、MD4、MD5、SHA 是它自带的），关掉 Kerberos 与 GSSAPI（只做 NTLM 与来宾）；
  它的头文件互相用 `<smb2/…>` 包含，框架里没有这个目录，构建只在框架里的副本中把这一个路径改成 `<UmbelSMB2/…>`，库本身不动；
  `libsmb2.h` 自己不包含 `<stdint.h>` 等，包内的 `LibSMB2.h` 先包含它们。
- libnfs 用 CMake 构建，不要 OpenSSL；关掉 Kerberos、TLS、NFSv4.2、多线程与示例，并用 `CMAKE_DISABLE_FIND_PACKAGE_*` 关掉 GSSAPI 与 GnuTLS，免得找到本机 Homebrew 里别的架构的库；
  它的协议子库是 CMake 的 OBJECT 库，已并进 `libnfs.a`；头文件里的 `<nfsc/…>` 与 SMB 一样只在框架里的副本中改成 `<UmbelNFS/…>`。
- 构建后由 `Tools/verify_network_libraries.sh` 复验链接关系（只依赖系统库、安装名是本项目的），失败即中止。

## 构建前置

`brew install cmake ninja`；Xcode 带 macOS、iOS、iOS 模拟器的 SDK。
