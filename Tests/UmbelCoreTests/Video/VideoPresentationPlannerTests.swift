import CoreVideo
import XCTest
@testable import UmbelCore

final class VideoPresentationPlannerTests: XCTestCase {
  func testP5PrefersQualifiedSystemPixelsAndRetainsOnlyNativeCompressedRecovery() {
    let signal = VideoSignalDescription(pixels: .init(cvFormat: kCVPixelFormatType_420YpCbCr10BiPlanarFullRange),
      transferCode: 2, primariesCode: 2, matrixCode: 2, rangeCode: 2,
      dynamicHDR: .dv(profile: 5, level: 7, compatibility: 0))
    let capable = VideoEnvironmentCapabilities(supportsSystemCompressed: true, supportsP5SystemPixels: true)
    let plans = VideoPresentationPlanner.candidates(signal: signal, policy: .init(), environment: capable)
    XCTAssertEqual(plans.map(\.route), [.systemPixels, .systemCompressed])
    XCTAssertTrue(plans.allSatisfy { $0.metadata == .declared })
    XCTAssertEqual(VideoPresentationPlanner.candidates(signal: signal, policy: .init(),
      environment: .init(supportsSystemCompressed: true, supportsP81SystemPixels: true)).map(\.route), [.systemCompressed])
    XCTAssertTrue(VideoPresentationPlanner.candidates(signal: signal,
      policy: .init(dynamicRange: .standard), environment: capable).isEmpty)
  }

  func testP81UsesOriginalPixelsWithoutDependingOnCompressedSupport() {
    let signal = p81Signal()
    for compressed in [false, true] {
      let plans = VideoPresentationPlanner.candidates(signal: signal, policy: .init(),
        environment: .init(showsHDR: true, supportsSystemCompressed: compressed, supportsP81SystemPixels: true))
      XCTAssertEqual(plans.map(\.route), [.systemPixels, .metalPixels])
      XCTAssertEqual(plans.first?.metadata, .declared)
      XCTAssertEqual(plans.last?.metadata, .baseLayerFallback)
      XCTAssertEqual(plans.last?.output, .pq)
    }
  }

  func testP81SystemCandidateDoesNotReduceUnknownOrDifferentPixelFormats() {
    let formats: [OSType?] = [nil, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
      kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
      kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_64RGBAHalf]
    for format in formats {
      let signal = p81Signal(pixels: format.map(VideoPixelDescription.init(cvFormat:)))
      let plans = VideoPresentationPlanner.candidates(signal: signal, policy: .init(),
        environment: .init(supportsSystemCompressed: true, supportsP81SystemPixels: true))
      XCTAssertEqual(plans.map(\.route), [.metalPixels])
      XCTAssertEqual(plans.first?.metadata, .baseLayerFallback)
    }
  }

  func testP81RespectsExplicitStandardRangeAndCompatibleMetadataPolicies() {
    for policy in [UmbelVideoPolicy(dynamicRange: .standard),
                   UmbelVideoPolicy(dynamicMetadata: .compatibleBaseLayer)] {
      let plans = VideoPresentationPlanner.candidates(signal: p81Signal(), policy: policy,
        environment: .init(showsHDR: true, supportsSystemCompressed: true, supportsP81SystemPixels: true))
      XCTAssertEqual(plans.map(\.route), [.metalPixels])
      XCTAssertEqual(plans.first?.metadata, .baseLayerFallback)
      XCTAssertEqual(plans.first?.output.pixelFormat, .rgba16Float)
      if policy.dynamicRange == .standard { XCTAssertTrue(plans.first?.output.isStandard == true) }
    }
  }

  func testP81PixelSupportDoesNotAuthorizeOtherProfiles() {
    let signal = VideoSignalDescription(transferCode: 18,
      dynamicHDR: .dv(profile: 8, level: 3, compatibility: 4))
    let plans = VideoPresentationPlanner.candidates(signal: signal, policy: .init(),
      environment: .init(supportsP81SystemPixels: true))
    XCTAssertEqual(plans.map(\.route), [.metalPixels])
  }

  private func p81Signal(
    pixels: VideoPixelDescription? = .init(cvFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
  ) -> VideoSignalDescription {
    .init(pixels: pixels, transferCode: 16, primariesCode: 9, matrixCode: 9, rangeCode: 1,
      dynamicHDR: .dv(profile: 8, level: 3, compatibility: 1))
  }

  func testUnknownP8CompatibilityDoesNotInventAnSDRBaseLayer() {
    let signal = VideoSignalDescription(transferCode: 2,
      dynamicHDR: .dv(profile: 8, level: 3, compatibility: 9))
    XCTAssertTrue(VideoPresentationPlanner.candidates(signal: signal, policy: .init(),
      environment: .init(supportsP84SystemPixels: true)).isEmpty)
  }
  func testSDRPrecisionDoesNotDependOnHDRCapability() throws {
    let signal = VideoSignalDescription(pixels: .init(cvFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange),
                                        transferCode: 1)
    for hdr in [false, true] {
      let plans = VideoPresentationPlanner.candidates(signal: signal, policy: .init(),
        environment: .init(showsHDR: hdr))
      XCTAssertEqual(try XCTUnwrap(plans.first).output.pixelFormat, .rgba16Float)
      XCTAssertTrue(try XCTUnwrap(plans.first).output.isStandard)
    }
  }

  func testP84SystemSupportDoesNotAuthorizeP81() throws {
    let environment = VideoEnvironmentCapabilities(supportsP84SystemPixels: true)
    let p84 = VideoSignalDescription(transferCode: 18, dynamicHDR: .dv(profile: 8, level: 3, compatibility: 4))
    let p81 = VideoSignalDescription(transferCode: 16, dynamicHDR: .dv(profile: 8, level: 3, compatibility: 1))
    let first = VideoPresentationPlanner.candidates(signal: p84, policy: .init(), environment: environment)
    let second = VideoPresentationPlanner.candidates(signal: p81, policy: .init(), environment: environment)
    XCTAssertEqual(first.first?.route, .systemPixels)
    XCTAssertEqual(second.first?.route, .metalPixels)
    XCTAssertEqual(second.first?.metadata, .baseLayerFallback)
    XCTAssertEqual(second.first?.reason, "metadataTransportUnverified")
  }

  func testForcedSDRUsesHighPrecisionBaseLayer() throws {
    let signal = VideoSignalDescription(pixels: .init(cvFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange),
      transferCode: 18, dynamicHDR: .dv(profile: 8, level: 3, compatibility: 4))
    let plan = try XCTUnwrap(VideoPresentationPlanner.candidates(signal: signal,
      policy: .init(dynamicRange: .standard), environment: .init(supportsP84SystemPixels: true)).first)
    XCTAssertEqual(plan.route, .metalPixels)
    XCTAssertEqual(plan.output.pixelFormat, .rgba16Float)
    XCTAssertTrue(plan.output.isStandard)
    XCTAssertEqual(plan.reason, "standardRangeRequested")
  }

  func testCompatiblePolicyDoesNotSelectSystemMetadata() {
    let signal = VideoSignalDescription(transferCode: 18, dynamicHDR: .dv(profile: 8, level: 3, compatibility: 4))
    let plan = VideoPresentationPlanner.candidates(signal: signal,
      policy: .init(dynamicMetadata: .compatibleBaseLayer),
      environment: .init(supportsP84SystemPixels: true)).first
    XCTAssertEqual(plan?.route, .metalPixels)
    XCTAssertEqual(plan?.reason, "compatibleBaseLayerRequested")
  }
}
