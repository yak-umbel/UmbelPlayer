# 播放诊断与可重复验证

## 视频时间戳与暂停恢复

`UmbelPlaybackDiagnostics` 是默认关闭的结构化事件记录器。每个会话使用一个实例，
供解复用、解码、音频连续性、时钟和内置视频渲染器共享；自定义输出协议无需新增实现。
它只在内存中记录，不回调接入方、不写文件、不发网络请求，也不读取环境变量。
记录不包含媒体内容、分片 URL 或请求头。

```swift
let diagnostics = UmbelPlaybackDiagnostics(capacity: 20_000)
let session = PlaybackSession(
  source: source,
  audioOutput: EngineAudioOutput(),
  videoRenderer: renderer,
  diagnostics: diagnostics)
```

在呈现循环之外定期调用 `diagnostics.snapshot(after: lastSequence)`，用 `JSONEncoder`
逐条导出 `events`，然后将 `lastSequence` 更新为 `latestSequence`。
事件包含同一 `traceID`、递增序号、UTC 可编码日期和单调 host time；时间字段默认以秒计。
无效或非有限时间戳不出现在 `values` 中，不能按零处理。读取不改变播放状态。
事件名和字段可能扩展，采集方应容忍未知事件或缺失字段。

默认环形缓存最多保留 20,000 条事件，不保证覆盖固定秒数。
`overwrittenEventCount` 是记录开始后累计被替换的事件数；若本次第一条事件序号大于
`lastSequence + 1`，则采集已经丢失事件。开启后应每 0.5–1 秒增量导出，不能只在卡顿结束时
读取缓存。压缩包可能比呈现提前约 60 秒被解复用，应保留卡顿前足够长的日志。

| 事件 | 主要观测 |
| --- | --- |
| `session_open` / `session_loaded` | 框架版本、音频输出、渲染器、所选轨道和解码路径 |
| `demux_open` | `playlist` 自有映射、`hlsFallback` 回退或普通 `container` 路径 |
| `hls_segment_open` / `hls_segment_lost` | 分片序号、所属 run、清单起点及长度、跳过的分片 |
| `hls_run_begin` / `hls_run_open` / `hls_anchor` | run 起点、前一 run 的原始结束时间、offset 和保留／重建决策 |
| `demux_packet` | 轨道、原始 PTS/DTS 与整数 ticks、time base、映射后 PTS/DTS、run 或 timeline origin |
| `video_decoded` / `audio_decoded` | 本次解码输入包 PTS、输出帧 PTS、轨道和 seek generation |
| `video_queued` / `video_take` / `video_flush` | 输出、队列 generation、帧 PTS、时钟、队首 PTS、`headMinusClock`、深度和取帧原因 |
| `video_deinterlace_failed` | 去隔行不可用或某次处理没有完成：`reason`，以及自上一条记录起被略去的次数 `withheld`；该帧原样通过 |
| `video_output_switch` | 主画面／PiP 的交接方向及系统呈现路径 |
| `audio_silence` / `audio_overlap` | 预期与输入 PTS、间隙、补静音或跳过的采样数 |
| `audio_anchor` / `audio_anchor_unavailable` | 引擎节点和播放器 sample time、节点 host time、`renderAge`、anchor 及运行状态 |
| `clock_rate` / `clock_reset` / `clock_adopt` | rate、anchor、采纳前后位置、`correction` 和 anchor 年龄 |
| `session_play` / `session_pause` / `session_seek` | 操作意图、seek generation，实际时钟变化另见 `clock_*` |
| `session_seek_path` | 定位走哪条路：`cache` 保留已读缓存、读取接着走；`reread` 清空缓存由解复用器重新定位。附目标与保留后的 `bufferedSeconds` |
| `demux_seek` / `demux_seek_superseded` | 解复用器定位的目标；播放列表定位被后一次取代时记后者，被取代的那次不再读取 |

`video_take` 在同一次队列 actor 操作中取得各字段。`queueDepth` 为取帧后的剩余深度；
`headPTS` 是本次考虑的队首，`framePTS` 是选出的帧。原因包括 `empty`、`future`、
`first`、`due`、`lateLast` 和 `seeded`。没有变化的 `empty`／`future` 最多每秒记录一次，
原因变化和非空取帧立即记录。暂停时等待未来帧属于正常现象，应结合实际 rate 和操作日志判断。
队首 PTS、剩余深度变化或发生丢帧时也立即记录，不受每秒限流影响。
自定义渲染器可能不提供队列事件；系统解码的压缩样本也不能用帧队列深度解释。

原始时间戳指解复用器输出、尚未经过本框架时间线映射的时间戳。在 `hlsFallback` 路径中，
底层 HLS 解复用器已经可能处理过 discontinuity；该路径仍需保留原始清单和分片才能核对容器时间戳。
分片读取事件标记字节流边界，解复用器会预读，不能将当下读取的分片直接认作当前包的精确来源。
解码器会重排或延迟输出，`packetPTS` 表示本次送入的包，不表示每个输出帧都由该包产生。

隔行片源去隔行后，`video_decoded` 按画面记录：一个隔行帧记两条，后一条的 `framePTS` 晚半帧，
条数是画面数，不是解码器输出的帧数。`video_deinterlace_failed` 在每帧都失败时最多每秒记录一条，
`withheld` 是这一秒里被略去的次数；GPU 不可用时只在第一次记录。

独立示例的导出在 utility task 中运行，控制台每条记录以 `[playback-diagnostic]` 开头，
后面是 JSON；覆盖未读取事件时会报告 `lost`。
命令行示例在正常结束和加载失败时都会等待最后一批事件导出，再退出进程。

```bash
Tools/swift.sh run umbel-play <本地文件或独立 HTTP 地址> 120 --engine-audio --diagnostics
```

iOS 示例使用启动参数 `-diagnostics -engine-audio`；另加 `-no-object-audio` 可明确选择引擎解码声音。
原始清单来自本地文件时，需要使用能经 `UmbelSource` 定位并打开相对分片的来源实现，
或通过独立 HTTP 服务提供清单与分片；普通 `UmbelFileSource` 只提供单文件读取。

采集前记录设备、系统版本、框架构建所用修订号及未提交改动。`Umbel.version` 是包版本，
不能代替二进制修订号。修订信息必须来自实际构建记录，不能根据运行时工作区 HEAD 或启动参数
反推已安装二进制的版本。现有二进制缺少可追溯记录时，应从已确认源码重新构建后再采样。

复现时在同一媒体区间比较连续播放、短暂停、长暂停、PiP 进入／退出；保留清单的
`EXTINF`、discontinuity、初始化段和原始分片时间戳，避免重新封装后抹掉异常。
先检查 `video_take.reason == future` 时 `headMinusClock` 是否达到几秒，再逐层追查：
源包已经有间隙、映射后才跳变、解码输出发生变化，或恢复后 anchor 将时钟拉回。
补静音记录可以解释音频时钟继续前进，但不能单独证明间隙的来源。
同时采集现有 `decodingStatistics`；显示驱动的 `errors == 0` 不代表解码器没有拒包或坏帧。

应分别观察调度、帧队列、渲染提交和数据传输。某一层的采样不能替代另一层的实际完成时间。

## HTTP 请求范围与统计

```swift
let http = UmbelHTTPSource(url: url, maximumRangeLength: 1 << 20)
let source = UmbelBufferedSource(wrapping: http)
// 将 source 交给 PlaybackSession，保留 http 以读取统计。
let transfer = await http.transferStatistics
print(transfer.requestCount, transfer.receivedBytes,
      transfer.deliveredBytes, transfer.bufferedBytes)
```

`maximumRangeLength` 的单位是字节。`nil` 保留开放 Range；正数限制单次请求的范围。
非正数会让读取报错，不会静默退回开放范围。
1 MiB 是可用于本地渐进式服务的起始选择，不是所有网络的最优值。更小的范围增加请求次数与往返开销。
范围大小不改变短读语义：第一批字节到达后即可返回，跨范围续读不会向解复用器返回假的 EOF。
当前范围有未消费数据时不预先请求下一个范围；同一会话允许系统复用连接，但不承诺固定连接数量。

有限模式要求服务器正确支持 Range，校验响应范围；忽略 Range 的 `200` 响应不能满足这个约束。
默认开放模式仍允许从位置 0 读取完整 `200` 响应。子来源继承最大范围设置，接入播放列表时也应确认服务支持范围请求。

| 观测值 | 含义 | 不代表什么 |
|---|---|---|
| 服务端成功写出的正文数 | 本机测试服务的写入完成计数 | 客户端已经接收或解码的字节数 |
| `requestCount` | 此 source 发起的请求任务数，包括重试、定位和挂起超时后的续读 | TCP 连接数或重定向次数 |
| `receivedBytes` | 数据委托交付给 source 的累计正文数 | socket 收到的全部字节或内存占用 |
| `deliveredBytes` | 此 source 经 `read` 返回的累计字节数 | 播放进度、唯一文件字节数或解码消费量 |
| `bufferedBytes` | 此 source 当前接收后尚未交付的数据量 | URLSession、内核、代理或上层缓存的总量 |
| `sessionRenewals` | 此 source 遇到请求超时、使后续请求改走新会话的次数（见 [接入指南](integration.md)） | 新建的 TCP 连接数 |

重复读取和重试可能重复计数；统计不是文件偏移。定位会丢弃未消费数据，不能用
`receivedBytes - deliveredBytes` 推算当前缓冲。上层内存缓存、磁盘缓存和解复用预读也会让 source
交付位置领先播放位置。缓存回收应使用自己的数据所有权与保留策略，不能只依赖最后读取偏移。

开放响应的 4 MiB / 1 MiB 水位只依据框架缓冲触发任务挂起和恢复。它不是实际网络传输的硬上限，
已进入网络栈的数据仍可能继续到达。有限范围的效果以服务器遵守范围请求为前提；它不会限制代理自行向上游下载的范围。

任务挂起期间，系统仍按会话的 `timeoutIntervalForRequest` 计时（默认会话为 60 秒）。读取方停下超过这个时长，
挂起的请求会超时；这不是网络故障，source 交付完已收到的数据后，从下一个未交付的字节另发请求续读，
不占用重试次数、也不退避。

设备没有网络时（`notConnectedToInternet` 等四种，见 [接入指南](integration.md)），读取按退避继续等待、不占重试次数，
每次等待后的新请求都计入 `requestCount`，失败请求的 `attempts` 把这些等待算在内；超过 `offlinePatience` 才失败。

`lastFailure` 记录最近一次失败的请求（`HTTPRequestFailure`），之后重试成功也保留；读取被取消或 source 被关闭不算失败。

| 字段 | 含义 |
|---|---|
| `error` | 这次请求失败的原因；是读取的最后一次请求时，就是 `read` 抛出的错误 |
| `urlErrorCode` | 传输途中的网络错误码，如超时 `.timedOut`；服务器以状态拒绝时为 `nil` |
| `errorDomain` / `errorCode` | 传输途中失败时系统错误的域和码：网络错误（`NSURLErrorDomain`，与 `urlErrorCode` 相同），或 URL 层之下的错误，如 CFNetwork 的连接错误；服务器以状态拒绝时为 `nil` |
| `httpStatus` | 收到的 HTTP 状态；为 `nil` 表示没有收到响应 |
| `offset` / `attempts` | 读取的起始位置；这次读取已发出的请求数，含本次 |

`UmbelError.sourceUnavailable` 的说明文字以错误域和错误码表示系统错误（如 `NSURLErrorDomain error -1001`），不随设备语言变化。
需要按失败类型分支时读 `lastFailure` 的字段，不解析说明文字。
地址的协议读不了时错误是 `UmbelError.unsupportedScheme`（如 `rtmp`），不重试；此时 `urlErrorCode` 为 `unsupportedURL`。

请求超时后改走新会话（见 [接入指南](integration.md)）可用 `Tools/SilentConnectionCheck/run.sh` 验收：
本机起一个首条连接中途静默的 HTTP/2 服务，对照系统本身的重试与 source 的续读，需要 Node.js。
做法与判读见 [说明](../Tools/SilentConnectionCheck/README.md)。

## 显示与线程

在 iOS 15 及以上，可选择 `UmbelUI` 的独立显示驱动：

```swift
@MainActor
func beginDisplay(for session: PlaybackSession) -> UmbelDisplayDriver {
  let driver = UmbelDisplayDriver(session: session)
  driver.start()
  return driver // 由控制器持有；退出时调用 stop()。
}
```

驱动在自己的线程和 RunLoop 上接收 `CADisplayLink` 回调，完成状态由线程安全的协调器更新，
不依赖主线程执行完成回调。同一时刻只允许一个呈现调用，忙碌时跳过后续 tick，避免任务堆积。
不要同时为同一 session 启动手动显示循环。`start()`／`stop()` 与视图生命周期控制在主线程调用；
停止后已开始的呈现可能完成，但不会向下一次运行记录结果。若要切换为手动循环，
应等 `statistics.isRendering == false` 后再开始，避免与尚未退出的调用重叠。

暂停播放时保留驱动，以支持字幕和布局重绘。视图脱离窗口或没有可显示的 drawable 时，调用
`setDrawableAvailable(false)`；重新可见时恢复为 `true`。该方法是调用方提供的可见性信号，
不是 Metal drawable 获取成功率指标。应用进入后台后自动停止调度并取消在途调用，回到前台后恢复。
取消会在渲染边界检查；已经开始的 drawable 获取或已提交的 GPU 工作不能被撤回。

**画中画：** 小窗显示的是画给系统显示层的画面。`setPictureInPictureActive(true)` 后，驱动在前台不看
`setDrawableAvailable` 继续呈现；在后台显示回调不触发，改由驱动线程上约每秒 60 次的定时器调用
`renderVideoFrame()`，小窗继续走，关闭后恢复原来的后台停止。把驱动交给 `UmbelPictureInPicture.displayDriver`，
小窗开关时由封装通知驱动。自己驱动呈现的宿主在小窗打开期间，后台也要继续调用 `renderVideoFrame()`。
系统显示路径（包括 DV P5 的原始像素与压缩样本）由系统显示层自行调度，不依赖呈现调用。主视图暂时隐藏不等于结束会话。

`PlaybackSession` 和渲染器可以从异步上下文调用。同步解码模式同样在 UI 线程之外解码；
它不决定显示回调是否由主线程驱动。

图层创建与挂载、视图布局、屏幕尺寸变化、需要主线程的色彩配置，以及画中画控制仍要在主线程进行。
稳定播放的调度可以与主线程分开，不能据此假设任意 CALayer 操作都可跨线程。
获取 Metal drawable 可能等待或返回空；窗口不可见、应用进入后台和输出资源耗尽必须分开观察。

以下指标应保持独立解释：

- 显示回调间隔及回调相对预期时刻的延迟；刷新率改变时预期间隔也改变。
- 忙碌时跳过的回调次数，以及实际呈现调用耗时。
- 渲染队列深度、迟帧丢弃数量和当前帧时间戳；低频采样不能证明采样间隔内的状态。
- drawable 是否可用，以及 GPU 完成或 drawable 呈现回调（若调用方需要实际提交后的观测）。

`PresentedFrame` 是渲染器返回的结果，不是完成上屏的通知。显示刷新率高于视频帧率时，
许多调用正常返回 `nil`；不能把这些调用直接标记为供帧不足。

`driver.statistics` 提供累计计数：`tickCount`、`busyTickCount`、`presentedFrameCount`、
`emptyRenderCount`、`errorCount`、`reportedDroppedFrameCount`。其中 presented 只表示返回了非空结果。
`lastTickInterval`／`maximumTickInterval` 记录实际回调到达间隔，
`lastRenderDuration`／`maximumRenderDuration` 记录调用耗时，单位均为秒；
最大值覆盖此驱动实例的观测历史。`lastError` 可用于错误反馈，`isRendering` 表示是否仍有呈现调用在途。
主线程忙时读取或显示统计本身仍可能晚到，但不会阻塞协调器更新统计。

独立示例默认使用这个驱动。加 `-mainstall 0.2` 每 2 秒阻塞主线程 200 ms，
再加 `-main-display` 切换到主线程参考循环，便于使用同一个构建、同一媒体做 A/B。
这些故意制造停顿的选项只用于示例验收，不应加入产品播放流程。

## 解码背压与硬解异常

发送压缩包返回 `EAGAIN` 表示解码器尚有输出或输入待处理，当前包没有被接收。
框架会先取出积压帧，再重发同一个包；接收单帧失败时继续取帧。发送最多尝试 8 次，
接收连续失败 16 次则报告 `decoderFailure`，避免异常解码器无限占用线程或持续静默丢包。
孤立坏包仍跳过；背压不计作坏包。

来源持续读取而视频队列长期为空，应检查解码器错误和出帧情况，不能仅凭网络增长判定网络不足。
`PlaybackSession.decodingStatistics` 给出各解码器的出帧数、拒收包数和失败帧数，可直接用于这种判断。
正常的帧重排也会暂时不出帧，因此框架不按“连续若干包无输出”直接清空解码器。

软件解码回归覆盖真实 FFmpeg 缓冲占满、原包重试、单帧接收失败、发送失败后的待处理输入，
以及排空和 seek；它能验证 send／receive 状态恢复，不能替代设备上的 VideoToolbox 生命周期验收。
设备回归应覆盖硬解播放时快速退到桌面、自动画中画尚未激活即进入后台、重新回到前台，
观察是否恢复出帧与播放，并检查重复切换、暂停、seek 和播完行为。

iOS 示例的 `-background-decoding` 让画面在后台继续解码，模拟宿主在画中画尚未激活时的状态；
系统随后收走硬件解码器，回到前台时解码器报告会话失效。关掉声音（`audio off`）后缓冲水位由画面决定，
时钟随之停住，追帧不会顺带清空解码器，最接近上述场景。2026-09-29 在 iPad Pro（M4）上用 HEVC Main 10
长片（关键帧间隔 2 s）验收：把收发处理改回修复前的写法构建时，回到前台后不再出帧，解码器以每秒约九千个的速度拒收包，直到读完整部片子；
修复后三轮都在回到前台 0.8–1.5 s 内恢复出帧，失败帧与拒收包各数十个且不再增长。

## 独立 iOS 检查

`Examples/UmbelPlayiOS` 的共享 scheme `UmbelPlaybackChecks` 使用同一套 HTTP 测试文件，
在 iOS 的 Foundation URLSession 上连接进程内独立线程运行的真实 loopback HTTP 服务，
不使用 URLProtocol 替身。测试宿主通过 `-transport-tests` 启动空界面，不打开外部媒体。

在 Xcode 中选择这个 scheme 和 iPad／iPhone，执行 Test。命令行可指定已启动的模拟器：

```bash
xcodebuild test \
  -project Examples/UmbelPlayiOS/UmbelPlayiOS.xcodeproj \
  -scheme UmbelPlaybackChecks \
  -destination 'platform=iOS Simulator,id=<simulator-udid>' \
  -derivedDataPath .build/ios-playback-checks
```

真实设备需要选择本机的开发签名团队。测试正文为确定性生成的数据，无需特定 App、媒体文件或外部服务器。
保留 `.xcresult` 和控制台输出，注明系统版本、设备与请求范围配置。服务端写出量、接收量和交付量应分别报告，
记录停止消费前后差值与测量窗口，不能只记录函数是否调用了 `suspend()`。

模拟器能验证 iOS API、协议连续性与调度隔离；硬件刷新率、实际上屏、后台行为和画中画仍需设备验收。

## 设备验收

1. 用独立示例播放本地或本机 HTTP 媒体，先记录稳定播放的回调间隔、调用耗时和迟帧数量。
2. 加入可控的主线程短暂停顿，比较使用主线程显示循环和独立驱动时的结果。确保测试没有同时改变解码模式。
3. 改变窗口大小、方向与刷新率；验证字幕与暂停后的布局重绘，记录 drawable 不可用的时段。
4. 覆盖后台音频、回到前台、画中画进入／退出（含小窗打开时退到后台）、锁屏、音频中断和退出播放。
   后台只有画中画的画面继续绘制，主视图的 Metal 层不申请 drawable。
5. HTTP 分别运行开放范围和有限范围；停止 source 消费后继续观察服务端写出量，再恢复读取并校验数据连续性。
6. 定位、取消、关闭来源、断流重试和新来源替换后，验证旧请求及时终止且不会把旧数据交给新会话。

主线程优化仍由接入方负责。独立显示调度不能修复接入方的 UI 卡顿，有限范围也不能替代代理的磁盘回收保护。
