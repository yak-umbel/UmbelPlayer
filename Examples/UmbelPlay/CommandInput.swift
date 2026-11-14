import CoreMedia
import Foundation
import ImageIO
import UmbelCore

/// Commands from standard input, one per line, so a script can drive the
/// player the way the keyboard does:
///
///     seek <seconds>      jump there
///     sub <id> | off      choose a subtitle track
///     audio <id> | off    choose an audio track
///     pause | play
///     rate <speed>        0.5 to 2 times the normal speed
///     pip                 picture in picture on or off, with --pip
///     fullscreen          the window into full screen or out of it
///     size <w> <h>        the window's picture to that size, in points
///     aspect <ratio> | off
///     fill on | off
///     subdelay <seconds>
///     subscale <factor>
///     subpos <fraction>   subtitles raised by that part of the picture's height
///     audiodelay <seconds>
///     snapshot [path.png]
///     frame               report the picture's position in the view
///     status              report phase, position, level and selections
///     mute on | off
///     volume <level>      0 to 1
///     sub auto            back to choosing subtitles by the audio
///     caps                report what the current picture allows
///
/// The keyboard needs the window in front and a person at the keys. This
/// needs neither: someone else can steer while the viewer only watches.
enum CommandInput {
  static func start(
    session: PlaybackSession, stats: PlaybackStats,
    pictureInPicture: @escaping @MainActor @Sendable () -> Void,
    window: @escaping @MainActor @Sendable ([String]) -> Void
  ) -> Task<Void, Never> {
    Task.detached {
      do {
        for try await line in FileHandle.standardInput.bytes.lines {
          if line == "pip" {
            await pictureInPicture()
            continue
          }
          let words = line.split(separator: " ").map(String.init)
          if words.first == "fullscreen" || words.first == "size" {
            await window(words)
            continue
          }
          await handle(line, session: session, stats: stats)
        }
      } catch {
        // Standard input closed or unreadable: nothing more will come.
      }
    }
  }

  private static func handle(_ line: String, session: PlaybackSession, stats: PlaybackStats) async {
    let words = line.split(separator: " ").map(String.init)
    guard let command = words.first else { return }
    let argument = words.count > 1 ? words[1] : nil
    let track = argument == "off" ? nil : argument.flatMap(Int32.init).map(UmbelTrack.ID.init)
    do {
      switch command {
      case "seek":
        guard let seconds = argument.flatMap(Double.init) else { return report("usage: seek <seconds>") }
        await stats.markSeeked(to: seconds)
        Trace.log(String(format: "seek %.1f", seconds))
        report(String(format: "command: seek to %.1f s", seconds))
        try await session.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
      case "sub" where argument == "auto":
        try await session.selectSubtitleTrackAutomatically()
        report("command: subtitles auto -> \(await session.selectedSubtitleTrack.map { String($0.rawValue) } ?? "off")")
      case "sub":
        try await session.selectSubtitleTrack(track)
        report("command: subtitles \(argument ?? "?")")
      case "mute":
        await session.setMuted(argument == "on")
        report("command: mute \(await session.isMuted ? "on" : "off")")
      case "volume":
        guard let level = argument.flatMap(Float.init) else { return report("usage: volume <0 to 1>") }
        await session.setVolume(level)
        report(String(format: "command: volume %.2f", await session.volume))
      case "status":
        report(await status(of: session))
      case "caps":
        let caps = await session.videoCapabilities
        report("command: caps aspect \(caps.canOverrideAspectRatio) scale \(caps.canScalePicture)"
          + " colors \(caps.canAdjustColors) snapshot \(caps.snapshot)")
      case "audio":
        try await session.selectAudioTrack(track)
        report("command: audio \(argument ?? "?") route \(label(await session.audioRoute))")
      case "pause":
        await stats.markPaused()
        await session.pause()
        report("command: pause")
      case "rate":
        guard let speed = argument.flatMap(Double.init) else { return report("usage: rate <speed>") }
        await stats.markRateChanged()
        await session.setRate(speed)
        report(String(format: "command: rate %.2f", await session.rate))
      case "play":
        try await session.play()
        report("command: play")
      case "aspect":
        let ratio = argument == "off" ? nil : argument.flatMap(Double.init)
        await session.setAspectRatio(ratio)
        let currentRatio = await session.aspectRatio
        report("command: aspect \(currentRatio.map { String($0) } ?? "source")")
      case "fill":
        await session.setPictureScaling(argument == "on" ? .fill : .fit)
        report("command: fill \(await session.pictureScaling == .fill ? "on" : "off")")
      case "subdelay":
        await session.setSubtitleDelay(argument.flatMap(Double.init) ?? 0)
        report("command: subtitle delay \(await session.subtitleDelay) s")
      case "subscale":
        await session.setSubtitleScale(argument.flatMap(Double.init) ?? 1)
        report("command: subtitle scale \(await session.subtitleScale)")
      case "subpos":
        await session.setSubtitlePlacement(.init(verticalOffset: argument.flatMap(Double.init) ?? 0))
        report("command: subtitle placement \(await session.subtitlePlacement.verticalOffset)")
      case "audiodelay":
        await session.setAudioDelay(argument.flatMap(Double.init) ?? 0)
        report("command: audio delay \(await session.audioDelay) s")
      case "snapshot":
        let path = argument ?? "snapshot.png"
        do {
          let image = try await session.snapshot()
          try writePNG(image, to: URL(fileURLWithPath: path))
          report("command: snapshot \(image.width)x\(image.height) -> \(path)")
        } catch {
          report("command: snapshot failed: \(error.localizedDescription)")
        }
      case "frame":
        if let frame = await session.pictureFrame {
          report(String(format: "command: frame (%.3f, %.3f, %.3f, %.3f)",
                        frame.minX, frame.minY, frame.width, frame.height))
        } else {
          report("command: frame unavailable")
        }
      default:
        report("unknown command: \(line)")
      }
    } catch {
      report("command failed: \(line): \(error.localizedDescription)")
    }
  }

  private static func status(of session: PlaybackSession) async -> String {
    let phase = await session.phase
    let position = await session.currentTime.seconds
    let buffered = await session.bufferedDuration.seconds
    let audio = await session.selectedAudioTrack.map { String($0.rawValue) } ?? "off"
    let subtitle = await session.selectedSubtitleTrack.map { String($0.rawValue) } ?? "off"
    let failure = await session.failureReason.map { " | failure \($0.localizedDescription)" } ?? ""
    let video = await session.videoPresentationStatus
    return String(format: "status: phase %@ | position %.3f | buffered %.1f | rate %.2f | volume %.2f | muted %@",
                  phase.rawValue, position, buffered, await session.rate, await session.volume,
                  await session.isMuted ? "yes" : "no")
      + " | audio \(audio) | route \(label(await session.audioRoute)) | subtitle \(subtitle)"
      + " | audiodelay \(await session.audioDelay)"
      + " | video \(video.route?.rawValue ?? "none") metadata \(video.metadata.rawValue)\(failure)"
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

  private static func report(_ text: String) {
    print(text)
    fflush(stdout)
  }

  private static func writePNG(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
    else {
      throw NSError(domain: "umbel-play", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "cannot create PNG at \(url.path)"])
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
      throw NSError(domain: "umbel-play", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "cannot write PNG at \(url.path)"])
    }
  }
}
