import CoreMedia
import Metal
import QuartzCore
import XCTest
@testable import UmbelCore

/// HDR tone-mapped to standard range, where the system cannot show HDR or
/// the host asks for SDR: BT.2390's EETF on the brightest channel, from the
/// film's peak down to BT.2408's reference white (203 nits = SDR white),
/// BT.2020 into BT.709 with what falls outside clipped, encoded for BT.1886.
///
/// Every expected value was worked out from those standards and the sample
/// codes, independently of the shader.
final class ToneMappingTests: XCTestCase {
  private let tolerance = CMTime(seconds: 0.02, preferredTimescale: 600)

  private func renderer(_ range: UmbelDynamicRange = .standard) async throws -> OffscreenVideoRenderer {
    guard let device = MTLCreateSystemDefaultDevice() else {
      throw XCTSkip("no Metal device here; rendering tests skipped")
    }
    let renderer = OffscreenVideoRenderer(
      pipeline: try MetalPipeline(device: device), dynamicRange: range, tolerance: tolerance)
    try await renderer.prepare(
      width: 64, height: 64, color: VideoColorDescription(matrix: .bt2020, range: .limited))
    return renderer
  }

  /// The green of one pixel drawn from 10-bit codes, and the whole pixel.
  private func draw(
    luma: UInt16, cb: UInt16 = 512, cr: UInt16 = 512, transfer: UmbelTransferFunction,
    hdr: UmbelHDRMetadata? = UmbelHDRMetadata(maxContentLightLevel: 1000, maxFrameAverageLightLevel: 400),
    range: UmbelDynamicRange = .standard
  ) async throws -> (r: Float, g: Float, b: Float) {
    let renderer = try await renderer(range)
    let buffer = try XCTUnwrap(
      VideoFrame.makeTestP010PixelBuffer(width: 64, height: 64, luma: luma, cb: cb, cr: cr))
    try await renderer.enqueue(
      VideoFrame(
        presentationTime: .zero, pixelBuffer: buffer, width: 64, height: 64,
        color: VideoColorDescription(
          matrix: .bt2020, range: .limited, transfer: transfer, primaries: .bt2020, hdr: hdr)))
    _ = try await renderer.presentFrame(at: .zero)
    let format = await renderer.targetPixelFormat
    XCTAssertEqual(format, .rgba16Float)
    return try await renderer.readValue(x: 32, y: 32)
  }

  /// Black stays black; 50 nits, below the knee, keeps its brightness
  /// (0.5586 once encoded); the film's 1000-nit peak lands on SDR white.
  func testPQAnchors() async throws {
    for (code, expected) in [(UInt16(64), Float(0)), (450, 0.5586), (723, 1)] {
      let value = try await draw(luma: code, transfer: .pq)
      XCTAssertEqual(value.g, pow(expected, 2.4), accuracy: 0.006, "linear SDR, code \(code)")
      XCTAssertEqual(value.r, value.g, accuracy: 0.006, "grey stays grey")
    }
  }

  /// The source peak comes from the film: MaxCLL 4000 leaves room above
  /// 1000 nits, so 1000 nits no longer lands on white (193.8 nits, 0.9808).
  /// Without metadata, 1000 nits is assumed.
  func testTheFilmsPeakSetsTheCurve() async throws {
    let brighter = try await draw(
      luma: 723, transfer: .pq,
      hdr: UmbelHDRMetadata(maxContentLightLevel: 4000, maxFrameAverageLightLevel: 400))
    XCTAssertEqual(brighter.g, pow(0.9808, 2.4), accuracy: 0.006)
    let unknown = try await draw(luma: 723, transfer: .pq, hdr: nil)
    XCTAssertEqual(unknown.g, 1, accuracy: 0.006)
  }

  /// HLG goes through its OOTF for a 1000-nit display first: 0.5 is 50.7
  /// nits (0.5610); 0.75, reference white at 203 nits, is compressed a
  /// little by the curve's knee (159 nits, 0.9034).
  func testHLGAnchors() async throws {
    for (code, expected) in [(UInt16(502), Float(0.5610)), (721, 0.9034)] {
      let value = try await draw(luma: code, transfer: .hlg, hdr: nil)
      XCTAssertEqual(value.g, pow(expected, 2.4), accuracy: 0.006, "linear SDR, code \(code)")
    }
  }

  /// A BT.2020 green at 243 nits: outside BT.709, its red and blue come out
  /// negative and are clipped; green lands at 0.9806.
  func testWideGamutIsClippedIntoBT709() async throws {
    let value = try await draw(luma: 420, cb: 318, cr: 265, transfer: .pq)
    XCTAssertEqual(value.r, 0, accuracy: 0.006)
    XCTAssertEqual(value.b, 0, accuracy: 0.006)
    XCTAssertEqual(value.g, pow(0.9806, 2.4), accuracy: 0.006)
  }

  /// Automatic keeps HDR as HDR where it can be shown.
  func testAutomaticKeepsHDR() async throws {
    let value = try await draw(luma: 723, transfer: .pq, range: .automatic)
    XCTAssertEqual(value.g, 10.042, accuracy: 0.02, "linear light, 100 nits a unit")
  }

  /// On screen, standard range leaves the layer as for SDR.
  @MainActor
  func testStandardRangeLeavesTheLayerSDR() async throws {
    guard let device = MTLCreateSystemDefaultDevice() else {
      throw XCTSkip("no Metal device here")
    }
    let layer = MainThreadLayer(layer: CAMetalLayer())
    let renderer = MetalVideoRenderer(
      pipeline: try MetalPipeline(device: device), layer: layer.layer, dynamicRange: .standard,
      tolerance: tolerance)
    try await renderer.prepare(
      width: 64, height: 64,
      color: VideoColorDescription(matrix: .bt2020, range: .limited, transfer: .pq, primaries: .bt2020))
    XCTAssertEqual(layer.layer.pixelFormat, .rgba16Float)
    if #available(iOS 16.0, *) { XCTAssertFalse(layer.layer.wantsExtendedDynamicRangeContent) }
  }
}
