# Playback, presentation, previews and cached audio APIs

## Backward seek cache

```swift
let session = PlaybackSession(
  source: source,
  audioOutput: audioOutput,
  videoRenderer: renderer,
  buffering: .init(
    maximumPacketBytes: 32 * 1024 * 1024,
    maximumBackwardPacketBytes: 64 * 1024 * 1024))

let forwardBytes = await session.bufferedPacketBytes
let backwardBytes = await session.backwardPacketBytes
```

`maximumBackwardPacketBytes` defaults to `0` (disabled); negative values also
disable retention. The caller chooses it when creating the session. The example
budgets are choices, not device recommendations. The bound is shared across
retained compressed audio/video payloads, not multiplied by track count. Oldest
history is evicted first and video history is trimmed to a keyframe. An oversized
packet breaks that track's history instead of exceeding the bound. A long group
of pictures may therefore leave no usable backward cache. Empty packets are not
retained. There is no guaranteed number of seconds: bitrate and keyframe spacing
determine the available interval.

A seek can reuse history when the keyframe and consecutive decode-order video
packets, audio warm-up and continuous sound, and the selected embedded subtitles
are available. The decoder and outputs restart at the target while the demuxer
continues reading at its existing position. This saves source reads and demuxer
seeks, but still decodes from the keyframe. Missing coverage, unknown continuity,
changed codec parameter generations, and cache eviction use the normal seek path.
Changing selected media tracks or rereading clears backward history.
After a cached rewind, switching to an inactive audio or embedded subtitle track
also checks its coverage. Missing packets trigger an ordinary seek at the current
position. Subtitle selection and delay changes during a seek invalidate its replay
snapshot before feeding resumes.

History is separate from forward buffering and does not raise `bufferedDuration`
or block reading while it is behind the decode queues. On a cache hit, existing
payloads move back into the decode queues: `backwardPacketBytes` falls and
`bufferedPacketBytes` rises. This transfer can temporarily exceed the forward
reading high-water mark (`maximumPacketBytes`) or duration target; it does not
allocate another copy of the payloads. Reading waits until the queue drains below
its normal bounds. Neither setting limits total player memory: packet metadata,
decoded frames, device output, demuxer preroll, subtitle history, and independently
retained audio extraction data are separate. Setting only the backward budget
does not impose a forward byte limit.

This optimization applies to seekable on-demand content with engine-decoded
sound (including audio-only and video-only playback). System audio keeps its
existing seek behavior; live sources do not gain seek support. Embedded subtitle
replay uses the existing subtitle history, whose window can be shorter than the
media history; missing subtitle state falls back to rereading. Both subtitle
slots and their delays are checked. Bitmap subtitles require every subtitle
packet since the last ordinary seek, including earlier palette and object
definitions; any discarded packet prevents cached replay of that track. A failed
or completed playback run also uses normal seek. `session_seek_path` keeps
`path=cache|reread` and adds a `cache` label
(`forward`, `backward`, or the miss reason) and `backwardPacketBytes` after the
decision.

## Video decoding mode

```swift
let session = PlaybackSession(
  source: source,
  videoRenderer: renderer,
  videoDecodingMode: .asynchronous) // Default: .synchronous.
try await session.load()
let requestedMode = await session.videoDecodingMode
let selectedRoute = await session.videoDecodingStatus
```

`UmbelVideoDecodingMode.synchronous` decodes each packet before handing its frames
on. `.asynchronous` separates engine packet submission from result consumption:
a private serial queue decodes one packet ahead while the preceding result waits
for renderer capacity. There are at most two outstanding packet jobs, including
a result being awaited; decoder reorder buffers and renderer queues keep their
existing bounds. Both choices execute outside the UI thread and retain the same
hardware preference, software fallback, frame ordering and color handling.

This is engine-level lookahead, not native VideoToolbox submit/callback mode.
Synchronous mode does not disable the software decoder's internal threads.
Lookahead can add a packet interval of startup latency when the next packet has
not arrived. No speedup is guaranteed. Audio and thumbnail decoding are unchanged.

The mode is immutable for the session's lifetime. To choose another, stop that
session and open a new source/session with the other value; there is no live swap
or implicit seek for a configuration change. Normal seeks and suspension preserve
the configured mode and discard old pending results.

`videoDecodingStatus` is `.inactive` before successful loading, after `stop()`, or
without video output; otherwise it is `.synchronous`, `.asynchronous`, or
`.systemManaged`. Status describes the selected route, including during temporary
video suspension, rather than whether a decoder is currently busy. DV P5 always
uses `.systemManaged`, regardless of the requested mode; this option does not
enable software P5 processing. Existing load errors still report unsupported
content/output combinations.

## Video decoder preference

```swift
let session = PlaybackSession(
  source: source,
  videoRenderer: renderer,
  videoDecoder: .init(preference: .software, softwareThreadCount: 8)) // Default: .init()
try await session.load()
let asked = await session.videoDecoderConfiguration
let decoding = await session.videoDecoderStatus // .software(threads: 8)
```

`UmbelVideoDecoderConfiguration.preference` is `.hardware` (default) or `.software`.
`.hardware` is what the engine has always done: the hardware decoder where it can
decode the video, the software decoder where it cannot. `.software` uses the
software decoder for every video the engine decodes, including those the hardware
could decode. It is a preference, not a requirement: pictures the system decodes
(DV that the system shows itself, and P8.1 / P8.4 pictures the system decodes into
buffers for the engine to hand to its display layer) do not pass through it, and
are not affected. Audio and thumbnail decoding are not affected either.

`softwareThreadCount` is the number of threads software decoding runs on. `nil`
(default) leaves it to the decoder, which picks the device's cores plus one, up to
sixteen. A host that sets it chooses from
`UmbelVideoDecoderConfiguration.softwareThreadCounts`: `1, 2, 4, 6, 8, 10, 12, 14, 16`.
Any other count is brought down to the one below it (`7` → `6`), the first when it is
below them all (`0`, negatives → `1`) and the last when it is above them all
(`17` and more → `16`). It applies to software decoding wherever it happens: preferred,
or fallen back to because the hardware cannot decode the video. It is ignored while
the hardware decodes.

What the count costs: H.264, HEVC, VP9 and most other codecs decode on threads by
frame, so a count of *n* delays the first picture, and the first after every seek, by
*n* − 1 frames, and keeps *n* frames being decoded in memory besides the ones waiting
to be shown. At 4K with 10 bits a frame is about 25 MB. Fewer threads answer sooner and
hold less; more are for a video that fewer cannot keep up with. AV1 is decoded by a
library that divides the work its own way, with a delay of the square root of the count,
rounded up, in frames (four at sixteen threads); its status reports `threads: nil` when
no count was given.

Both are given when the session is made, as `videoDecodingMode` is, and kept for all of
it: a decoder made again — after the app was in the background and the hardware decoder
was taken away, after a seek that renews it, when a playlist moves on to content encoded
otherwise, or when the system refuses a DV stream and the base layer is decoded here —
is made with the same preference and count. To change them, stop the session and make a
new one. A session made without `videoDecoder` behaves as before.

`videoDecoderStatus` says what decodes the chosen video track now: `.inactive` (before
loading succeeds, after `stop()`, without a video output), `.hardware`,
`.software(threads:)` with the count it runs on, or `.systemManaged`. It follows what
happens rather than what was asked: a video the hardware cannot decode, or one
VideoToolbox refuses once it has seen it, reports `.software` under `.hardware`. A host
can show "hardware chosen, decoded in software" by comparing it with
`videoDecoderConfiguration.preference`. When VideoToolbox refuses a stream when the first
pictures are read, the decoder is opened again as a software decoder, on the threads
software decoding gets, and given that packet again; nothing is lost or shown twice.

## Deinterlacing

```swift
await session.setDeinterlacing(.off) // Default: .automatic.
let setting = await session.deinterlacing
```

`UmbelDeinterlacing.automatic` turns every frame the stream marks interlaced into
two progressive pictures: the first field's at the frame's time, the second's half
a frame later. Each picture keeps its own field's rows and fills in the others.
Where the picture is still, the missing rows come from the other field, so detail
stays at full resolution and nothing flickers. Where it moves, they are drawn from
the kept field's own rows along the direction of the edge, so there are no combs.
In between, the two are mixed by how much the picture moved. Progressive frames,
and frames the stream does not mark, pass as they are. The pictures are
progressive on every output: the window, Picture in Picture, snapshots, custom
renderers and timeline previews.

An interlaced 4:2:2, 4:1:1 or 4:4:4 stream is turned into 4:2:0 one field at a time,
so the colour rows stay with the field they came from; converted as a whole, the
colours of two moments would be averaged, and a moving saturated edge would smear.

An interlaced stream therefore presents twice as many pictures a second as it has
frames. `PresentedFrame` counts and the gaps between pictures follow the fields,
not the frame rate of the source. The second picture's time comes from the frame's
duration, halved. A stream that sends each field as its own packet gives the
duration of one field, so its declared frame rate is used to tell the two apart.
A stream with no frame duration, no declared frame rate and no container frame rate
— a rate outside 10 to 62.5 frames a second, such as the 27 MHz system clock some
streams write where a frame rate belongs, counts as none — takes the period from how
its frames are spaced:
once two spacings in a row agree, within 5% and between 10 and about 60 frames a
second, the second picture follows half that period after the first. Until then,
the first two frames of a stream show only the first picture. A seek keeps the
period it found.

`.off` shows frames as decoded, with the fields woven together. A change applies
from the next decoded frame; pictures already queued keep the form they have.
It survives seeks and output switches.

Only the stream's own interlaced mark is trusted: unmarked video is not
detected, and telecined film is not restored. The P5 system display route is
not processed. HEVC and VVC do not pair the two fields of a field-coded stream, so
such a stream shows its fields as decoded. If no GPU is available, or one pass does
not complete, the frame is shown as it is rather than failing playback; the
diagnostics record `video_deinterlace_failed` (see `playback-diagnostics.md`).

## Dual subtitles

```swift
try await session.selectSubtitleTrack(firstSubtitleID) // Primary slot.
try await session.selectSubtitleTrack(secondSubtitleID, for: .secondary)
await session.setSubtitleDelay(0.25, for: .secondary) // Seconds later.
await session.setSubtitleScale(1.2, for: .secondary)
await session.setSubtitlePlacement(.init(verticalOffset: 0.2), for: .secondary)
try await session.selectSubtitleTrack(nil, for: .secondary)
```

`UmbelSubtitleSlot.primary` and `.secondary` each retain their own track, delay,
size multiplier and placement across seeks and track changes. The existing
single-subtitle APIs address primary only. Automatic forced-subtitle selection
also affects primary only; secondary starts disabled. Use
`selectedSubtitleTrack(for:)`, `currentSubtitleCues(for:)`, `subtitleDelay(for:)`,
`subtitleScale(for:)` and `subtitlePlacement(for:)` to query either slot.

Both slots accept embedded or external text, ASS and bitmap tracks, including the
same track in both slots. Secondary defaults to an upward offset of 0.2 canvas
heights; primary defaults to authored placement. This initial offset does not
guarantee collision avoidance for authored artwork. Delay is in seconds, positive
for later display; scale is an authored-size multiplier. Changes redraw a paused
picture, and snapshots compose both slots. Disabling one leaves the other selected.
Selecting an embedded track mid-play, or selecting it again after turning it off,
shows the line already on screen at the playhead, paused or playing: the track's
lines from the last ten seconds, and older lines still showing, are handed to the
new decoder. At most 32 such older lines are kept per track.

Raw PGS `.sup` files can be passed to `addExternalSubtitle(_:language:title:)`
through any supported byte source. Adding returns an external track without
selecting it; select its ID in either slot. The loader retains authored timing,
bitmap canvas and clear events. Binary input is detected before text conversion;
malformed input throws rather than adding an empty track.

External loading owns and invalidates the supplied source. Input is limited to
32 MiB. SUP is decoded into a complete in-memory timeline, with a conservative
64 MiB cumulative bitmap budget (both defined objects and displayed bitmaps are
checked), 32 MiB per object, canvas sides at most 8192 pixels and at most 20,000
bitmap references. Long or high-resolution SUP files can exceed these limits and
are rejected in full. This version does not stream an unbounded external bitmap
timeline. Text encoding detection remains available for external text files.

## Subtitle placement

```swift
await session.setSubtitlePlacement(.init(bottomInset: 0.2))
await session.setSubtitlePlacement(.init()) // Restore authored placement.
```

`UmbelSubtitlePlacement.verticalOffset` and `bottomInset` are fractions of the
**visible video canvas height**, excluding letterbox bars. Positive offset moves
subtitles upward; bottom inset reserves space below them. For a control overlapping
48 view points of a 240-point video canvas, use `bottomInset: 0.2`. Convert view
coordinates to this canvas before calling the engine. Offset is clamped to
`-1...1`, inset to `0...1`; non-finite values are ignored.

Text, ASS and bitmap images move as one group, including explicitly positioned
artwork. Relative spacing is preserved. The group stays inside the available area
when it fits; otherwise its top aligns with the canvas top. Default values preserve
the authored positions. Setting placement requests an immediate redraw while
paused. Snapshots apply the same fractions at their output resolution, not a fixed
number of view points. The snapshot is the full video picture; fit/fill cropping of
the on-screen viewport is not included. Placement is applied independently to
each selected slot. Use the `for:` overload to reserve control-bar space for both.

## Cached PCM

```swift
let ranges = await session.cachedAudioRanges(for: audioTrackID)
let extraction = Task {
  try await session.extractCachedAudio(for: audioTrackID, range: requestedRange)
}
let pcm = try await extraction.value
// pcm.frames: planar Float32 AudioFrame values, with media presentation times.
// pcm.coveredRanges: actual sample coverage, which can differ from the request.
// extraction.cancel() cancels an in-progress extraction.
```

Pass `cachedAudio: CachedAudioConfiguration(maxDuration:maxBytes:maxDecodedBytes:)` to the session
initializer to choose retention. Defaults are 30 seconds per audio track and
8 MiB of compressed packet payload shared across tracks. Decoded PCM is limited
to 64 MiB per extraction by default; exceeding it throws
`CachedAudioError.outputLimitExceeded(maxBytes:)`. Either compressed limit set to zero
disables retention. The duration is measured against the latest packets read,
including read-ahead; it does not promise 30 seconds behind the playhead. Returned
PCM and active extraction snapshots live outside those cache limits. Bound the
number of concurrent extractions and release results when finished.

Coverage describes retained compressed packets with known timestamps and durations.
It can contain holes, and changes as packets arrive or are evicted. A request must
fit within one covered interval; missing coverage throws
`CachedAudioError.missingCoverage(available:)`. There is no source read or network
fallback. A seek that reads again clears retained coverage; a forward seek into
packets already read keeps it, since reading continues where it was. An
extraction that already took its packet snapshot can finish independently.

Each extraction uses a separate decoder and leaves the playback decoder, position,
rate, volume and delay alone. It decodes the available preceding contiguous history
and trims to complete samples inside the request. Cache eviction may remove codec
history needed to reconstruct leading samples; packet coverage does not guarantee
identical PCM coverage. Frame timestamps are rounded to microseconds, and returned
coverage merges gaps up to one microsecond from rounding. Inspect `coveredRanges`
and frame timestamps. Missing or
rejected samples are not replaced with invented silence. Sample rate and channel
count belong to each frame; they may change across a stream discontinuity. Within
each frame, channel `c` occupies `samples[c * frameCount ..< (c + 1) * frameCount]`.

## Timeline previews

```swift
let previews = UmbelThumbnailGenerator {
  try UmbelFileSource(url: mediaURL) // Fresh, independently owned source each time.
}
let request = Task {
  try await previews.thumbnail(
    at: requestedTime, maximumSize: CGSize(width: 320, height: 180))
}
let preview = try await request.value
// preview.image is an SDR CGImage; preview.presentationTime is its actual time.
// request.cancel() cancels this request, including while queued or reading.
```

The generator owns a separate demuxer and decoder, so it never seeks or closes a
playback session's source. The factory must return a fresh source on every call;
for HTTP, construct a new source with the same authentication and request policy.
The generator invalidates owned sources after success, failure or cancellation.
Do not return the source currently used by playback.

Requests run one at a time per generator. A cancelled queued request does not open
a source, and cancellation of an active request does not cancel the next one.
Custom factories and sources should cooperate with cancellation and release I/O
when invalidated. A noncooperative read may outlive the cancelled request; a source
returned late by a cancelled factory is invalidated when it arrives.

The result is the first picture at or after the requested time, or the last picture
at end of stream. Inspect `presentationTime`; it can differ from the request.
`maximumSize` is a finite pixel bounding box, with both dimensions at least one.
The result preserves display aspect, rounds down to whole pixels and never
upscales. A picture whose stream declares a rotation comes back upright, sized
in its turned shape, and interlaced video comes back deinterlaced.
Previews contain video only, with neutral colors, independent of playback
subtitle and picture-adjustment settings. There is no persistent thumbnail cache.

`UmbelThumbnailError` distinguishes invalid time/size, unavailable seeking, absent
video and content requiring system display. Times must be numeric, nonnegative
and within the known duration. Live/nonseekable sources and the P5
system route are unsupported. Decode, source and render failures may also throw;
task cancellation throws `CancellationError`.

## Picture adjustments

```swift
await session.setVideoAdjustments(
  .init(brightness: 0.1, contrast: 1.1, saturation: 0.8))
let settings = await session.videoAdjustments
await session.setVideoAdjustments(.init()) // Neutral reset.
```

`UmbelVideoAdjustments` uses brightness `-1...1` (default 0), contrast `0...2`
(default 1), and saturation `0...2` (default 1). Finite values clamp to these
ranges; non-finite values become the neutral default for that component.
Saturation zero produces grayscale video. Settings survive seeks and output
switches, redraw while paused and apply to snapshots. Subtitle colors are not
adjusted; translucent subtitle edges still blend with the adjusted picture.

The common GPU video path first applies contrast around half reference white,
then adds brightness times reference white, then mixes luminance and RGB by
saturation. For SDR output this operates in encoded RGB with white 1 and BT.709
luminance weights `(0.2126, 0.7152, 0.0722)`, after any HDR-to-SDR mapping.
For PQ HDR output it operates in linear BT.2020 at 100 nits per unit, with white
2.03 (203 nits). HLG HDR uses BT.2020 scene light on the 0...12 scale, with white
3.1796 (75% signal). Both HDR paths use weights `(0.2627, 0.6780, 0.0593)`;
negative adjusted values clamp to zero, while values above 1 retain HDR headroom.
SDR output clamps to `0...1`. Neutral settings bypass this math.

Snapshots use the same settings in their SDR output domain; they do not reproduce
an HDR display's extended luminance. Timeline previews always use neutral settings.
Query `videoCapabilities.canAdjustColors` before enabling controls. Built-in pixel
paths support adjustments. The P5 and P8.4 system display paths report false and keep
settings for a later supported route. Custom renderers default to false and a
no-op `setVideoAdjustments(_:)` until they implement this capability.

## Video capabilities

```swift
let capabilities = await session.videoCapabilities
// canOverrideAspectRatio, canScalePicture, canAdjustColors, snapshot, subtitles
```

Query after loading and again after changing content/output or seeking. The built-in
pixel renderers support aspect override and snapshots; a snapshot becomes available
after a frame is presented. Metal and offscreen outputs support fit/fill; the pixel
sample-buffer route hands over whole pictures and reports no viewport scaling.
Custom renderers default to unsupported and
can implement `VideoRenderer.videoCapabilities`.

The current DV P5 system display route supports fit/fill, but reports no aspect
override and `snapshot == .unsupported(.systemDisplay)`. It shows pictures as
stored, without the stream's declared rotation. Arbitrary geometry is not
categorically prohibited by the system: a correct implementation needs coordinated
layer bounds, subtitle layout and picture-in-picture behavior.

## Video format and dynamic metadata policy

```swift
let session = PlaybackSession(
  source: source,
  videoRenderer: renderer,
  videoPolicy: UmbelVideoPolicy(
    dynamicRange: .automatic,
    dynamicMetadata: .automatic))
let quality = await session.videoPresentationStatus
```

The explicit policy is chosen at construction. Existing initializers inherit the
renderer range setting. An explicit automatic-range policy conflicts with a renderer
constructed to require standard range and is rejected during loading.
`.standard` limits dynamic range while retaining available precision.
`.compatibleBaseLayer` chooses the compatible signal and permits pixel processing;
it does not force an eight-bit format.

P8.4 can use original decoded buffers and their attachments on the system display
layer. P8.1 follows the same rule: where the system decodes DV in hardware, original pixels
go to the system display layer under the automatic policy, and `.compatibleBaseLayer` keeps
them on the HDR10 base layer. Where the framework has measured the result against the
system's own player (macOS), the support notes say so; elsewhere the result is unverified.
P8.2 uses its SDR base layer. System rejection can fall back from a retained random access
point; cancellation and network errors do not trigger quality fallback.
The native pixel path orders callbacks using safe decode timestamps and bounds
retained surfaces. Missing or unsafe timestamps can select the compatible route.
After a system-path failure the current session keeps that compatible route;
reloading content evaluates system eligibility again.

The quality snapshot exposes `source`, `decoded`, `outputFormat`,
`outputEffectiveBits`, `outputStorageBits`, `metadata`, `qualityChanges`, `reason`,
and `routeGeneration`. Floating-point storage has no asserted integer effective
depth. These fields describe submitted samples and targets, not panel scanout.
`submittedToSystem` records delivery; `effectValidated` does not become true merely
because buffers were accepted. The snapshot works without enabling diagnostics.

Both system display routes report snapshot capture unsupported. Their original
pixels cannot be used as a substitute for a verified capture of the processed
system picture. Main-window subtitles may be a separate overlay; system picture
in picture reports `.unavailable` for custom subtitle composition. Choosing picture
in picture does not itself discard the metadata or require SDR/8-bit conversion.
The composited pixel route currently maps HDR to SDR while independently choosing
a high-precision target; its limitations are included in quality diagnostics.
For composited picture in picture, `UmbelPictureInPicture` supplies the system's
rendered pixel size. Output fits that size without upscaling or lowering precision;
original system buffers and full-source snapshots retain their original size.
Custom hosts can use `SampleBufferVideoRenderer.setRenderSize(_:)`, or
`SwitchingVideoRenderer.setPictureInPictureRenderSize(_:)`; pass `nil` to restore
the natural source size. `video_render_size` diagnostics record source and output
dimensions separately from color and precision changes.

Snapshots retain the eight-bit sRGB API, with an explicit color conversion and
stable spatial dithering at final quantization. Export changes are recorded as
`video_export` and do not change the live playback plan. `OffscreenVideoRenderer`
raw `readValue` returns the target's encoding: high-precision SDR is linear light;
eight-bit `readPixel` is a compatible BT.709 signal export for SDR working targets.

System pixel readback exists from iOS/tvOS 17.4, macOS 14.4 and visionOS 1.1, but its
API returns no pixels at a nonzero playback rate, for protected content, or when an
image is unavailable. Real P5 pixel format and color conversion still need device
validation. The package's synthetic routing fixtures cannot establish screenshot
color correctness. No software P5 processing is enabled. `requiresPause` is available
in the public availability type for renderers that implement verified paused capture;
the built-in system route currently reports unsupported.

## Audio delay and release symbols

`setAudioDelay(_:)` updates subsequent audio processing without a seek or changing
the playback/pause state. Prepared audio drains with its earlier timing. Increasing
delay can introduce silence; decreasing it skips overlapping sound. This avoids a
full playback restart but does not promise inaudible transitions at every setting.

For Release archives, run `Tools/archive_release_symbols.sh`. It archives an
independent consumer for iOS devices and macOS and checks the final embedded
frameworks against their dSYMs. See [archive instructions](../Tools/ArchiveConsumer/README.md).
