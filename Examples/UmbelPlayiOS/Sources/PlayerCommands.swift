import CoreMedia
import Foundation
import UIKit
import UmbelCore

/// A diagnostic command copied into the app container, for an observer on
/// a physical device. Change the id for each command, e.g.
/// {"id":1,"line":"fill on"}. The same id is handled only once per launch.
@MainActor
enum PlayerCommands {
  private struct Command: Decodable {
    let id: Int
    let line: String
  }

  static func start(
    session: PlaybackSession, file: URL,
    pictureInPicture: @escaping @MainActor () -> Void,
    playing: @escaping @MainActor (Bool) -> Void
  ) -> Task<Void, Never> {
    Task {
      var lastID: Int?
      while !Task.isCancelled {
        if let data = try? Data(contentsOf: file),
           let command = try? JSONDecoder().decode(Command.self, from: data),
           command.id != lastID {
          lastID = command.id
          print("command [\(command.id)]: \(command.line)")
          await handle(command.line, session: session,
                       pictureInPicture: pictureInPicture, playing: playing)
        }
        do { try await Task.sleep(nanoseconds: 200_000_000) }
        catch { return }
      }
    }
  }

  private static func handle(
    _ line: String, session: PlaybackSession,
    pictureInPicture: @MainActor () -> Void, playing: @MainActor (Bool) -> Void
  ) async {
    let words = line.split(separator: " ").map(String.init)
    guard let name = words.first else { return }
    let argument = words.count > 1 ? words[1] : nil
    let number = argument.flatMap(Double.init)
    do {
      switch name {
      case "pause":
        await session.pause()
        playing(false)
      case "play":
        try await session.play()
        playing(true)
      case "seek":
        guard let number, number.isFinite else { return }
        try await session.seek(to: CMTime(seconds: number, preferredTimescale: 600))
      case "audio":
        let track = argument == "off" ? nil
          : argument.flatMap(Int32.init).map(UmbelTrack.ID.init)
        try await session.selectAudioTrack(track)
      case "rate":
        guard let number, number.isFinite else { return }
        await session.setRate(number)
      case "sub" where argument == "auto":
        try await session.selectSubtitleTrackAutomatically()
      case "mute":
        guard argument == "on" || argument == "off" else { return }
        await session.setMuted(argument == "on")
      case "volume":
        guard let number, number.isFinite else { return }
        await session.setVolume(Float(number))
      case "status":
        let audio = await session.selectedAudioTrack.map { String($0.rawValue) } ?? "off"
        let subtitle = await session.selectedSubtitleTrack.map { String($0.rawValue) } ?? "off"
        let video = await session.videoPresentationStatus
        print(String(format: "status: phase %@ | position %.3f | buffered %.1f | rate %.2f | volume %.2f",
                     await session.phase.rawValue, await session.currentTime.seconds,
                     await session.bufferedDuration.seconds, await session.rate, await session.volume)
          + " | muted \(await session.isMuted) | audio \(audio) | route \(Self.label(await session.audioRoute))"
          + " | subtitle \(subtitle)"
          + " | video \(video.route?.rawValue ?? "none") metadata \(video.metadata.rawValue)")
      case "caps":
        let caps = await session.videoCapabilities
        print("caps: aspect \(caps.canOverrideAspectRatio) scale \(caps.canScalePicture)"
          + " colors \(caps.canAdjustColors) snapshot \(caps.snapshot)")
      case "sub":
        let track = argument == "off" ? nil
          : argument.flatMap(Int32.init).map(UmbelTrack.ID.init)
        try await session.selectSubtitleTrack(track)
      case "aspect":
        guard argument == "off" || number != nil else { return }
        await session.setAspectRatio(number)
      case "fill":
        guard argument == "on" || argument == "off" else { return }
        await session.setPictureScaling(argument == "on" ? .fill : .fit)
      case "subdelay":
        guard let number else { return }
        await session.setSubtitleDelay(number)
      case "subscale":
        guard let number else { return }
        await session.setSubtitleScale(number)
      case "audiodelay":
        guard let number else { return }
        await session.setAudioDelay(number)
      case "pip":
        pictureInPicture()
      case "frame":
        if let frame = await session.pictureFrame {
          print(String(format: "picture frame: (%.3f, %.3f, %.3f, %.3f)",
                       frame.minX, frame.minY, frame.width, frame.height))
        } else {
          print("picture frame: unavailable")
        }
      case "snapshot":
        let image = try await session.snapshot()
        guard let data = UIImage(cgImage: image).pngData() else {
          throw UmbelError.snapshotUnavailable(reason: "PNG encoding failed")
        }
        let url = try documentsFile(argument ?? "snapshot.png")
        try data.write(to: url, options: .atomic)
        print("snapshot: \(image.width)x\(image.height) -> \(url.lastPathComponent)")
      case "notices":
        let notices = Umbel.thirdPartyNotices
        for notice in notices {
          print("notice: \(notice.name) \(notice.version) \(notice.license), \(notice.text.count) characters")
        }
        let text = notices.map { "\($0.name) \($0.version) [\($0.license)]\n\($0.text)" }
          .joined(separator: "\n\n")
        try text.write(to: documentsFile("notices.txt"), atomically: true, encoding: .utf8)
      default:
        print("unknown command: \(line)")
      }
    } catch {
      print("command failed: \(line): \(error)")
    }
  }

  private static func documentsFile(_ name: String) throws -> URL {
    let directory = try FileManager.default.url(
      for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    return directory.appendingPathComponent(URL(fileURLWithPath: name).lastPathComponent)
  }

  /// How the sound plays, in a word or two, and why it came back if it did.
  static func label(_ route: UmbelAudioRoute) -> String {
    switch route {
    case .none: return "none"
    case .engine: return "engine"
    case .systemPlayer: return "system-player"
    case .engineAfterFallback(let reason): return "engine (system player: \(reason))"
    }
  }
}
