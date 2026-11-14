# IOSNetworkSmoke

在 iOS 模拟器里跑可选网络模块（SRT、SFTP、RIST、SMB、NFS）的 iOS 切片：框架能被加载、能运行、能连上服务器读到字节。
不在 CI 里（要模拟器与本机服务器），改了这些模块或它们的库之后手动跑。

## 跑什么

- SRT、RIST、NFS：仓库里现成的完整测试，原样跑；它们的对端（发送端、NFS 服务）都在测试进程里，所以能在 iOS 上编。
- SFTP、SMB：`SmokeTests/` 里的冒烟测试，连本机起的真 sshd 与 Samba（`servers.sh`），读整个文件比对内容，并验证主机密钥、
  加密、来宾、错口令。SFTP 与 SMB 的完整测试用 `Process` 起服务器，iOS 上编不过，所以另写这两个。
- `build.sh --floor`：核心（五个模块都并在它的产品里）用 iOS 15（包的下限）对真机切片编译；测试运行用 iOS 17（SRT 的测试用了 `ContinuousClock`，
  iOS 16 才有），下限没有对应的模拟器，只能靠这一步。

## 用法

```bash
Tools/IOSNetworkSmoke/all.sh                 # 每个已安装的 iOS 版本各一台 iPad 模拟器，最后跑下限编译
Tools/IOSNetworkSmoke/run.sh <模拟器 UDID> <标签>   # 单台；日志 tmp/ios-smoke/<标签>.log
Tools/IOSNetworkSmoke/build.sh --floor       # 只跑下限编译
```

前提：五个 xcframework 已构建（`Tools/BuildNetwork/build.sh`）、`xcrun simctl list` 里有 iPad 模拟器；SMB 要 `brew install samba`，
没装就只跳过 SMB 的测试。副本、构建缓存与日志都在 `tmp/ios-smoke/`，`Tools/clean_builds.py` 管它。

## 覆盖不到的

- 嵌进 .app 与签名：测试包从产物目录加载框架。
- 真实局域网、Wi‑Fi、iOS 的"本地网络"权限、进后台：模拟器不限制，也不是真网络。要验这些得上真机。
- SFTP、SMB 的服务器是 Mac 回环上的，SRT、RIST、NFS 的对端是进程内的。

## 几个坑

- 起服务器要各开一个会话：Samba 结束时会向整个进程组发 SIGTERM。后台启动时要直接启动，用 shell 函数包一层的话 `$!` 是子 shell。
- smbd 必须 `stdin=/dev/null`；目录路径要短（Unix 套接字不超过 104 字节）；非 root 用 `pdbedit` 建用户（`smbpasswd -L` 只能 root）。
- `xcodebuild test` 的 scheme `UmbelPlayer`（包里只有一个产品时，Xcode 只生成这一个，以包名命名）会编所有测试目标，所以副本里只放能在 iOS 上编的。
