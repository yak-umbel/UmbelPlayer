import CoreGraphics
import CoreMedia
import Metal
import QuartzCore
import XCTest
@testable import UmbelCore

/// HDR pictures handed on in linear light — half floats, PQ as nits over
/// 100, HLG as scene light on the system's 0...12 scale — for the system to
/// show in extended dynamic range. Linear, so that subtitles blend over them as light does: blended
/// in PQ's code values, a black outline's soft edge over a bright picture
/// came out near black, and the outline looked heavy and harsh.
///
/// Expected values come from the standards: a limited-range 10-bit code c
/// stands for (c − 64) / 876, decoded by BT.2100's PQ EOTF or HLG inverse
/// OETF; BT.2408's reference white, where subtitles belong, is 203 nits
/// (2.03) for PQ and scene light 0.2650 for HLG — 3.1796 on the scale the
/// system's HLG metadata takes, 0...12 rather than BT.2100's 0...1.
final class HDROutputTests: XCTestCase {
  private let tolerance = CMTime(seconds: 0.02, preferredTimescale: 600)

  private func pipeline() throws -> MetalPipeline {
    guard let device = MTLCreateSystemDefaultDevice() else {
      throw XCTSkip("no Metal device here; rendering tests skipped")
    }
    return try MetalPipeline(device: device)
  }

  private func color(_ transfer: UmbelTransferFunction) -> VideoColorDescription {
    VideoColorDescription(matrix: .bt2020, range: .limited, transfer: transfer, primaries: .bt2020)
  }

  private func frame(code: UInt16, transfer: UmbelTransferFunction) throws -> VideoFrame {
    let buffer = try XCTUnwrap(
      VideoFrame.makeTestP010PixelBuffer(width: 64, height: 64, luma: code, cb: 512, cr: 512))
    return VideoFrame(
      presentationTime: .zero, pixelBuffer: buffer, width: 64, height: 64, color: color(transfer))
  }

  private func draw(
    _ frame: VideoFrame, subtitles: [UmbelSubtitleBitmap] = []
  ) async throws -> OffscreenVideoRenderer {
    let renderer = OffscreenVideoRenderer(pipeline: try pipeline(), tolerance: tolerance)
    try await renderer.prepare(width: 64, height: 64, color: frame.color)
    await renderer.setSubtitles(subtitles)
    try await renderer.enqueue(frame)
    _ = try await renderer.presentFrame(at: .zero)
    return renderer
  }

  /// PQ code 723 is 1004.19 nits: 10.042 at 100 nits a unit. An 8-bit
  /// target could hold nothing past 1.
  func testPQIsHandedOnInLinearLight() async throws {
    let renderer = try await draw(try frame(code: 723, transfer: .pq))
    let format = await renderer.targetPixelFormat
    XCTAssertEqual(format, .rgba16Float, "eight bits would round what HDR needs kept")
    let value = try await renderer.readValue(x: 32, y: 32)
    XCTAssertEqual(value.g, 10.042, accuracy: 0.02)
    XCTAssertEqual(value.r, value.g, accuracy: 0.02)
  }

  /// HLG code 721 is signal 0.75, scene light 0.2650 in BT.2100's 0...1;
  /// the system applies the OOTF for the display at hand. Its HLG metadata
  /// takes scene light 0...12, as ARIB STD-B67 scales it: handed on as
  /// 0...1, every HLG picture showed about three and a half times too dark
  /// beside the system's own playback of the same film.
  func testHLGIsHandedOnAsSceneLightOnTheSystemsScale() async throws {
    let renderer = try await draw(try frame(code: 721, transfer: .hlg))
    let value = try await renderer.readValue(x: 32, y: 32)
    XCTAssertEqual(value.g, 3.1796, accuracy: 0.01)
  }

  /// A subtitle edge half covered by black outline, over a 1004-nit picture,
  /// is half as bright: 502 nits, 5.02. Blended in PQ's code values it came
  /// out at a few tens of nits — the harsh dark fringe viewers saw.
  func testSubtitleEdgesBlendAsLight() async throws {
    let renderer = try await draw(
      try frame(code: 723, transfer: .pq), subtitles: [try subtitle(blue: 0, green: 0, red: 0, alpha: 128)])
    let edge = try await renderer.readValue(x: 32, y: 48)
    XCTAssertEqual(edge.g, 10.042 * (1 - 128.0 / 255), accuracy: 0.05)

    // White at half coverage — stored premultiplied as 128 — is white light
    // at half coverage: 2.03 × 0.502 + 10.042 × 0.498 = 6.020. Decoded
    // without undoing the alpha first, 128 would read as mid grey.
    let white = try await draw(
      try frame(code: 723, transfer: .pq),
      subtitles: [try subtitle(blue: 128, green: 128, red: 128, alpha: 128)])
    let whiteEdge = try await white.readValue(x: 32, y: 48)
    let coverage = Float(128.0 / 255)
    XCTAssertEqual(whiteEdge.g, 2.03 * coverage + 10.042 * (1 - coverage), accuracy: 0.05)
  }

  /// A 4×2 subtitle of one colour, given as premultiplied sRGB B, G, R, A.
  private func subtitle(
    blue: UInt8 = 255, green: UInt8 = 255, red: UInt8 = 255, alpha: UInt8 = 255
  ) throws -> UmbelSubtitleBitmap {
    var bytes: [UInt8] = []
    for _ in 0..<8 { bytes += [blue, green, red, alpha] }
    let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
    let image = try XCTUnwrap(
      CGImage(
        width: 4, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 16,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGBitmapInfo(
          rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    return UmbelSubtitleBitmap(image: image, frame: CGRect(x: 16, y: 40, width: 32, height: 16))
  }

  /// White subtitles over HDR sit at reference white, as bright as the
  /// interface around the picture, not at the picture's peak.
  func testSubtitlesSitAtReferenceWhite() async throws {
    for (transfer, code, white) in [(UmbelTransferFunction.pq, 723, 2.03), (.hlg, 721, 3.1796)] {
      let renderer = try await draw(
        try frame(code: UInt16(code), transfer: transfer), subtitles: [try subtitle()])
      let subtitle = try await renderer.readValue(x: 32, y: 48)
      XCTAssertEqual(subtitle.g, Float(white), accuracy: 0.005, "\(transfer)")
      XCTAssertEqual(subtitle.b, Float(white), accuracy: 0.005, "white stays white")
    }
  }

  /// Colours are converted, not only white: sRGB is decoded to light and
  /// taken into BT.2020's primaries. Mid grey (128) is 0.2159 of white in
  /// light, 0.4382 at 203-nit white; sRGB red is (0.6274, 0.0691, 0.0164) in
  /// BT.2020, (1.2736, 0.1403, 0.0333).
  func testSubtitleColoursAreConvertedFaithfully() async throws {
    let grey = try await draw(
      try frame(code: 723, transfer: .pq), subtitles: [try subtitle(blue: 128, green: 128, red: 128)])
    let greyValue = try await grey.readValue(x: 32, y: 48)
    XCTAssertEqual(greyValue.g, 0.4382, accuracy: 0.004)

    let red = try await draw(
      try frame(code: 723, transfer: .pq), subtitles: [try subtitle(blue: 0, green: 0, red: 255)])
    let redValue = try await red.readValue(x: 32, y: 48)
    XCTAssertEqual(redValue.r, 1.2736, accuracy: 0.004)
    XCTAssertEqual(redValue.g, 0.1403, accuracy: 0.004)
    XCTAssertEqual(redValue.b, 0.0333, accuracy: 0.004)
  }

  /// SDR stays eight-bit and untouched.
  func testSDRKeepsItsEightBitTarget() async throws {
    let buffer = try XCTUnwrap(
      VideoFrame.makeTestPixelBuffer(width: 64, height: 64, luma: 126, cb: 128, cr: 128))
    let renderer = try await draw(
      VideoFrame(
        presentationTime: .zero, pixelBuffer: buffer, width: 64, height: 64,
        color: VideoColorDescription(matrix: .bt709, range: .limited)))
    let format = await renderer.targetPixelFormat
    XCTAssertEqual(format, .bgra8Unorm)
    let value = try await renderer.readValue(x: 32, y: 32)
    XCTAssertEqual(value.g, 128.0 / 255, accuracy: 0.01)
  }

  // ── On screen ────────────────────────────────────────

  private struct LayerState: Equatable {
    let format: MTLPixelFormat
    let colorspace: String?
    let edr: Bool
    let hasMetadata: Bool
  }

  @available(iOS 16.0, *)
  @MainActor
  private func state(of layer: CAMetalLayer) -> LayerState {
    LayerState(
      format: layer.pixelFormat, colorspace: layer.colorspace?.name as String?,
      edr: layer.wantsExtendedDynamicRangeContent, hasMetadata: layer.edrMetadata != nil)
  }

  /// The display layer is set up for each kind of picture as it arrives:
  /// PQ and HLG in half floats, extended linear BT.2020, extended dynamic
  /// range and metadata for the system's tone mapping; SDR back as it was.
  @MainActor
  func testTheLayerFollowsThePicture() async throws {
    guard #available(iOS 16.0, *) else { throw XCTSkip("the layer's HDR settings need iOS 16") }
    guard VideoOutput.systemShowsHDR else { throw XCTSkip("no EDR tone mapping here") }
    // Wrapped: the renderer and this test both hold it, as renderer and
    // window do in a host.
    let layer = MainThreadLayer(layer: CAMetalLayer())
    let renderer = MetalVideoRenderer(
      pipeline: try pipeline(), layer: layer.layer, tolerance: tolerance)
    try await renderer.prepare(width: 64, height: 64, color: color(.sdr))

    try await renderer.enqueue(try frame(code: 723, transfer: .pq))
    _ = try await renderer.presentFrame(at: .zero)
    XCTAssertEqual(
      state(of: layer.layer),
      LayerState(
        format: .rgba16Float, colorspace: CGColorSpace.extendedLinearITUR_2020 as String, edr: true,
        hasMetadata: true))

    await renderer.flush()
    try await renderer.enqueue(try frame(code: 721, transfer: .hlg))
    _ = try await renderer.presentFrame(at: .zero)
    XCTAssertEqual(
      state(of: layer.layer),
      LayerState(
        format: .rgba16Float, colorspace: CGColorSpace.extendedLinearITUR_2020 as String, edr: true,
        hasMetadata: true))

    await renderer.flush()
    let sdr = try XCTUnwrap(
      VideoFrame.makeTestPixelBuffer(width: 64, height: 64, luma: 126, cb: 128, cr: 128))
    try await renderer.enqueue(
      VideoFrame(
        presentationTime: .zero, pixelBuffer: sdr, width: 64, height: 64, color: color(.sdr)))
    _ = try await renderer.presentFrame(at: .zero)
    XCTAssertEqual(
      state(of: layer.layer), LayerState(format: .rgba16Float,
        colorspace: CGColorSpace.extendedLinearITUR_2020 as String, edr: false, hasMetadata: false))
  }

  /// A track that says PQ sets the layer up before its first frame.
  @MainActor
  func testATrackSetsTheLayerUpBeforeAnyFrame() async throws {
    guard #available(iOS 16.0, *) else { throw XCTSkip("the layer's HDR settings need iOS 16") }
    guard VideoOutput.systemShowsHDR else { throw XCTSkip("no EDR tone mapping here") }
    let layer = MainThreadLayer(layer: CAMetalLayer())
    let renderer = MetalVideoRenderer(
      pipeline: try pipeline(), layer: layer.layer, tolerance: tolerance)
    try await renderer.prepare(width: 64, height: 64, color: color(.pq))
    XCTAssertEqual(layer.layer.pixelFormat, .rgba16Float)
    XCTAssertTrue(layer.layer.wantsExtendedDynamicRangeContent)
  }

  /// The layer's format belongs to the renderer. A host that sets it back
  /// after the renderer set it up — the example window once did, for a film
  /// whose track said HDR before the window existed — must not leave HDR
  /// half floats drawn into an eight-bit drawable: that showed as magenta
  /// and green bars. The renderer checks the layer before every picture.
  @MainActor
  func testALayerSetBackByTheHostIsSetUpAgain() async throws {
    guard VideoOutput.systemShowsHDR else { throw XCTSkip("no EDR tone mapping here") }
    let layer = MainThreadLayer(layer: CAMetalLayer())
    let renderer = MetalVideoRenderer(
      pipeline: try pipeline(), layer: layer.layer, tolerance: tolerance)
    try await renderer.prepare(width: 64, height: 64, color: color(.pq))
    XCTAssertEqual(layer.layer.pixelFormat, .rgba16Float)

    layer.layer.pixelFormat = .bgra8Unorm
    try await renderer.enqueue(try frame(code: 723, transfer: .pq))
    _ = try await renderer.presentFrame(at: .zero)
    XCTAssertEqual(layer.layer.pixelFormat, .rgba16Float, "set up again before drawing")
  }

  // ── The metadata as the system takes it ──────────────

  /// ITU-T H.265 D.2.28: primaries green, blue, red, then white, as x, y
  /// pairs in 0.00002 steps; luminance in 0.0001-nit steps, maximum first.
  /// D.2.35: MaxCLL, MaxFALL. All big-endian.
  func testMetadataIsPackedAsTheSEIMessages() throws {
    let metadata = UmbelHDRMetadata(
      masteringDisplay: .init(
        red: .init(x: 0.68, y: 0.32), green: .init(x: 0.265, y: 0.69),
        blue: .init(x: 0.15, y: 0.06), whitePoint: .init(x: 0.3127, y: 0.329),
        minLuminance: 0.0001, maxLuminance: 1000),
      maxContentLightLevel: 1000, maxFrameAverageLightLevel: 400)
    let display = try XCTUnwrap(HDR10SEI.masteringDisplay(metadata))
    XCTAssertEqual(
      Array(display),
      [0x33, 0xC2, 0x86, 0xC4, 0x1D, 0x4C, 0x0B, 0xB8, 0x84, 0xD0, 0x3E, 0x80,
       0x3D, 0x13, 0x40, 0x42, 0x00, 0x98, 0x96, 0x80, 0x00, 0x00, 0x00, 0x01])
    XCTAssertEqual(Array(try XCTUnwrap(HDR10SEI.contentLightLevel(metadata))), [0x03, 0xE8, 0x01, 0x90])
    XCTAssertNil(HDR10SEI.masteringDisplay(UmbelHDRMetadata()), "nothing to pack")
  }
}
