import CoreMedia
import XCTest
@testable import UmbelCore

/// DV profile 5's packets become frames that carry their compressed sample,
/// for the system to decode and show.
final class SystemDecodeSessionTests: XCTestCase {
  func testNativePreparationDefersOnlyLateParameterSetsAndKeepsThePicturesMetadata() async throws {
    let demux = DemuxSession(source: try UmbelFileSource(url: fixture("dv_p84.mp4")))
    try await demux.open()
    addTeardownBlock { await demux.close() }
    let tracks = await demux.tracks
    let track = try XCTUnwrap(tracks.first { $0.kind == .video })
    let found = await demux.codecParameters(for: track.id)
    let parameters = try XCTUnwrap(found)
    let sets = try XCTUnwrap(HEVCParameterSets.arrays(inHvcC: parameters.extradata))
    var first: DemuxPacket?
    while first == nil, let packet = try await demux.nextPacket() {
      if packet.trackID == track.id { first = packet }
    }
    let packet = try XCTUnwrap(first)
    let units = HEVCParameterSets.units(in: packet.data, lengthSize: 4).filter {
      let kind = ($0.first! >> 1) & 63
      return !(32...34).contains(kind)
    }
    // A synthetic RPU sentinel checks association and framing, not visual effects.
    let kept = HEVCParameterSets.lengthPrefixed(units + [Data([124, 1, 85])])
    let input = kept + HEVCParameterSets.lengthPrefixed([sets.vps, sets.sps, sets.pps])
    for prepare in [false, true] {
      let session = try SystemDecodeSession(parameters: parameters, record: try XCTUnwrap(parameters.dovi), preparesParameterSets: prepare)
      let changed = DemuxPacket(trackID: packet.trackID, data: input, presentationTime: packet.presentationTime,
        decodeTime: packet.decodeTime, duration: packet.duration, isKeyframe: true)
      let frames = try await session.decode(changed, hidden: false)
      let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(try XCTUnwrap(frames.first?.compressedSample)))
      var bytes = [UInt8](repeating: 0, count: CMBlockBufferGetDataLength(block))
      XCTAssertEqual(CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: &bytes), noErr)
      XCTAssertEqual(Data(bytes), prepare ? kept : input)
      await session.close()
    }
  }
  func testP84SystemFramesDescribeTheirHLGBaseLayer() async throws {
    let (session, packets) = try await opened("dv_p84.mp4")
    let frames = try await session.decode(packets[0], hidden: false)
    let frame = try XCTUnwrap(frames.first)
    XCTAssertEqual(frame.color.transfer, .hlg)
    XCTAssertEqual(frame.presentationRoute, .systemCompressed)
  }
  private func fixture(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures").appendingPathComponent(name)
  }

  private func opened(_ name: String) async throws -> (SystemDecodeSession, [DemuxPacket]) {
    let demux = DemuxSession(source: try UmbelFileSource(url: fixture(name)))
    try await demux.open()
    addTeardownBlock { await demux.close() }
    let tracks = await demux.tracks
    let video = try XCTUnwrap(tracks.first { $0.kind == .video })
    let found = await demux.codecParameters(for: video.id)
    let parameters = try XCTUnwrap(found)
    let session = try SystemDecodeSession(parameters: parameters, record: try XCTUnwrap(parameters.dovi))
    var packets: [DemuxPacket] = []
    while packets.count < 30, let packet = try await demux.nextPacket() {
      if packet.trackID == video.id { packets.append(packet) }
    }
    return (session, packets)
  }

  func testPacketsBecomeCompressedFrames() async throws {
    let (session, packets) = try await opened("dv_p5.mp4")
    var frames: [VideoFrame] = []
    for packet in packets.prefix(10) { frames += try await session.decode(packet, hidden: false) }
    XCTAssertEqual(frames.count, 10)
    for (frame, packet) in zip(frames, packets) {
      XCTAssertNotNil(frame.compressedSample)
      XCTAssertNil(frame.pixelBuffer)
      XCTAssertTrue(frame.isShown)
      XCTAssertEqual(frame.presentationTime, packet.presentationTime)
      XCTAssertEqual(frame.width, 320)
      XCTAssertEqual(frame.height, 240)
    }
  }

  func testHiddenPacketsBecomeFramesNotShown() async throws {
    let (session, packets) = try await opened("dv_p5.mp4")
    let frames = try await session.decode(packets[0], hidden: true)
    XCTAssertEqual(frames.count, 1)
    XCTAssertFalse(frames[0].isShown)
  }

  func testFlushWaitsForAKeyframe() async throws {
    let (session, packets) = try await opened("dv_p5.mp4")
    _ = try await session.decode(packets[0], hidden: false)
    await session.flush()
    let other = try XCTUnwrap(packets.first { !$0.isKeyframe })
    let frames = try await session.decode(other, hidden: false)
    XCTAssertTrue(frames.isEmpty, "after a flush nothing goes out before a keyframe")
  }

  func testNothingIsHeldBack() async throws {
    let (session, packets) = try await opened("dv_p5.mp4")
    _ = try await session.decode(packets[0], hidden: false)
    let drained = try await session.drain()
    XCTAssertTrue(drained.isEmpty, "the system holds the frames, not this session")
  }
}
