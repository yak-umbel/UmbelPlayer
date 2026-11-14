# 构建空间管理

日常构建使用固定目录，避免每次验证复制整套编译缓存。所有命令在项目根目录运行：

```bash
Tools/swift.sh build
Tools/swift.sh test
Tools/swift.sh run umbel-play /path/to/video.mp4
Tools/check_ios_deployment.sh
Tools/ci.sh
```

`Tools/swift.sh` 保留 Swift 命令的参数、标准输出和退出码，并把构建、包缓存和临时文件放到项目 `tmp/`。
构建结束会更新缓存的使用时间并检查容量；缓存总量超过 10 GiB 时提醒，不自动删除。
直接执行 `swift build` 或 `swift test` 仍会使用 SwiftPM 默认的 `.build/`，建议统一使用上述入口。

`Tools/check_ios_deployment.sh` 用独立 iOS 示例检查框架能否以 iOS 15 为部署目标完成构建，CI 也会执行。
它复用 `tmp/xcode-derived/`，构建日志保存在 `tmp/deployment-checks/ios15.log`；这是编译检查，不代替旧系统运行验收。

| 目录 | 内容和保留方式 |
|---|---|
| `tmp/swift-build/` | 本包构建与测试缓存，日常复用 |
| `tmp/swiftpm-cache/` | SwiftPM 包缓存，可重新获取 |
| `tmp/xcode-derived/` | Xcode 中间产物；手动调用 `xcodebuild` 时指定 `-derivedDataPath tmp/xcode-derived/manual` |
| `tmp/ffmpeg-build/`、`tmp/libass-build/`、`tmp/network-build/` | 依赖库的中间产物；删除后重建依赖会更慢（`network-build` 里有 OpenSSL，重编最久） |
| `tmp/ios-smoke/` | `Tools/IOSNetworkSmoke` 的包副本、模拟器构建缓存与日志（约 1.4 GB）；删除后下次运行重建，约 5 分钟 |
| `tmp/releases/` | 发布归档、匹配的 dSYM 和验证日志，清理工具不删除 |
| `tmp/process/` | 工具运行时的临时文件；不纳入批量清理名单 |

`Tools/archive_release_symbols.sh` 默认将归档与日志写入 `tmp/releases/` 的新目录。
同一次验证的 iOS 与 macOS 构建共用一份中间缓存，退出时删除其独占的缓存子目录。
构建失败也保留日志和已生成的归档。需要调试中间构建状态时，应另行运行 `xcodebuild`。
发布归档需按版本自行备份和管理，不能把归档中的 dSYM 当成缓存删除。

## 清理

```bash
# 预览：列出专用缓存、占用量和是否满足保留期限，不删除文件。
python3 Tools/clean_builds.py

# 删除整棵目录至少 7 天无修改的缓存。
python3 Tools/clean_builds.py --delete

# 明确需要立即释放缓存时，可包括近期生成的缓存。
python3 Tools/clean_builds.py --delete --older-than-days 0

# 只检查容量；超过阈值打印提醒，不删除、不使构建失败。
python3 Tools/clean_builds.py --check
```

可通过 `--older-than-days 14` 或 `--budget-gib 8` 调整期限或提醒阈值。
期限按整棵缓存目录的最新修改时间计算，不依赖文件系统的访问时间。
日常 Swift 入口会在使用后更新目录时间。工具不安装定时任务，也不因超出容量自动删除。

清理仅覆盖表中的五类构建/包缓存，以及兼容旧版本的 `Tools/BuildFFmpeg/build/`、
`Tools/BuildLibass/build/`。不会递归寻找并删除任意名为 `build` 的目录。
旧实验目录需要单独检查；它们可能同时包含源码快照、补丁、录屏和唯一的验证证据。

删除前检查整份候选清单：目录中有 Git 跟踪文件或 `.xcarchive` 就拒绝删除。
候选路径或其父目录是符号链接时跳过；缓存内部的链接只删除链接本身。
运行中的编译、测试进程会阻止删除；无法查看进程时也拒绝删除。请停止构建后清理，
清理完成前不要启动新构建。预览的磁盘块总量可能包含 APFS 共享块，实际回收量以磁盘可用空间为准。

## 实验资料

实验副本只保存必要的源码、脚本、补丁与结论，不复制 `.git/`、`.build/`、`tmp/`、`videos/`。
需要相同版本的二进制依赖时只读共用 `Binaries/`。实验结束后清理编译产物，按需要保留最小复现样本和录像。
源码、Git 历史、正式依赖二进制、测试视频、发布归档与调试符号均不属于自动清理范围。
