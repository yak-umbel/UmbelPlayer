import CoreMedia
import XCTest
@testable import UmbelCore

private actor IgnoringReceiver: SubtitlePacketReceiver {
  func receive(_ packet: DemuxPacket) async {}
}

final class BytePressureReliefTests: XCTestCase {
  private let video = UmbelTrack.ID(rawValue: 0)
  private let audio = UmbelTrack.ID(rawValue: 1)
  private let subtitle = UmbelTrack.ID(rawValue: 2)

  /// Sound decoded here beside a picture: the sound is measured.
  private func engine(generation: Int = 0, audio: UmbelTrack.ID? = nil, subtitled: Bool = false) -> PacketRouting {
    PacketRouting(
      audioID: audio ?? self.audio, audioSession: nil, videoID: video, videoSession: nil,
      subtitleID: subtitled ? subtitle : nil, subtitleReceiver: subtitled ? IgnoringReceiver() : nil,
      generation: generation)
  }

  /// Sound played by the system player beside a picture: the picture is measured.
  private func system(_ route: ObjectAudioRoute, generation: Int = 0, subtitled: Bool = false) -> PacketRouting {
    PacketRouting(
      audioID: audio, audioSession: nil, objectAudio: route, videoID: video, videoSession: nil,
      subtitleID: subtitled ? subtitle : nil, subtitleReceiver: subtitled ? IgnoringReceiver() : nil,
      generation: generation)
  }

  private func objectAudioRoute() async throws -> ObjectAudioRoute {
    let demux = DemuxSession(source: try UmbelFileSource(url: ServedEAC3.fixture("eac3_movie.mkv")))
    try await demux.open()
    addTeardownBlock { await demux.close() }
    let tracks = await demux.tracks
    let sound = try XCTUnwrap(tracks.first { $0.kind == .audio })
    let found = await demux.codecParameters(for: sound.id)
    let parameters = try XCTUnwrap(found)
    return ObjectAudioRoute(
      track: sound, parameters: parameters, duration: await demux.duration, onFailure: { _ in })
  }

  /// The picture standing in for sound that has no first frame.
  private func pictureStandingIn() -> BytePressureRelief {
    var relief = BytePressureRelief()
    _ = relief.route(engine(), routed: [audio, video], revision: 0)
    _ = relief.firstFrame(of: video)
    _ = relief.relieve(soundReady: true)
    return relief
  }

  func testAPictureStandsInForSoundWithoutAFirstFrameUntilItHasOne() {
    var relief = BytePressureRelief()
    XCTAssertTrue(relief.route(engine(), routed: [audio, video], revision: 0))
    XCTAssertEqual(relief.measurement.track, audio)
    XCTAssertFalse(relief.relieve(soundReady: true), "nothing has a first frame to go on with")
    XCTAssertFalse(relief.firstFrame(of: video))
    XCTAssertTrue(relief.relieve(soundReady: true))
    XCTAssertEqual(relief.measurement.track, video)
    XCTAssertTrue(relief.measurement.gatesPlayback)
    XCTAssertTrue(relief.firstFrame(of: audio), "the sound's own first frame: it measures again")
    XCTAssertEqual(relief.measurement.track, audio)
  }

  func testASubtitleSwitchKeepsTheStandIn() {
    var relief = pictureStandingIn()
    XCTAssertTrue(relief.route(engine(subtitled: true), routed: [audio, video], revision: 1))
    XCTAssertEqual(relief.measurement.track, video)
  }

  func testASeekEndsTheStandIn() {
    var relief = pictureStandingIn()
    _ = relief.route(engine(generation: 1), routed: [audio, video], revision: 1)
    XCTAssertEqual(relief.measurement.track, audio)
  }

  func testAnotherMeasuredTrackEndsTheStandIn() {
    var relief = pictureStandingIn()
    let other = UmbelTrack.ID(rawValue: 3)
    _ = relief.route(engine(audio: other), routed: [other, video], revision: 1)
    XCTAssertEqual(relief.measurement.track, other)
  }

  func testAStandInNoLongerRoutedEnds() {
    var relief = pictureStandingIn()
    let soundOnly = PacketRouting(audioID: audio, audioSession: nil, videoID: nil, videoSession: nil, generation: 0)
    _ = relief.route(soundOnly, routed: [audio], revision: 1)
    XCTAssertEqual(relief.measurement.track, audio)
  }

  func testARouteArrivingAfterALaterOneChangesNothing() {
    var relief = BytePressureRelief()
    XCTAssertTrue(relief.route(engine(generation: 2), routed: [], revision: 5))
    XCTAssertFalse(relief.route(engine(generation: 1), routed: [], revision: 4))
    XCTAssertEqual(relief.routing.generation, 2)
  }

  /// A first frame counts only from a track that is routed; one from a
  /// track switched away is late news.
  func testOnlyRoutedTracksHaveFirstFrames() {
    var relief = BytePressureRelief()
    _ = relief.route(engine(), routed: [audio], revision: 0)
    _ = relief.firstFrame(of: video)
    XCTAssertFalse(relief.relieve(soundReady: true))
  }

  func testPlayingAgainForgetsFirstFrames() {
    var relief = BytePressureRelief()
    _ = relief.route(engine(), routed: [audio, video], revision: 0)
    _ = relief.firstFrame(of: video)
    relief.restart()
    XCTAssertFalse(relief.relieve(soundReady: true))
  }

  func testTheSystemPlayersSoundCountsOnceItsClockLeads() async throws {
    let route = try await objectAudioRoute()
    var relief = BytePressureRelief()
    _ = relief.route(system(route), routed: [video], revision: 0)
    XCTAssertEqual(relief.measurement.track, video)
    XCTAssertFalse(relief.relieve(soundReady: false))
    XCTAssertTrue(relief.relieve(soundReady: true))
    XCTAssertEqual(relief.measurement.track, audio)
    XCTAssertFalse(relief.measurement.gatesPlayback, "the system player waits for its own data")
  }

  func testAFallbackRequestStandsForItsRouteAndSeekGenerationOnly() async throws {
    let route = try await objectAudioRoute()
    var relief = BytePressureRelief()
    XCTAssertNil(relief.askForFallback(), "no system player")
    _ = relief.route(system(route), routed: [video], revision: 0)
    let request = try XCTUnwrap(relief.askForFallback())
    XCTAssertNil(relief.askForFallback(), "one at a time")
    XCTAssertTrue(relief.holds(request))
    _ = relief.route(system(route, subtitled: true), routed: [video], revision: 1)
    XCTAssertTrue(relief.holds(request), "a subtitle switch leaves it standing")
    _ = relief.route(system(route, generation: 1), routed: [video], revision: 2)
    XCTAssertFalse(relief.holds(request), "a seek leaves it stale")
    let next = try XCTUnwrap(relief.askForFallback())
    relief.settle(request)
    XCTAssertTrue(relief.holds(next), "a stale answer does not settle the request after it")
    relief.settle(next)
    XCTAssertNotNil(relief.askForFallback())
  }

  func testAFallbackRequestIsStaleOnceTheSoundIsDecodedHere() async throws {
    let route = try await objectAudioRoute()
    var relief = BytePressureRelief()
    _ = relief.route(system(route), routed: [video], revision: 0)
    let request = try XCTUnwrap(relief.askForFallback())
    _ = relief.route(engine(), routed: [audio, video], revision: 1)
    XCTAssertFalse(relief.holds(request))
    XCTAssertNil(relief.askForFallback())
  }
}
