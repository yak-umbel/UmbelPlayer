import XCTest
@testable import UmbelFFmpegSupport

private actor FixtureBytes {
  private let data: Data
  private var position = 0

  init(named name: String) throws {
    data = try Data(contentsOf: FixtureLocator.url(for: name))
  }

  func read(maxLength: Int) -> Data {
    guard position < data.count else { return Data() }
    let end = min(position + maxLength, data.count)
    defer { position = end }
    return data.subdata(in: position..<end)
  }

  func seek(to offset: Int64) { position = min(Int(offset), data.count) }

  var length: Int64 { Int64(data.count) }
}

private func openedDemuxer(named name: String) async throws -> FFmpegDemuxer {
  let bytes = try FixtureBytes(named: name)
  let demuxer = FFmpegDemuxer(
    callbacks: FFmpegIOCallbacks(
      read: { maxLength in await bytes.read(maxLength: maxLength) },
      seek: { offset in await bytes.seek(to: offset) },
      totalLength: { await bytes.length },
      canSeek: true),
    configuration: .init())
  try await demuxer.open()
  return demuxer
}

/// Each fixture is the same 128×64 picture with another display matrix
/// written beside it (Tools/make_fixtures.sh).
final class FFmpegRotationDeclarationTests: XCTestCase {
  func testStreamsReportTheirRotationClockwise() async throws {
    let declared: [(name: String, degrees: Int32)] = [
      ("rotation_none.mp4", 0), ("rotation_cw90.mp4", 90), ("rotation_cw180.mp4", 180),
      ("rotation_cw270.mp4", 270), ("rotation_flipped.mp4", 0), ("rotation_45.mp4", 0),
    ]
    for (name, degrees) in declared {
      let demuxer = try await openedDemuxer(named: name)
      let streams = await demuxer.streams()
      let video = try XCTUnwrap(streams.first { $0.mediaType == .video }, name)
      XCTAssertEqual(video.width, 128, name)
      XCTAssertEqual(video.height, 64, name)
      XCTAssertEqual(video.rotation, degrees, name)
      await demuxer.close()
    }
  }

  func testAStreamInfoMadeByHandTurnsNothingByDefault() {
    let info = FFmpegStreamInfo(
      index: 0, mediaType: .video, codecName: "h264", language: nil, title: nil,
      isDefault: true, isForced: false, width: 16, height: 16,
      frameRateNum: 25, frameRateDen: 1, channelCount: 0, sampleRate: 0)
    XCTAssertEqual(info.rotation, 0)
  }
}
