# 接入指南

适用于当前 iOS / iPadOS 与原生 macOS 内测范围。先查看 [平台与限制](support.md)，再按 [README](../README.md) 构建二进制依赖。
Xcode 添加本地包后，链接动态产品 `UmbelCore`。内核使用 `import UmbelCore`，画中画另用 `import UmbelUI`；不要把内部支持模块作为宿主 API。

本指南面向任意接入方；“宿主”泛指调用框架的应用，不指某个特定产品。应用集成由接入方负责，本项目通过独立示例与测试工程验证框架。

## 最小播放连接

宿主提供显示层、显示刷新循环与生命周期管理。以下两个辅助函数连接引擎，不包含完整界面。
可运行的参考是 [iOS 示例](../Examples/UmbelPlayiOS/Sources/PlayerViewController.swift) 和 [macOS 示例](../Examples/UmbelPlay/UmbelPlay.swift)。

在主线程创建并挂载 `CAMetalLayer` 和 `AVSampleBufferDisplayLayer`，然后建立支持普通画面、系统显示路径与画中画的组合输出：

```swift
import AVFoundation
import CoreMedia
import Metal
import QuartzCore
import UmbelCore

// The renderer draws; the main actor only owns layout and layer lifetime.
private struct RenderLayerHandle<Layer: CALayer>: @unchecked Sendable {
  let layer: Layer
}

@MainActor
func makeVideoRenderer(
  metalLayer: CAMetalLayer,
  systemLayer: AVSampleBufferDisplayLayer
) throws -> SwitchingVideoRenderer {
  guard let device = MTLCreateSystemDefaultDevice() else {
    throw UmbelError.videoRenderUnavailable(reason: "Metal device unavailable")
  }
  let metal = RenderLayerHandle(layer: metalLayer)
  let system = RenderLayerHandle(layer: systemLayer)
  let tolerance = CMTime(seconds: 0.02, preferredTimescale: 600)
  let main = try MetalVideoRenderer(
    layer: metal.layer, device: device, tolerance: tolerance)
  let secondary = try SampleBufferVideoRenderer(
    layer: system.layer, device: device, tolerance: tolerance)
  return SwitchingVideoRenderer(main: main, pictureInPicture: secondary)
}
```

这里的 `@unchecked Sendable` 是宿主对图层访问纪律的窄范围承诺，不表示 `CALayer` 的任意跨线程操作都安全。
系统显示层初始化会设置时间基准，因此该工厂必须在主线程运行。若只需要普通像素路径，可直接传入 `MetalVideoRenderer`。

用 Xcode 16.x（本包的持续集成用 16.4）并启用 Swift 6 语言模式构建时，该 SDK 尚未把 `MTLDevice` 标为可跨线程传递：
把同一个 `device` 交给渲染器的文件会报 `sending 'device' risks causing data races`。
把该文件的 `import Metal` 改成 `@preconcurrency import Metal` 即可；较新的 SDK 不需要。本包自己的示例和测试就是这样处理的。

```swift
import Foundation
import UmbelCore

func openMedia(
  at url: URL,
  videoRenderer: any VideoRenderer,
  headers: [String: String] = [:],
  videoDecodingMode: UmbelVideoDecodingMode = .synchronous
) async throws -> PlaybackSession {
  let source: any UmbelSource
  if url.isFileURL {
    source = try UmbelFileSource(url: url)
  } else {
    source = UmbelBufferedSource(
      wrapping: UmbelHTTPSource(url: url, headers: headers))
  }
  let session = PlaybackSession(
    source: source,
    audioOutput: SampleBufferAudioOutput(),
    videoRenderer: videoRenderer,
    videoDecodingMode: videoDecodingMode)
  do {
    try await session.load()
    return session
  } catch {
    await session.stop()
    throw error
  }
}
```

保留返回的 session 与 renderer，配置音频会话和显示循环后调用 `try await session.play()`。
未传入 `audioOutput` 不会自动建立声音输出，未传入 `videoRenderer` 也不会自动建立画面。
一个 session 对应一个来源；`stop()` 会关闭来源并终止该实例，换片或重新打开应建立新 session。

对于需要限制单次预取范围的 HTTP 服务，可显式设置最大 Range 长度：

```swift
let source = UmbelHTTPSource(url: url, maximumRangeLength: 1 << 20)
```

默认 `nil` 保留开放 Range。有限 Range 仍然边收边交付，不等待整个范围下载完毕；
消费完当前范围且再次读取时，才请求下一范围，仍走当前会话（超时后的更换见下文）。
服务器必须正确响应范围请求；有限模式不自动回退为整文件下载。
这限制的是每次请求的范围，不是 App 内存、代理上游预取或播放位置与读取位置之间的差距。
传输统计与验证方法见 [播放诊断](playback-diagnostics.md)。

请求超时后，后续请求改走新会话：超时的请求可能把连接留在会话的连接池里，连接没断却不再有数据，
HTTP/2 会把下一个请求排到这条连接上，同一会话里的重试于是同样超时。传入的 `session` 没有 delegate 时，
source 按它的配置自行新建；带 delegate 时（例如自定义证书校验或登录处理）需传入 `makeSession`，否则保持原会话：

```swift
let source = UmbelHTTPSource(url: url, session: session, makeSession: { makeMediaSession() })
```

`makeSession` 每次返回一个新会话，配置与 `session` 相同；被替换或不再使用后由 source 使其失效，
传入的 `session` 本身不会被失效。由 `source(for:)` 打开的来源（如播放列表分片）共用同一次更换。
只有请求超时会触发更换；读取方停下导致的挂起超时、服务器错误状态都不会。

在创建时传入 `videoDecodingMode: .asynchronous` 可开启引擎级单包前瞻；默认 `.synchronous`。
两种模式都在界面线程之外解码，保留原有硬件优先与软件回退策略；音频与缩略图解码不变。
开启后，私有串行队列可在上一包的结果等待渲染容量时解码下一包，最多两个在途包任务；
这不是原生 VideoToolbox 异步提交／回调模式。下一包尚未到达时，前瞻可能增加一个包间隔的启动延迟，不保证加速。

`await session.videoDecodingMode` 是不可变的请求值；更换模式需停止当前实例并创建新来源和 session。
`await session.videoDecodingStatus` 报告实际选中的 `.synchronous`、`.asynchronous` 或 `.systemManaged` 路径，
加载成功前、停止后或没有视频输出时为 `.inactive`。视频临时挂起时仍报告选中的路径，不作为解码忙闲指示。
DV P5 无论请求哪种模式都走 `.systemManaged`，不会因此开启软件 P5 处理。详见 [接口说明](playback-controls.md#video-decoding-mode)。

创建时传入 `videoDecoder: .init(preference: .software, softwareThreadCount: 8)` 可选择解码器；不传则与以前完全一样。
`preference` 为 `.hardware`（默认，能硬解就硬解、硬解不了回退软解）或 `.software`（一律软解，即使硬件本来可以解）；
这是偏好而不是强制，系统解码的画面（DV 交系统显示、P8.1／P8.4 由系统解成像素）不经过这条路径，不受影响。
`softwareThreadCount` 只在软解时有效，硬解时忽略；`nil` 由解码器自己定（核数加一，最多 16）。可选的档位是
`UmbelVideoDecoderConfiguration.softwareThreadCounts`，即 1、2、4、6、8、10、12、14、16；其它值取其下一档（7 → 6），小于 1 取 1，大于 16 取 16。
帧线程的代价：H.264、HEVC、VP9 等多数编码在线程数为 *n* 时，首幅画面与每次跳转后的首幅画面晚 *n* − 1 帧，内存里多 *n* 帧在途的画面（4K 10 位每帧约 25 MB）；
AV1 由单独的解码库分工，延迟为线程数的平方根（向上取整，16 线程时 4 帧）。
两项和 `videoDecodingMode` 一样在整个会话里保持：后台回来、跳转后重建、播放列表换了编码、系统拒绝 DV 后改在这里解基础层，重建的解码器都按同样的设置做；
要换就停止会话、新建一个。

`await session.videoDecoderConfiguration` 是请求值；`await session.videoDecoderStatus` 报告实际在用的：`.hardware`、`.software(threads:)`（线程数；AV1 且未指定时为 `nil`）、
`.systemManaged`，加载成功前、停止后或没有视频输出时为 `.inactive`。它反映实际情况：选了硬解而这个片源硬件解不了，或系统解码器看到码流后拒绝，都会显示 `.software`，
宿主据此与 `videoDecoderConfiguration.preference` 对比，就能提示「选了硬解但回退成了软解」。详见 [接口说明](playback-controls.md#video-decoder-preference)。

## 显示、布局与退出

渲染器不创建显示循环。宿主随屏幕刷新调用 `try await session.renderVideoFrame()`，将调用串行化；一次调用未结束时跳过后续 tick，避免堆积 `Task`。
暂停时仍需保留刷新通路，以支持字幕、布局和画中画切换等变化。渲染错误应反馈到宿主状态，不宜长期静默忽略。

iOS 可持有 `UmbelUI.UmbelDisplayDriver(session:)` 并调用 `start()`，使用独立线程的显示回调；
退出时 `stop()`，不与手动显示循环并用。前台暂停时保留刷新，后台停止前台呈现；
画中画小窗打开时例外，驱动在后台改用定时器继续为小窗呈现（见下文「音频会话、后台与画中画」）。
主 RunLoop 上的显示回调会受主线程工作影响；`renderVideoFrame()` 调用耗时短并不能排除回调晚到。
`PresentedFrame.droppedFrames` 统计本次取帧前丢弃的迟帧，呈现调用晚到和供帧不足都可能影响这一数值，
不能仅凭它判断解码性能。返回 `PresentedFrame` 也不表示 GPU 已完成或画面已经上屏；
没有新帧到期时返回 `nil` 是正常情况。显示驱动接入、线程边界及验收步骤见 [播放诊断](playback-diagnostics.md)。

要知道首帧或某次跳转的画面是否已经出来，不要靠播放进度推断（进度到了目标、`phase` 变成 `.playing`，都不说明目标画面已显示；
暂停时进度根本不走）。读 `session.firstPresentedFrame`：它是会话开始以来或最近一次跳转开始以来呈现的第一幅画面，之前为 `nil`。
`seek(to:)` 返回后读 `session.seekGeneration`（每次 `seek(to:)` 加一；换音轨、画面挂起恢复、系统播放器交还声音时会话自己的重定位也计数），
`firstPresentedFrame?.seekGeneration` 达到它，就是这次跳转的画面已经交给渲染器显示，暂停状态同样适用。
`renderVideoFrame()` 返回的每个 `PresentedFrame` 也带 `seekGeneration`，自己驱动显示循环的宿主可直接比对。
这个信号的含义是渲染器的呈现调用收下了这幅画面（已解码、已交给显示层），不保证画面已上屏；显示循环由谁驱动都能读到。
画面出来之后的断流，与续播尚未出画就失败，由此可以分开：前者 `firstPresentedFrame` 已有值。
系统自己显示画面的路径（DV P5）同样给出信号：画面交给系统显示层时上报，暂停时跳到两个画面之间的位置也是，
上报的是该位置之后的第一幅画面。

主线程随布局更新图层范围，并将 `CAMetalLayer.drawableSize` 设为视图点尺寸乘屏幕缩放系数得到的像素尺寸。
渲染器管理像素格式、色彩空间和扩展动态范围设置，宿主不要在布局回调中覆盖它们。
iOS 示例将系统显示层放在 Metal 层下面；P5 主画面由前者显示，后者叠加透明字幕。

`session.pictureFrame` 是相对视图的归一化画面矩形，使用左上原点；fill 裁剪时矩形可以超出 `0...1`，未呈现或输出不支持报告时可以为 `nil`。
计算可见视频区域应取画面矩形与视口的交集，排除 fit 留下的黑边。

流声明了旋转时，画面在绘制时转正：`UmbelTrack.VideoDescription.displayWidth` / `displayHeight`、`VideoFrame.displaySize`、
`pictureFrame`、比例覆盖（`setAspectRatio`）和 fit／fill 都按转正后的画面计算；字幕不跟着转。
自定义 `VideoRenderer` 收到的 `VideoFrame` 带有 `rotation`，其 `displaySize` 已含旋转，渲染器要按 `rotation` 绘制，
否则存储方向的画面会被画进转正尺寸的画布。DV P5 的系统显示路径不转，帧的 `rotation` 为 `.none`。
会话为四分之一转的轨道调用 `prepare(width:height:pixelAspectRatio:color:)` 时，传入的是转正后的显示宽高、像素宽高比为 1，
不是存储像素；首帧到来后以帧自带的尺寸为准，帧的 `width` / `height` 始终是存储像素。

隔行片源默认去隔行：每个隔行帧变成两幅逐行画面，相隔半帧，渲染器（包括自定义的）收到的都是逐行帧，
画面数和 `PresentedFrame` 按场计，不要把帧时间间隔当作片源的帧率。`session.setDeinterlacing(.off)` 从下一个解出的帧起关闭；
未标隔行的帧不受影响。去隔行在 GPU 上执行，失败时该帧原样通过（会有梳状纹），不会让播放失败。

退出播放时先停显示循环与状态刷新任务、取消片段提取与预览请求，协调关闭画中画，再 `await session.stop()` 并释放图层与控制器。
若仍在画中画播放，主界面暂时消失不应被当作退出播放。

## 状态、控制与错误

`PlaybackSession` 是 actor。UI 从异步属性读取 `phase`、`currentTime`、`duration`、`bufferedDuration`、`tracks` 与选中轨道，再在主线程更新。
当前没有承诺状态 publisher 或 delegate；宿主可管理一个可取消的轮询任务。
直播或未知时长不要直接将 `duration.seconds` 当作有限数字显示；先检查 `duration.isNumeric`。

| 操作 | 接入约定 |
|---|---|
| `load()` / `play()` | 处理抛出的错误；开始播放可能先进入 `.buffering` |
| `pause()` / `seek(to:)` | seek 前检查 `isSeekable`，并处理实际调用失败；seek 保留播放／暂停意图；seek 到片尾或之后进入 `.ended`，像素路径显示最后一帧。前进到已读缓冲内时保留缓冲、不重新请求数据，`bufferedDuration` 相应减少而不归零；seek 未完成期间 `currentTime` 报目标位置 |
| `setRate(_:)` | 有效范围 0.5–2，保持音高 |
| `setVolume(_:)` / `setMuted(_:)` | 音量为 0–1，静音单独保存 |
| `selectAudioTrack(_:)` | 从 `tracks` 的音频轨道取 ID；`nil` 关闭音频轨道。`isDecodable` 为 false 的轨道（如 AC-4）不会被自动选中，手动选择抛出 `unsupportedCodec` 且原音轨保留；没有可解码的音轨时只播画面 |
| `setAudioDelay(_:)` | 单位秒，正数表示声音较晚；不 seek，过渡行为见 [接口说明](playback-controls.md) |
| `videoCapabilities` | 加载、seek 或输出变化后重新查询；按结果启用比例、缩放、颜色调节和截图入口 |
| `setVideoAdjustments(_:)` | 亮度 -1–1，对比度与饱和度 0–2；默认 0／1／1，`.init()` 复位；先查询 `canAdjustColors` |

异步管线失败会表现为 `phase == .failed`，原因读取 `failureReason`；不能只处理 `play()` 抛出的错误。
诊断打点可读 `decodingStatistics`：长时间 `.buffering` 而来源仍在读取时，出帧数不涨、拒收包数或失败帧数上涨，
说明问题在解码器而不在网络；它只用于记录，不必据此控制播放。
`UmbelError.isRetryable` 是重试提示，宿主仍需限制重试次数并提供停止入口。持有 `UmbelHTTPSource` 时，
`lastFailure` 可区分超时与服务器拒绝，见 [播放诊断](playback-diagnostics.md#http-请求范围与统计)。片段提取还可能抛出 `CachedAudioError` 或取消错误。
地址的协议读不了时（如把 `rtmp://` 交给 `UmbelHTTPSource`）报 `UmbelError.unsupportedScheme`，只带小写的协议名、不带地址；`isRetryable` 为 `false`，同一地址重试不会有结果。
设备没有网络时（系统对每个请求立即返回「没有网络」一类错误：`notConnectedToInternet`、`dataNotAllowed`、`internationalRoamingOff`、`callIsActive`），
`UmbelHTTPSource` 不占重试次数地等待，最多 `RetryPolicy.offlinePatience`（默认 60 秒）：已缓冲的内容照常播放，用完后 `phase` 为 `.buffering`，
网络恢复后在原位置续读；seek、取消与 `invalidate()` 立即打断等待。这几种错误与服务器无关，换地址没有用；`networkConnectionLost`、
`cannotConnectToHost`、`cannotFindHost`、`dnsLookupFailed` 等仍走 `maxRetries`。耐心按墙上时间计，不知道暂停；设为 0 即按其他瞬时故障处理。
是否提示「没有网络」由宿主决定，引擎只给 `.buffering`。
来源中断时（耐心用尽、服务器出错等），已缓冲的内容播完后会话进入 `.failed`，来源恢复后也不会自行重连。重试可在同一会话记下 `currentTime`、`seek(to:)` 回去再 `play()`，也可新建会话后 seek 到该位置。

## 字幕、控件避让与截图

默认 `compositesSubtitles: true`，引擎合成文字、ASS 与位图字幕。仅当宿主自行绘制时设为 `false` 并调用 `renderSubtitles(in:)`，避免两条字幕绘制路径同时运行。
外挂字幕通过 `addExternalSubtitle(_:language:title:)` 添加后，必须将返回轨道的 `id` 传给 `selectSubtitleTrack(_:)` 才会选中。
现有单字幕接口操作主字幕；传 `nil` 关闭主字幕，`selectSubtitleTrackAutomatically()` 恢复主字幕的自动选择规则。

副字幕使用 `selectSubtitleTrack(_:for: .secondary)`，初始关闭，默认向上偏移视频画布高度的 20%。
文字、ASS、内嵌位图和外挂 PGS `.sup` 均可选入任一字幕槽；两槽也可以选同一轨道。
`setSubtitleDelay`、`setSubtitleScale`、`setSubtitlePlacement` 的 `for:` 重载分别控制每槽，关闭其中一槽不会关闭另一槽。
默认偏移不保证所有 ASS 图案互不重叠，接入方可独立调整位置与大小。

控制栏出现时调用 `setSubtitlePlacement(.init(bottomInset: fraction))`，隐藏后设回 `.init()`。
`fraction` 的分母是**可见视频画布高度**，分子是从该画布底边算起需避让的高度，两者需先换算到相同坐标单位。
例如控件占用 240 点视频画布底部的 48 点，传入 `0.2`。位于黑边里的控件不应重复算入视频避让；系统 safe area 的点值不能直接传给引擎。

`verticalOffset` 同样以可见视频高度为基准，正数向上。每个字幕槽内的内容作为整体移动，ASS 中显式定位的图案也包括在内。
使用双字幕时，需分别对 `.primary` 与 `.secondary` 设置控件避让；恢复时保留各自需要的偏移。
暂停时调整会请求即时重绘。截图中的字幕按相同相对位置规则处理，但截图是完整视频画面，不包括宿主控件，也不复制视口 fit / fill 的裁剪结果。
截取前查询 `videoCapabilities.snapshot`，再调用 `snapshot(includingSubtitles:)` 并处理错误。完整契约见 [接口说明](playback-controls.md)。

颜色调节只作用于视频，保留字幕颜色；暂停时设置会请求重绘，seek 和画中画输出切换保留设置。
截图使用相同调节参数，但始终输出 SDR；HDR 与 SDR 的运算域和参考白值见 [接口说明](playback-controls.md)。

## 进度预览

使用独立的 `UmbelThumbnailGenerator` 获取指定时间的画面，无需对播放 session 定位：

```swift
func makePreviews(url: URL, headers: [String: String] = [:]) -> UmbelThumbnailGenerator {
  UmbelThumbnailGenerator {
    if url.isFileURL { return try UmbelFileSource(url: url) }
    return UmbelBufferedSource(wrapping: UmbelHTTPSource(url: url, headers: headers))
  }
}
```

每次工厂调用必须新建独立来源，不能返回正在播放的 source。自定义认证与子资源策略同样经该来源注入。
保留一个 generator，并以可取消的 `Task` 调用 `thumbnail(at:maximumSize:)`；拖动到新位置时取消过时请求。
每个 generator 同时执行一个请求，取消排队请求不会打开来源。显示时间应读取结果的 `presentationTime`，不能假定与请求完全相同。

结果是保持显示比例、限制像素尺寸且不放大的 SDR `CGImage`，不含字幕，也不继承播放中的颜色设置。
直播、不可定位来源和 P5 系统显示路径暂不支持；需处理 `UmbelThumbnailError`、来源错误和取消错误。
默认大小、时间边界和资源释放契约见 [接口说明](playback-controls.md)。

## 缓存 PCM 与自定义来源

先用音频轨道 ID 查询 `cachedAudioRanges(for:)`，选择完整落在一个覆盖区间内的 `CMTimeRange`，再以可持有的 `Task` 调用 `extractCachedAudio(for:range:)`；取消时调用该任务的 `cancel()`。
查询与提取之间缓存可能变化，仍需处理 `missingCoverage`。返回结果的 `coveredRanges` 与每帧时间戳是实际覆盖，不应把请求时间原样标在 PCM 上。

默认每轨保留最近读入的 30 秒压缩包、所有轨道合计不超过 8 MiB；每次提取最多返回 64 MiB PCM，可在 session 初始化时调整。
这包含预读数据，不保证播放点之前有 30 秒历史；需要重新读取的 seek 会清空保留区间，前进到已读范围内的 seek 保留它（读取接着原处继续），已取得快照的提取可独立完成。
提取不 seek、不读取来源补洞，返回分平面 Float32；样本布局、解码历史限制和内存上限详见 [接口说明](playback-controls.md)。

`UmbelDiskCacheSource` 的磁盘字节缓存与上述音频保留缓存用途不同，磁盘已有数据不代表它可立即经 PCM 接口提取。
宿主的网络认证、代理或自有缓存统一经 `UmbelSource` 注入：

- 随机读取实现 `UmbelRandomAccessSource`；仅顺序读取实现 `UmbelStreamingSource`。
- `read` / `readNext` 的空结果表示 EOF，不是暂时无数据；等待或暂时故障应按协议等待或抛错。
- HLS 自定义来源还需提供 `UmbelLocatedSource`，让播放列表、分片和密钥使用相同网络策略；`location` 应反映重定向后的地址。
- 包装器转发 `locatedSource`；`source(for:)` 负责子资源的请求策略。不要让子资源绕开宿主数据源。
- `invalidate()` 应释放资源、可重复调用，并让后续读取抛出中断错误。
- 来源读不了地址的协议时抛 `UmbelError.unsupportedScheme`。直接抛出系统的 `URLError(.unsupportedURL)` 且带失败地址时，`failureReason` 也归到这一类；包成其他错误再抛则不会。
- `read` / `readNext` 应响应任务取消：播放器在读到的内容不再需要时（跳转到尚未读取的位置、关闭会话）取消正在读取的任务，
  读取此时应尽快结束并抛 `UmbelError.interrupted`（或 `CancellationError`）。取消只针对这一次读取，不关闭来源，之后的读取照常服务；
  不响应取消的来源，跳转要等那次读取自己返回。

### 内置的网络来源

- `UmbelLiveHTTPSource(url:headers:session:)`：HTTP 直播（HTTP-FLV、HTTP-TS 或任何不结束的响应体）。不发 `Range`，会话报告不可 seek。
  第一个字节之前的失败会重试（`startRetries`，默认 2 次，只重试 5xx、408、429 与瞬时的网络错误，如超时、连接丢失、没有网络）；字节交付之后断开一律报 `sourceUnavailable`，不续读。
- `UmbelNetworkStreamSource(url:configuration:)`：`rtmp`、`rtmps`、`rtmpt`、`rtmpts`（后两者把 RTMP 套在 HTTP 请求里，给其他都不通的网络）、
  `udp`、`tcp`（MPEG-TS 直连）。构造时校验：其他协议抛 `unsupportedScheme`；
  `tcp`、`udp` 地址里的选项只放行 `pkt_size`、`fifo_size`、`overrun_nonfatal`、`buffer_size`、`reuse`、`sources`、`localaddr`，其余抛 `sourceUnavailable`
  （例如 `listen=1` 会让播放器开端口等对端，不放行）。RTMP 各形态的查询串原样交给服务器。
  连接超过 `connectTimeout`（默认 15 秒，含与服务器的第一轮交换）或已连上后超过 `stallTimeout`（默认 20 秒）没有数据，报 `sourceUnavailable`。
  证书一律校验，没有关闭校验的开关；自签名环境用 `certificateAuthorityFile` 给出信任的证书（PEM）。
  系统对 TLS 服务端证书有要求，自签名证书也一样：要含服务器认证用途（`extendedKeyUsage=serverAuth`）、证书名与地址一致（IP 地址写进 `subjectAltName`）、
  有效期不超过 398 天，否则交了文件也过不了，报 `sourceUnavailable`。
- `UmbelRTPStreamSource(url:configuration:)`：`rtsp` 与 `rtp`。它们的解封装器自己开连接、给出的是包而不是字节流，来源把包整理时间戳后写进内存里的一个容器
  （先试 Matroska，装不下换 NUT，再换 MPEG-TS），交给播放管线；编码原样通过，不解码。`rtsp` 默认走 TCP（`transport` 可选 UDP）；
  `rtp://` 加入发往某个 UDP 端口或组播地址的流，地址里没有流的描述，只有 FFmpeg 无需描述就能认出的（MPEG 传输流）才能这样播。
  `rtp` 地址的选项与 `udp` 一样受限；`rtsp` 地址的查询串原样交给服务器。**这两个协议的流结束也报 `sourceUnavailable`**：
  FFmpeg 的解封装器在服务器正常结束与连接被切断时的表现相同，而对直播来说后者才是必须告知的。
- `UmbelFTPSource(url:configuration:)`：`ftp://主机/路径` 上的一个文件，**随机读**，会话可以 seek（从别处读会让服务器从那里开始，即重连）。
  需要登录时把 `用户:密码@` 写进地址，否则匿名。FTP 不加密，登录与文件内容都是明文。读取被取消时立刻放弃，连接状态不明，会关掉，下一次读取重新连。
  不重试：读失败就报，由宿主决定。
- 这些来源都由宿主创建与持有：停止会话不会关闭来源，调用 `invalidate()`（或释放来源）才放掉连接。
  取消某一次读取只让这一次返回 `interrupted`，来源本身继续。
- 断流与流结束在字节层分不开：服务器正常发出结束通知时是流结束（RTMP、TCP），其余情况（连接被重置、无数据、网络中断）都是 `sourceUnavailable`。
  来源不会重连，重连会把第二个容器头交给同一个解封装器；要继续看就重新创建来源与会话。
- 这些来源的连接是 FFmpeg 自己的，不经过系统代理与 App Transport Security；`rtmp`、`rtmpt`、`rtsp`、`rtp`、`udp`、`tcp`、`ftp` 不加密。
  UDP 不重传，iOS 上用组播需要宿主自己申请系统的组播权限。
- iOS 上连接局域网里的服务器要有“本地网络”权限：宿主在 `Info.plist` 里写 `NSLocalNetworkUsageDescription`，用户第一次连局域网地址时系统弹窗询问。
  **用户回应弹窗之前，到局域网地址的 TCP 连接会立刻失败**，底层错误是 `EHOSTUNREACH`（errno 65）；回应之后新建的连接才通。实测 SFTP、SMB、NFS、RTSP、RTMP 都是如此：SFTP 报 `network error 65`，RTSP、RTMP 的错误里是 -65（FFmpeg 的负数写法），SMB 与 NFS 只报固定的话（`connection failed`、`mount failed`），这些都和真的没有路由分不开。所以在 iOS 上局域网来源一开始就连不上，先看这个权限的状态。
- 错误里没有地址（地址常带令牌或密码），只有协议名与错误码；宿主记录日志时同样不要写入完整地址。
- 直播流自己在元数据里声明了时长时，`duration` 就是所声明的值；没有声明的是不定时长，先检查 `duration.isNumeric`。
  时间从加入处算起，流的时间戳起点不是零也没有影响。直播不支持 seek 与进度预览。

### 可选模块

需要额外 C 库的协议做成可选模块，只在对应的库构建过时才出现在包里（先 `Tools/BuildNetwork/build.sh <模块>`）。构建过的模块并在动态产品 `UmbelCore` 里，没有要另外添加的产品，用 `import Umbel<名>Source` 引入：模块若是自己的产品，Xcode 会在它里面再带一份 `UmbelCore`，App 链接不了（`Tools/check_package_products.py` 守着这一点）。
代价是 App 带哪些模块，由构建这个包的机器上 `Binaries/` 里有哪些 `Umbel*.xcframework` 决定，App 里不能逐个挑；不用的模块就不要构建它的库。
除 NFS 外，这些模块的库都带加密实现（OpenSSL、Mbed TLS，libsmb2 自带的 AES）；带上它们，宿主申报出口合规时要算进去。

- `UmbelSRTSource(url:configuration:)`（`import UmbelSRTSource`）：`srt://主机:端口`，播放端是调用方，发送端是监听方。
  `?latency=`（毫秒）、`?streamid=`、`?passphrase=` 也可以放在 `Configuration` 里（`Configuration` 优先）；口令 10 到 79 个字符，
  对端要口令而这里没给或给错，在连接时被拒，报 `sourceUnavailable("connection rejected (reason N)")`，错误里没有口令与地址。
  `mode=listener`、`mode=rendezvous` 这类会让播放器开端口的选项一律拒绝，地址里只放行上面三个选项。
  SRT 分不出发送端结束与丢失，所以流结束也报 `sourceUnavailable`。连接是 SRT 自己的，不走系统代理与 App Transport Security。
  SRT 库自己会往标准错误写警告与错误（对着真发送端读时每秒几十行），模块已把它的日志关到只剩致命级别；失败只以抛出的错误告知宿主。
  模块自带的第三方许可原文：`UmbelSRTSource.thirdPartyNotices`（SRT 与随它链接的 OpenSSL；MPL-2.0 要求的源码获取方式写在其中）。
- `UmbelSFTPSource(url:configuration:hostKeyVerifier:)`（`import UmbelSFTPSource`）：`sftp://用户@主机[:端口]/路径`，随机读、可 seek、加密。
  **`hostKeyVerifier` 是必填的**：每次连接都会拿服务器出示的主机密钥（`HostKey`，含 `fingerprint`，即 `ssh-keygen -l` 打印的 `SHA256:…`）问你，
  返回 `false` 就在发出任何凭据之前断开，报 `sourceUnavailable("host key not trusted")`。可信指纹是固定几个时用 `UmbelSFTPSource.trusting(fingerprints:)`；
  首次连接要让用户确认的，就在自己的 verifier 里做（它在来源的读取线程上被调用，不要在里面等界面）。
  登录：地址里的 `用户:密码@`，或 `Configuration.authentication`（`.password`、`.privateKey(file:publicKeyFile:passphrase:)`，后者优先）；
  地址里的用户名与密码按字面使用（已做百分号解码）。地址不放行任何选项。错误里没有地址、用户、密码与密钥。
  读取被取消时放弃并关闭连接，下一次读取重新连接并重新校验主机密钥；`invalidate()` 之后不能再用。连接是 libssh2 自己的，不走系统代理。
  模块自带的第三方许可原文：`UmbelSFTPSource.thirdPartyNotices`（libssh2 与随它链接的 OpenSSL）。
- `UmbelRISTSource(url:configuration:)`（`import UmbelRISTSource`）：`rist://主机:端口`，播放端是调用方，发送端是监听方（如 `ristsender` 的 `rist://@主机:端口`）。
  地址里放行的选项：`buffer`、`buffer-min`、`buffer-max`、`reorder-buffer`、`rtt-min`、`rtt-max`、`bandwidth`、`return-bandwidth`、`secret`、`aes-type`（128 或 256）、
  `key-rotation`、`compression`、`cname`、`virt-dst-port`、`session-timeout`、`keepalive-interval`、`congestion-control`、`timing-mode`、`min-retries`、`max-retries`；
  其余一律拒绝（`miface`、`local-port`、`profile`、`username`、`password` 等），每个选项只能出现一次，数值要在范围内。`buffer`、`secret`、`aes-type` 也可放在 `Configuration` 里（`Configuration` 优先）。
  口令不经过地址文本交给库，所以其中的 `&`、`=`、`/` 等字符原样有效（放进地址时要百分号编码）。`profile` 默认 `.main`，也可 `.advanced`。
  `@` 开头（让播放器监听端口）的地址拒绝。**RIST 不校验口令**：口令不对时拿到的是没有数据（连接超时）或不是码流的字节，不是错误。
  恢复缓冲区决定接收端为等待重传把码流压后多久，也就是首帧多晚出来（默认 1000 毫秒）。RIST 分不出发送端结束与丢失，所以流结束也报 `sourceUnavailable`。
  连接是 librist 自己的，不走系统代理与 App Transport Security；错误里没有地址与口令。
  模块自带的第三方许可原文：`UmbelRISTSource.thirdPartyNotices`（librist、它自带的 Mbed TLS、lz4、cJSON）。
- `UmbelSMBSource(url:configuration:)`（`import UmbelSMBSource`）：`smb://[域;][用户[:密码]@]主机[:端口]/共享/路径`，随机读、可 seek。
  登录是 NTLM；地址里没有用户就是来宾（用户名 `Guest`、空密码，服务器不允许来宾就报 `authentication failed` 或 `access denied`）。用户名与密码按字面使用（已做百分号解码），
  `Configuration.password`、`Configuration.domain` 优先于地址里的。地址不放行任何选项。
  来宾没有会话密钥，不能签名也不能加密：libsmb2 在 SMB 3.1.1 下仍会签，服务器因签名不对而拒绝，所以来宾只协商 SMB 2；对来宾设 `requireEncryption` 在创建时就被拒绝。
  签名在服务器要求时自动使用，没有对应的开关（Samba 对 SMB 2 客户端总会协商签名，开关的效果观察不到，所以没有提供）。`requireEncryption` 要求 SMB 3 加密，服务器不支持就拒绝。
  错误只用固定的话（`authentication failed`、`access denied`、`share not found`、`file not found`、`connection timed out`、`no data received`），没有地址、用户、共享、路径与密码。
  读取被取消时放弃并关闭连接，下一次读取重新连接；`invalidate()` 之后不能再用。连接是 libsmb2 自己的，不走系统代理。
  **LGPL**：libsmb2 在 `UmbelSMB2.framework` 里，一个只含它的独立动态库。App 要用自己改过的版本，替换这个框架并重新链接即可；不要把它静态并进别的库。
  模块自带的第三方许可原文：`UmbelSMBSource.thirdPartyNotices`（libsmb2，含上述说明与源码获取方式）。
- `UmbelNFSSource(url:configuration:)`（`import UmbelNFSSource`）：`nfs://主机[:端口]/导出路径/文件`，随机读、可 seek。
  NFS 把文件分成导出（服务器共享的目录）与其中的路径两部分，而 URL 没说从哪里断开：不带选项时，文件是最后一个名字、导出是它所在的目录；
  `?export=/共享` 明说哪一段是导出，其余是其中的文件。另一个选项是 `?mountport=`，给 MOUNT 服务不在端口映射器上的服务器；地址里给了非标准端口而没给它，
  库会去问 111 端口的端口映射器。别的选项一律拒绝，每个只能出现一次；地址里不能有用户名与密码。
  **没有登录，没有加密**：NFS（AUTH_SYS）里服务器信客户端自称的用户与组，`Configuration.userID`、`groupID` 设这两个（不设就是 App 自己的），文件在网络上是明文。
  不找嵌套在这个导出下面的其他导出（那要多一次 MOUNT 的 EXPORT 调用，有的服务器不回，会让挂载失败）；文件在哪个导出里，就用 `?export=` 指明那个。
  只讲 NFS 版本 3；没有 Kerberos、TLS 与 NFSv4。
  错误只用固定的话（`export not found or not permitted`、`file not found or not readable`、`access denied`、`connection timed out`、`no data received` 等）：
  libnfs 8.0.0 在挂载时把导出不存在与没有权限都说成 `EPERM`，在打开文件时把已经转成 errno 的错误又转了一遍而一律变成 `ERANGE`，所以这两种只能如实说成"找不到或没权限"。
  读取被取消时放弃并关闭连接，下一次读取重新挂载；`invalidate()` 之后不能再用。连接是 libnfs 自己的，不走系统代理。
  libnfs 在创建连接时调用 `signal(SIGPIPE, SIG_IGN)`，**整个进程**从此忽略 `SIGPIPE`（它写的套接字可能已被对端关掉，不忽略就会杀掉进程；许多网络库都这样做，苹果平台上也不依赖它的默认行为）。
  **LGPL**：libnfs 在 `UmbelNFS.framework` 里，一个只含它的独立动态库。App 要用自己改过的版本，替换这个框架并重新链接即可；不要把它静态并进别的库。
  模块自带的第三方许可原文：`UmbelNFSSource.thirdPartyNotices`（libnfs：LGPL-2.1+ 与它的协议代码的 BSD-2-Clause，含上述说明与源码获取方式）。
- 自己带网络库的模块，实现 `UmbelBlockingByteReader`（`open`、`read`、`requestInterrupt`、`close`）后交给 `UmbelBlockingStreamSource(reader:)`：
  读取在专用线程上进行，进有界缓冲；取消一次读取只让这一次返回 `interrupted`；断流之后一直是断流；错误按 `UmbelError` 原样到宿主，
  不要把地址写进去。`requestInterrupt()` 要能让正在阻塞的 `read` 尽快抛出 `UmbelError.interrupted`。
  要随机读的（文件），实现 `UmbelBlockingFileReader`（`open`、`size`、`read(offset:maxLength:)`、`abandonCurrentCall`、`requestInterrupt`、`close`）后交给
  `UmbelBlockingFileSource(reader:)`：一次只进行一个读取；取消的读取（连接阶段也算）调用 `abandonCurrentCall()`，让阻塞的那一次抛出 `interrupted`，
  来源随后关闭连接，下一次读取再 `open()`。

## 音频会话、后台与画中画

iOS / iPadOS 的 `AVAudioSession` 由宿主管理：播放用途通常配置 `.playback`、`.moviePlayback` 并激活；需要多声道时启用相应系统选项并验证实际输出路由。
需要后台声音或画中画时，由宿主配置 `UIBackgroundModes` 的 `audio`。音频中断、路由改变、Now Playing 和远程控制也由宿主协调。

进入后台且没有画中画时，调用 `session.setVideoSuspended(true)` 可停止视频解码、保留声音；回前台调用 `false`。
恢复视频可能涉及重新定位或重建解码，不承诺完全无停顿。画中画进行中应保留视频输出。

主线程创建 `UmbelPictureInPicture(layer:session:renderer:)`，传入组合输出中的同一系统显示层；初始化可能返回 `nil`。
iOS 上把显示驱动交给它：`pictureInPicture.displayDriver = driver`，小窗打开时退到后台，画面照常更新。
不用 `UmbelDisplayDriver` 的宿主，在小窗打开期间（`isActive`）后台也要继续调用 `renderVideoFrame()`。
显示层需已在屏幕窗口内并有画面。保留控制器，通过 `start()` / `stop()` 请求切换；`isPossible` 和 `isActive` 分别表示当前系统判断与实际状态，调用 `start()` 不等于已成功进入。
macOS 画中画期间由封装跟随小窗调整系统显示层尺寸，宿主布局不要覆盖该尺寸；具体布局参考 [macOS 画中画示例](../Examples/UmbelPlay/PictureInPictureSetup.swift)。
P5 画中画字幕限制与系统适配风险见 [能力范围](support.md)。

## 对象音频

选中的音轨是 E-AC-3 (JOC)、片长已知、声音经 `SampleBufferAudioOutput` 输出时，这条音轨不经 FFmpeg 解码：
引擎把它重新封装成本机 HLS，交系统播放器只放声音；画面、字幕与画中画仍由引擎输出，跟随系统播放器的时钟。
对象信息由系统按当前设备渲染。声音只读一遍，网络片源不会因此多下载。其他音轨、`EngineAudioOutput` 与直播照旧由引擎解码。
向前 seek 到已读范围内时，只移动系统播放器，缓存与读取照旧，不新开请求；向后、超出已读范围、读失败之后，
以及系统播放器已放掉它要的第一段的短距离前跳（大约几秒以内，视它预读的深度而定），清空缓存、由解复用器重新定位（`session_seek_path` 记 `reread`）。

`session.audioRoute` 报告当前走法：`.engine`、`.systemPlayer`，或 `.engineAfterFallback(原因)`。
系统播放器失败，或拿到它所要的全部数据后 5 秒仍不播放时，引擎在当前位置改为自行解码，播放不停，同一会话不再尝试。
读取慢属于缓冲，`phase` 报 `.buffering`，不会因此退回。音量、静音、倍速照常生效；音频延迟改为移动画面，不移动声音。
系统播放器的声音不交给 AirPlay 接收端，走系统当前的音频路由；`AVAudioSession` 仍由宿主配置。

默认 `objectAudio: .automatic`。走这条路时，引擎在本机回环地址 `127.0.0.1` 上监听一个由系统分配的端口：
路径带随机口令，只接受 GET 与 HEAD，与宿主自己的 HTTP 服务互不影响；没有这类音轨播放时不监听。
不需要时创建会话传 `.off`，引擎从不监听端口：

```swift
let session = PlaybackSession(source: source, audioOutput: SampleBufferAudioOutput(), objectAudio: .off)
```

开启 App Sandbox 的 Mac App 需要 `com.apple.security.network.server`（Xcode：Signing & Capabilities → App Sandbox →
Incoming Connections (Server)），只监听本机回环也需要。缺少时 `audioRoute` 报 `.engineAfterFallback(.serverUnavailable(_))`，
声音照常由引擎解码。

## 验收与分发

框架自身的验证范围见 [内测清单](release-checklist.md)。接入方自行验证应用中的布局、业务交互与生命周期集成；这些应用验收不作为框架发布门槛。
`Umbel.thirdPartyNotices` 提供第三方名称、版本、许可与许可原文，供宿主展示；分发材料仍需遵守 [LICENSES.md](../LICENSES.md)。
运行时可记录 `Umbel.version`、`Umbel.ffmpegVersion`、`Umbel.ffmpegLicense`、`Umbel.libassVersion` 协助诊断依赖冲突。
本项目以独立消费工程的 Release Archive 验证框架及其依赖的 dSYM。接入方需另行检查自己最终 App 的 Archive；步骤见 [归档说明](../Tools/ArchiveConsumer/README.md)。
