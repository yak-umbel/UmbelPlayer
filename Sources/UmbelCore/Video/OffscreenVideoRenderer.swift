import CoreMedia
import CoreVideo
import Foundation
import Metal
import simd

/// A region of the screen, for checking pixels.
public enum ScreenRegion: Sendable {
  case whole
  case topHalf
  case bottomHalf
  case leftHalf
  case rightHalf
}

/// A renderer that draws to an offscreen texture.
///
/// It lets whether the picture is right be **checked in numbers**: read the
/// pixels back after rendering, and a wrong colour matrix, swapped ranges,
/// crossed planes or an upside-down picture are all caught. Sound can only
/// be checked by ear; for video, CI can judge for itself.
public actor OffscreenVideoRenderer: VideoRenderer, VideoDiagnosticsReceiving {
  private let pipeline: MetalPipeline
  private let queue: VideoFrameQueue
  private let dynamicRange: UmbelDynamicRange
  private var policyRange: UmbelDynamicRange?

  private var target: MTLTexture?
  private var color = VideoColorDescription(matrix: .unspecified, range: .limited)
  /// The target's size: the output size if one was given, else the video's.
  private var width = 0
  private var height = 0
  /// Fixed at construction; nil draws at the video's own size.
  private let outputSize: CGSize?
  /// Where the picture sits in the target, and the part of it that shows.
  private var layout = PictureLayout(picture: .zero, visible: .zero)
  private var geometry = PictureGeometry.standard
  /// The picture's own shape, before the geometry: what it is laid out by.
  private var shown = CGSize.zero
  /// The target's size, fixed at `prepare` so pixel reads stay put.
  private var output = CGSize.zero
  /// What the target holds: standard range, or HDR code values in half
  /// floats. Follows each frame, as the on-screen renderer's layer does.
  private var targetKind = VideoOutput.standard
  private var subtitles = SubtitleOverlay()
  /// Drawn again when the subtitles change and no new frame is due.
  private var lastFrame: VideoFrame?
  private var needsRedraw = false
  private var adjustments = UmbelVideoAdjustments()
  private var observation: VideoPresentationObservation?
  private var observationOutput = "video"

  /// For hosts: a graphics device is all it takes; the pipeline is made
  /// inside.
  ///
  /// The pipeline is kept out of the public signature on purpose: it is an
  /// implementation detail a host need not know of.
  ///
  /// `outputSize` draws into a target of that size, the picture fitted in it
  /// as the on-screen renderer fits it into its drawable.
  public init(
    device: MTLDevice, outputSize: CGSize? = nil, dynamicRange: UmbelDynamicRange = .automatic,
    capacity: Int = 3, tolerance: CMTime
  ) throws {
    self.pipeline = try MetalPipeline(device: device)
    self.outputSize = outputSize
    self.dynamicRange = dynamicRange
    self.queue = VideoFrameQueue(capacity: capacity, tolerance: tolerance)
  }

  /// For tests: renderers share one pipeline and compile the shaders once.
  internal init(
    pipeline: MetalPipeline, outputSize: CGSize? = nil,
    dynamicRange: UmbelDynamicRange = .automatic, capacity: Int = 3, tolerance: CMTime
  ) {
    self.pipeline = pipeline
    self.outputSize = outputSize
    self.dynamicRange = dynamicRange
    self.queue = VideoFrameQueue(capacity: capacity, tolerance: tolerance)
  }

  public var queueDepth: Int { get async { await queue.depth } }
  internal func setPlaybackDiagnostics(_ diagnostics: UmbelPlaybackDiagnostics?, output: String) async {
    await queue.setDiagnostics(diagnostics, output: output)
  }
  public var totalDroppedFrames: Int { get async { await queue.totalDropped } }

  public func prepare(
    width: Int, height: Int, pixelAspectRatio: Double, color: VideoColorDescription
  ) async throws {
    let shown = CGSize(width: Double(width) * pixelAspectRatio, height: Double(height))
    let output = outputSize ?? CGSize(width: shown.width.rounded(), height: shown.height.rounded())
    self.output = output
    self.width = Int(output.width)
    self.height = Int(output.height)
    self.shown = shown
    self.layout = PictureFit.layout(picture: shown, in: output, geometry: geometry)
    self.color = color
    try makeTarget(for: kind(for: color.transfer))
  }

  /// An off-screen target can hold HDR, so HDR stays HDR unless standard
  /// range was asked for.
  private func kind(for transfer: UmbelTransferFunction, bitDepth: Int? = 8) -> VideoOutput {
    VideoOutput.choose(for: transfer, systemShowsHDR: (policyRange ?? dynamicRange) == .automatic,
                       bitDepth: bitDepth, primaries: color.workingPrimaries,
                       permitsFloat32: pipeline.supports(.rgba32Float))
  }

  private func makeTarget(for kind: VideoOutput) throws {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: kind.pixelFormat, width: width, height: height, mipmapped: false)
    descriptor.usage = [.renderTarget, .shaderRead]
    descriptor.storageMode = .shared
    guard let texture = pipeline.device.makeTexture(descriptor: descriptor) else {
      throw UmbelError.videoRenderUnavailable(reason: "cannot create the offscreen texture")
    }
    target = texture
    targetKind = kind
  }

  /// The actual target format. Standard range can use high precision.
  public var targetPixelFormat: MTLPixelFormat { target?.pixelFormat ?? .invalid }

  public func enqueue(_ frame: VideoFrame) async throws {
    await queue.enqueue(frame)
  }

  public func presentFrame(at time: CMTime) async throws -> PresentedFrame? {
    let result = await queue.take(at: time)
    guard let frame = result.frame else {
      if needsRedraw, let lastFrame { try draw(lastFrame) }
      return nil
    }
    try draw(frame)
    return PresentedFrame(
      presentationTime: frame.presentationTime, droppedFrames: result.dropped)
  }

  /// Forgets the last frame too: after a seek it no longer belongs.
  public func flush() async {
    await queue.flush()
    lastFrame = nil
  }

  public var subtitleCanvasSize: CGSize { layout.visible.size }

  public var subtitlePictureFrame: CGRect {
    layout.picture.offsetBy(dx: -layout.visible.minX, dy: -layout.visible.minY)
  }

  public func setPictureGeometry(aspectRatio: Double?, scaling: UmbelPictureScaling) {
    geometry = PictureGeometry(aspectRatio: aspectRatio, scaling: scaling)
    layout = PictureFit.layout(picture: shown, in: output, geometry: geometry)
    needsRedraw = true
  }

  public func setVideoAdjustments(_ adjustments: UmbelVideoAdjustments) async {
    guard self.adjustments != adjustments else { return }
    self.adjustments = adjustments
    needsRedraw = true
  }

  public func setSubtitles(_ bitmaps: [UmbelSubtitleBitmap]) async {
    subtitles.update(bitmaps, device: pipeline.device)
    needsRedraw = true
  }

  /// Reads one pixel, from the top left. HDR values beyond 1 read as 255.
  public func readPixel(x: Int, y: Int) throws -> (r: UInt8, g: UInt8, b: UInt8) {
    let value = try readValue(x: x, y: y)
    let exported = exportPixel(SIMD3(value.r, value.g, value.b))
    func byte(_ component: Float) -> UInt8 { UInt8(max(0, min(1, component)) * 255 + 0.5) }
    return (r: byte(exported.x), g: byte(exported.y), b: byte(exported.z))
  }

  /// One pixel as the target holds it, 0...1 for standard range; for HDR
  /// linear light — PQ at 100 nits a unit, HLG as scene light.
  public func readValue(x: Int, y: Int) throws -> (r: Float, g: Float, b: Float) {
    guard let target else {
      throw UmbelError.videoRenderUnavailable(reason: "not prepared")
    }
    let region = MTLRegionMake2D(x, y, 1, 1)
    if target.pixelFormat == .rgba32Float {
      var values = [Float](repeating: 0, count: 4)
      target.getBytes(&values, bytesPerRow: 16, from: region, mipmapLevel: 0)
      return (values[0], values[1], values[2])
    }
    if target.pixelFormat == .rgba16Float {
      var halves = [UInt16](repeating: 0, count: 4)
      target.getBytes(&halves, bytesPerRow: 8, from: region, mipmapLevel: 0)
      return (Self.float(half: halves[0]), Self.float(half: halves[1]), Self.float(half: halves[2]))
    }
    var bytes = [UInt8](repeating: 0, count: 4)
    target.getBytes(&bytes, bytesPerRow: 4, from: region, mipmapLevel: 0)
    // The target is BGRA.
    return (Float(bytes[2]) / 255, Float(bytes[1]) / 255, Float(bytes[0]) / 255)
  }

  /// IEEE half precision to single, by hand: `Float16` is missing on Intel Macs.
  private static func float(half bits: UInt16) -> Float {
    let sign: Float = bits & 0x8000 == 0 ? 1 : -1
    let exponent = Int((bits >> 10) & 0x1F)
    let fraction = Float(bits & 0x3FF)
    if exponent == 0 { return sign * fraction * pow(2, -24) }
    if exponent == 31 { return fraction == 0 ? sign * .infinity : .nan }
    return sign * (1 + fraction / 1024) * pow(2, Float(exponent - 15))
  }

  /// Eight-bit readback is an export in the signal domain; raw readValue
  /// still exposes the actual high precision target for numerical checks.
  private func encodedSDR(_ value: Float) -> Float {
    guard targetKind.isLinearStandard else { return value }
    let value = max(value, 0)
    if color.transfer != .sdr { return pow(value, 1 / 2.4) }
    return value < 0.018 ? value * 4.5 : 1.099 * pow(value, 0.45) - 0.099
  }

  private static let wideTo709 = ColorGamutTransform.matrix(
    for: .init(matrix: .bt2020, range: .full, primaries: .bt2020), to2020: false)

  private func exportPixel(_ value: SIMD3<Float>) -> SIMD3<Float> {
    let rgb = targetKind.encoding == .standardLinear2020 ? Self.wideTo709 * value : value
    return SIMD3(encodedSDR(rgb.x), encodedSDR(rgb.y), encodedSDR(rgb.z))
  }

  /// The average colour of a region: for where light and dark fall, say
  /// whether the picture is upside down or mirrored.
  public func readAveragePixel(
    inRegion region: ScreenRegion
  ) throws -> (r: UInt8, g: UInt8, b: UInt8) {
    guard let target else {
      throw UmbelError.videoRenderUnavailable(reason: "not prepared")
    }
    let rect: MTLRegion
    switch region {
    case .whole:
      rect = MTLRegionMake2D(0, 0, width, height)
    case .topHalf:
      rect = MTLRegionMake2D(0, 0, width, height / 2)
    case .bottomHalf:
      rect = MTLRegionMake2D(0, height / 2, width, height / 2)
    case .leftHalf:
      rect = MTLRegionMake2D(0, 0, width / 2, height)
    case .rightHalf:
      rect = MTLRegionMake2D(width / 2, 0, width / 2, height)
    }

    let pixelCount = rect.size.width * rect.size.height
    if target.pixelFormat == .rgba32Float {
      var values = [Float](repeating: 0, count: pixelCount * 4)
      target.getBytes(&values, bytesPerRow: rect.size.width * 16, from: rect, mipmapLevel: 0)
      var totals = [Float](repeating: 0, count: 3)
      for index in stride(from: 0, to: values.count, by: 4) {
        let rgb = exportPixel(SIMD3(values[index], values[index + 1], values[index + 2]))
        for channel in 0..<3 { totals[channel] += rgb[channel] }
      }
      func byte(_ value: Float) -> UInt8 { UInt8(max(0, min(1, value / Float(pixelCount))) * 255 + 0.5) }
      return (byte(totals[0]), byte(totals[1]), byte(totals[2]))
    }
    if target.pixelFormat == .rgba16Float {
      var halves = [UInt16](repeating: 0, count: pixelCount * 4)
      target.getBytes(&halves, bytesPerRow: rect.size.width * 8, from: rect, mipmapLevel: 0)
      var totals: [Float] = [0, 0, 0]
      for index in stride(from: 0, to: halves.count, by: 4) {
        let rgb = exportPixel(SIMD3(Self.float(half: halves[index]), Self.float(half: halves[index + 1]), Self.float(half: halves[index + 2])))
        for channel in 0..<3 { totals[channel] += rgb[channel] }
      }
      func byte(_ total: Float) -> UInt8 {
        UInt8(max(0, min(1, total / Float(pixelCount))) * 255 + 0.5)
      }
      return (r: byte(totals[0]), g: byte(totals[1]), b: byte(totals[2]))
    }

    let bytesPerRow = rect.size.width * 4
    var bytes = [UInt8](repeating: 0, count: bytesPerRow * rect.size.height)
    target.getBytes(&bytes, bytesPerRow: bytesPerRow, from: rect, mipmapLevel: 0)

    var totalB = 0, totalG = 0, totalR = 0
    for index in stride(from: 0, to: bytes.count, by: 4) {
      totalB += Int(bytes[index])
      totalG += Int(bytes[index + 1])
      totalR += Int(bytes[index + 2])
    }
    return (
      r: UInt8(totalR / pixelCount),
      g: UInt8(totalG / pixelCount),
      b: UInt8(totalB / pixelCount)
    )
  }

  private func draw(_ frame: VideoFrame) throws {
    color = frame.color
    let kind = kind(for: frame.color.transfer, bitDepth: frame.preferredWorkingBits)
    observation?.observe(frame, output: observationOutput, target: kind)
    if kind != targetKind { try makeTarget(for: kind) }
    guard let target else {
      throw UmbelError.videoRenderUnavailable(reason: "not prepared")
    }
    shown = frame.displaySize
    layout = PictureFit.layout(picture: shown, in: output, geometry: geometry)
    let descriptor = MTLRenderPassDescriptor()
    descriptor.colorAttachments[0].texture = target
    descriptor.colorAttachments[0].loadAction = .clear
    descriptor.colorAttachments[0].storeAction = .store
    descriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)

    guard let commandBuffer = pipeline.commandQueue.makeCommandBuffer(),
          let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
      throw UmbelError.videoRenderUnavailable(reason: "cannot create a command encoder")
    }

    do {
      try pipeline.encode(
        frame, output: targetKind, subtitles: subtitles, layout: layout,
        adjustments: adjustments, into: encoder)
    } catch {
      encoder.endEncoding()
      throw error
    }
    encoder.endEncoding()

    commandBuffer.commit()
    // Offscreen, pixels can be read only once drawing is done; the real
    // display path need not wait.
    commandBuffer.waitUntilCompleted()
    pipeline.releaseRetainedTextures()
    lastFrame = frame
    needsRedraw = false
  }
}

extension OffscreenVideoRenderer: VideoPresentationObserving {
  var dynamicRangeConstraint: UmbelDynamicRange { dynamicRange }
  func setVideoPolicy(_ policy: UmbelVideoPolicy) { policyRange = policy.dynamicRange }
  func setVideoPresentationObservation(_ observation: VideoPresentationObservation?, output: String) {
    self.observation = observation
    observationOutput = output
  }
}

extension OffscreenVideoRenderer: SnapshotFrameProviding {
  public var videoCapabilities: UmbelVideoCapabilities { .pixels(hasFrame: lastFrame != nil) }
  internal var snapshotFrame: VideoFrame? { lastFrame }
  internal var snapshotDevice: SnapshotDevice? { SnapshotDevice(device: pipeline.device) }
}

extension OffscreenVideoRenderer: PictureFrameReporting {
  internal var normalizedPictureFrame: CGRect? {
    guard lastFrame != nil, output.width > 0, output.height > 0 else { return nil }
    let picture = layout.picture
    return CGRect(x: picture.minX / output.width, y: picture.minY / output.height,
                  width: picture.width / output.width, height: picture.height / output.height)
  }
}

extension OffscreenVideoRenderer: FrameSeeding {
  func seed(_ frame: VideoFrame) async { await queue.seed(frame) }
}
