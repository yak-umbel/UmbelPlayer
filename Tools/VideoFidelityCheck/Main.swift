import AVFoundation
import CryptoKit
import Foundation
import Metal
import UmbelCore
import UmbelFFmpegSupport

private struct Manifest: Decodable {
  struct Sample: Decodable {
    let id: String
    let path: String
    let sha256: String
    let license: String
  }
  let schemaVersion: Int
  let samples: [Sample]
}

private enum CheckFailure: String, Error {
  case invalidArguments, invalidManifest, hashMismatch, missingRPU, cannotReadCompressedSamples
}

private final class DisplayBox: @unchecked Sendable {
  let layer = AVSampleBufferDisplayLayer()
}

private actor FileCursor {
  let source: UmbelFileSource
  var position: Int64 = 0
  init(url: URL) throws { source = try UmbelFileSource(url: url) }
  func read(_ count: Int) async throws -> Data {
    let data = try await source.read(offset: position, maxLength: count)
    position += Int64(data.count)
    return data
  }
  func seek(_ offset: Int64) { position = offset }
  var length: Int64? { get async { await source.contentLength } }
}

/// Checks transport using real media. It does not certify display mapping.
@main private struct VideoFidelityCheck {
  @MainActor static func main() async {
    do {
      let args = Array(CommandLine.arguments.dropFirst())
      guard args.count == 4, args[0] == "--manifest", args[2] == "--report" else {
        throw CheckFailure.invalidArguments
      }
      let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
      guard manifest.schemaVersion == 1, !manifest.samples.isEmpty,
            Set(manifest.samples.map(\.id)).count == manifest.samples.count else { throw CheckFailure.invalidManifest }
      var reports: [[String: Any]] = []
      for sample in manifest.samples {
        guard !sample.id.isEmpty, !sample.license.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              sample.sha256.count == 64 else { throw CheckFailure.invalidManifest }
        let url = URL(fileURLWithPath: sample.path)
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard hash == sample.sha256.lowercased() else { throw CheckFailure.hashMismatch }
        let count = try await rpuCount(url: url)
        guard count > 0 else { throw CheckFailure.missingRPU }
        reports.append(try await check(sampleID: sample.id, hash: hash, url: url, rpuCount: count))
      }
      let passed = reports.allSatisfy { ($0["transportDelivered"] as? Bool) == true }
      let report: [String: Any] = ["schemaVersion": 1, "samples": reports, "transportChecksPassed": passed,
        "displayAttached": false, "effectValidated": false, "pictureInPictureEffectValidated": false,
        "systemVersion": ProcessInfo.processInfo.operatingSystemVersionString]
      try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        .write(to: URL(fileURLWithPath: args[3]), options: .atomic)
      print("video transport checks completed: \(reports.count); visual effects remain unverified")
      if !passed { exit(1) }
    } catch {
      if let failure = error as? CheckFailure { print("video transport check failed: \(failure.rawValue)") }
      else { let e = error as NSError; print("video transport check failed: \(e.domain) \(e.code)") }
      exit(1)
    }
  }

  private static func rpuCount(url: URL) async throws -> Int {
    let cursor = try FileCursor(url: url)
    let demux = FFmpegDemuxer(callbacks: .init(read: { try await cursor.read($0) },
      seek: { await cursor.seek($0) }, totalLength: { await cursor.length }, canSeek: true), configuration: .init())
    try await demux.open()
    do {
    guard let track = await demux.streams().first(where: { $0.mediaType == .video }),
          let parameters = await demux.codecParameters(streamIndex: track.index),
          parameters.extradata.count >= 23 else { throw CheckFailure.cannotReadCompressedSamples }
    let hvcC = parameters.extradata
    let lengthBytes = Int(hvcC[21] & 3) + 1
    var count = 0
    for _ in 0..<64 {
      guard let packet = try await demux.readPacket() else { break }
      if packet.streamIndex != track.index { continue }
      let bytes = [UInt8](packet.data)
      var position = 0
      while position + lengthBytes <= bytes.count {
        var size = 0
        for index in 0..<lengthBytes { size = size << 8 | Int(bytes[position + index]) }
        position += lengthBytes
        guard size >= 2, size <= bytes.count - position else { break }
        if (bytes[position] >> 1) & 63 == 62 { count += 1 }
        position += size
      }
    }
    await demux.close()
    return count
    } catch { await demux.close(); throw error }
  }

  @MainActor private static func check(sampleID: String, hash: String, url: URL, rpuCount: Int) async throws -> [String: Any] {
    guard let gpu = MTLCreateSystemDefaultDevice() else { throw CheckFailure.invalidManifest }
    let display = DisplayBox()
    let renderer = try SampleBufferVideoRenderer(layer: display.layer, device: gpu, tolerance: .zero)
    let diagnostics = UmbelPlaybackDiagnostics(capacity: 1000)
    let session = PlaybackSession(source: try UmbelFileSource(url: url), videoRenderer: renderer,
      videoPolicy: .init(), diagnostics: diagnostics)
    try await session.load()
    try await session.play()
    var presentations = 0
    do {
      for _ in 0..<120 {
        if try await session.renderVideoFrame() != nil { presentations += 1 }
        try await Task.sleep(nanoseconds: 16_000_000)
      }
    } catch { await session.stop(); throw error }
    let status = await session.videoPresentationStatus
    let playbackFailed = await session.phase == .failed
    let layerFailed = display.layer.status == .failed
    await session.stop()
    func value<T>(_ optional: T?) -> Any { optional.map { $0 as Any } ?? NSNull() }
    return ["sampleID": sampleID, "sha256": hash, "rpuNALCount": rpuCount,
      "presentations": presentations, "layerFailed": layerFailed, "playbackFailed": playbackFailed,
      "transportDelivered": presentations > 0 && !layerFailed && !playbackFailed,
      "route": value(status.route?.rawValue), "sourceFormat": value(status.source?.format),
      "decodedFormat": value(status.decoded?.format), "decodedBits": value(status.decoded?.effectiveBits),
      "outputFormat": value(status.outputFormat), "metadataStatus": status.metadata.rawValue,
      "qualityChanges": status.qualityChanges, "reason": value(status.reason), "effectValidated": false,
      "routeFailures": diagnostics.snapshot().events.filter { $0.name == "video_route_transition" }.map { $0.labels["reason"] ?? "unknown" },
      "qualityEvents": diagnostics.snapshot().events.filter { $0.name == "video_quality_changed" }.count]
  }
}
