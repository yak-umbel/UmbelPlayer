import AVFoundation
import CoreMedia
import XCTest
@testable import UmbelCore

/// A sound track written as fragmented MP4, the form the system player takes
/// segments in: one initialization segment, then fragments that each stand at
/// their own place in time.
final class FragmentedAudioTests: XCTestCase {
  private func fixture(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures").appendingPathComponent(name)
  }

  /// eac3_movie.mkv: 12 s, its E-AC-3 track 375 packets of 32 ms.
  private func soundPackets() async throws -> (track: FragmentedAudioTrack, packets: [DemuxPacket]) {
    let demux = DemuxSession(source: try UmbelFileSource(url: fixture("eac3_movie.mkv")))
    try await demux.open()
    let tracks = await demux.tracks
    let sound = try XCTUnwrap(tracks.first { $0.kind == .audio })
    var packets: [DemuxPacket] = []
    while let packet = try await demux.nextPacket() {
      if packet.trackID == sound.id { packets.append(packet) }
    }
    let found = await demux.codecParameters(for: sound.id)
    let parameters = try XCTUnwrap(found)
    await demux.close()
    // The encoder starts sound 5 ms before 0.
    let shift = CMTime(seconds: max(0, -packets[0].presentationTime.seconds), preferredTimescale: 1_000)
    let track = try FragmentedAudioTrack.make(parameters: parameters, leading: Array(packets.prefix(4)), shift: shift)
    return (track, packets)
  }

  private func write(_ parts: [Data]) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("fragmented-\(UUID().uuidString).mp4")
    try parts.reduce(Data(), +).write(to: url)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }

  func testTheInitializationSegmentDescribesTheStreamAlone() async throws {
    let (track, _) = try await soundPackets()
    XCTAssertEqual(MP4Box.children(of: track.initSegment).map(\.type), ["ftyp", "moov"])
    XCTAssertNotNil(MP4Box.find(["moov", "trak", "mdia", "minf", "stbl", "stsd"], in: track.initSegment))
    XCTAssertTrue(track.initSegment.range(of: Data("dec3".utf8)) != nil, "the stream description FFmpeg parsed")
    XCTAssertEqual(track.timescale, 48_000)
  }

  func testInitializationAndFragmentsMakeWhatTheSystemReadsWhole() async throws {
    let (track, packets) = try await soundPackets()
    var parts = [track.initSegment]
    var sequence: UInt32 = 1
    for start in stride(from: 0, to: packets.count, by: 188) {
      parts.append(track.fragment(sequence: sequence, packets: Array(packets[start..<min(start + 188, packets.count)])))
      sequence += 1
    }
    let asset = AVURLAsset(url: try write(parts))
    let duration = try await asset.load(.duration)
    XCTAssertEqual(duration.seconds, 12.0, accuracy: 0.05)
    let tracks = try await asset.loadTracks(withMediaType: .audio)
    let audio = try XCTUnwrap(tracks.first)
    let formats = try await audio.load(.formatDescriptions)
    let format = try XCTUnwrap(formats.first)
    XCTAssertEqual(CMFormatDescriptionGetMediaSubType(format), kAudioFormatEnhancedAC3)
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: audio, outputSettings: nil)
    reader.add(output)
    XCTAssertTrue(reader.startReading())
    var samples = 0
    while let buffer = output.copyNextSampleBuffer() { samples += CMSampleBufferGetNumSamples(buffer) }
    XCTAssertEqual(samples, packets.count, "every frame, none lost or doubled")
  }

  /// After a seek segments start anywhere: each fragment carries its own
  /// time, in `tfdt`, which a streaming player places it by. (A file reader
  /// lays a lone fragment from 0 whatever it says; the player is checked
  /// playing real segments elsewhere.)
  func testAFragmentStandsAtItsOwnTime() async throws {
    let (track, packets) = try await soundPackets()
    let fragment = track.fragment(sequence: 2, packets: Array(packets[188...]))
    let decodeTime = try XCTUnwrap(MP4Box.find(["moof", "traf", "tfdt"], in: fragment))
    XCTAssertEqual(fragment[decodeTime.lowerBound], 1, "a 64-bit time")
    let high = UInt64(MP4Box.readUInt32(fragment, at: decodeTime.lowerBound + 4))
    let low = UInt64(MP4Box.readUInt32(fragment, at: decodeTime.lowerBound + 8))
    let expected = ((packets[188].presentationTime + track.shift).seconds * 48_000).rounded()
    XCTAssertEqual(high << 32 | low, UInt64(expected), "the packet's own time, shifted")
    let runs = try XCTUnwrap(MP4Box.find(["moof", "traf", "trun"], in: fragment))
    XCTAssertEqual(MP4Box.readUInt32(fragment, at: runs.lowerBound + 4), UInt32(packets.count - 188))
  }

  private func decodeTime(of fragment: Data) throws -> UInt64 {
    let box = try XCTUnwrap(MP4Box.find(["moof", "traf", "tfdt"], in: fragment))
    return UInt64(MP4Box.readUInt32(fragment, at: box.lowerBound + 4)) << 32
      | UInt64(MP4Box.readUInt32(fragment, at: box.lowerBound + 8))
  }

  /// Fragments meet end to start: no gap, no overlap, the first at 0.
  func testFragmentsFollowOneAnotherFromZero() async throws {
    let (track, packets) = try await soundPackets()
    var expected: UInt64 = 0
    for (index, start) in stride(from: 0, to: packets.count, by: 188).enumerated() {
      let part = Array(packets[start..<min(start + 188, packets.count)])
      let fragment = track.fragment(sequence: UInt32(index + 1), packets: part)
      XCTAssertEqual(try decodeTime(of: fragment), expected, "fragment \(index)")
      expected += UInt64(part.count) * 1536
    }
  }
}
