import AppKit
import CoreMedia
import Darwin
import Foundation
import Metal
import QuartzCore
import UmbelCore

@main
struct UmbelPlay {
  static func main() {
    Trace.begin()
    // `--header "Name: Value"`, as many as needed, anywhere: the headers a
    // site wants on every request, the Referer most often.
    let arguments = CommandLine.arguments
    var positional: [String] = []
    var headers: [String: String] = [:]
    // --no-sound: no audio output at all, the clock kept by the host — for
    // a machine whose audio device is not running.
    var sound = true
    // --pip: picture in picture, from the key p or the command pip.
    var pip = false
    // --engine-audio: sound through the audio engine, as before the system's
    // renderer took it — to compare the two.
    var engineAudio = false
    var timestampDiagnostics = false
    // --no-object-audio: E-AC-3 with objects decoded here too, not played
    // by the system player — to compare the two.
    var objectAudio = UmbelObjectAudioMode.automatic
    var index = 1
    while index < arguments.count {
      if ["--no-sound", "--pip", "--engine-audio", "--no-object-audio", "--diagnostics"].contains(arguments[index]) {
        switch arguments[index] {
        case "--pip": pip = true
        case "--engine-audio": engineAudio = true
        case "--diagnostics": timestampDiagnostics = true
        case "--no-object-audio": objectAudio = .off
        default: sound = false
        }
        index += 1
        continue
      }
      if arguments[index] == "--header", index + 1 < arguments.count {
        let pair = arguments[index + 1].split(separator: ":", maxSplits: 1)
        if pair.count == 2 {
          headers[pair[0].trimmingCharacters(in: .whitespaces)] =
            pair[1].trimmingCharacters(in: .whitespaces)
        }
        index += 2
        continue
      }
      positional.append(arguments[index])
      index += 1
    }
    guard !positional.isEmpty else {
      print("usage: umbel-play <media file or http URL> [seconds to play] [external subtitle file]"
        + " [--header \"Name: Value\"]... [--no-sound] [--pip] [--engine-audio] [--no-object-audio] [--diagnostics]")
      exit(2)
    }

    let url = positional[0].range(of: "://") != nil
      ? (URL(string: positional[0]) ?? URL(fileURLWithPath: positional[0]))
      : URL(fileURLWithPath: positional[0])
    let seconds = positional.count >= 2 ? (Double(positional[1]) ?? 10) : 10
    let subtitleURL = positional.count >= 3 ? URL(fileURLWithPath: positional[2]) : nil

    Task { @MainActor in
      let status = await play(
        url: url, headers: headers, seconds: seconds, subtitle: subtitleURL, sound: sound,
        engineAudio: engineAudio, objectAudio: objectAudio, pip: pip, timestampDiagnostics: timestampDiagnostics)
      exit(status)
    }
    // The main thread goes to AppKit's event loop.
    //
    // **Not RunLoop.main.run()**: that only turns the run loop and does not
    // dispatch events to the application through sendEvent, so the keyboard
    // gets nothing — while the window shows as usual, layers committing by
    // another route, and all looks well. The task above ends playback with
    // exit.
    NSApplication.shared.run()
  }

  /// The video's own size, shrunk to fit the screen with the aspect kept.
  ///
  /// A 1080p picture is 1920 × 1080 points, wider than most laptop screens;
  /// opened at that size the window runs off the edge. Four fifths of the
  /// visible area at most leaves room for the terminal beside it.
  ///
  /// `UMBEL_WINDOW=left` or `right` puts the window in that half of the
  /// screen instead, so two players can run side by side — HDR against SDR,
  /// say, with `UMBEL_SDR=1` on one of them.
  @MainActor
  private static func fittedWindowSize(width: Int, height: Int) -> (width: Int, height: Int) {
    guard width > 0, height > 0, let visible = NSScreen.main?.visibleFrame else {
      return (width, height)
    }
    let share = PlayerWindow.Side.fromEnvironment == nil ? 0.8 : 0.49
    let scale = min(1, visible.width * share / Double(width), visible.height * 0.8 / Double(height))
    return (Int((Double(width) * scale).rounded()), Int((Double(height) * scale).rounded()))
  }

  @MainActor
  private static func play(
    url: URL, headers: [String: String], seconds: Double, subtitle: URL?, sound: Bool,
    engineAudio: Bool, objectAudio: UmbelObjectAudioMode, pip: Bool, timestampDiagnostics: Bool
  ) async -> Int32 {
    let diagnostics = timestampDiagnostics ? UmbelPlaybackDiagnostics() : nil
    let diagnosticExport = Trace.startPlaybackDiagnostics(diagnostics)
    let status: Int32
    do {
      let startedAt = Date()
      // By scheme: http and https from the network, anything else a local file.
      let source: UmbelSource
      var diskCache: UmbelDiskCache?
      if url.scheme == "http" || url.scheme == "https" {
        // Network media goes through a disk cache, as a host without one of
        // its own would set it up: played once, it plays again from disk,
        // offline too. The URL is the key; these test links do not change.
        let cache = try UmbelDiskCache(directory: cacheDirectory(), capacity: 2 << 30)
        diskCache = cache
        source = UmbelBufferedSource(
          wrapping: UmbelDiskCacheSource(
            wrapping: UmbelHTTPSource(url: url, headers: headers), key: url.absoluteString,
            cache: cache))
        let held = await cache.cachedBytes(forKey: url.absoluteString)
        print(String(format: "disk cache: %.1f MB of this already held", Double(held) / 1_000_000))
      } else {
        source = UmbelBufferedSource(wrapping: try UmbelFileSource(url: url))
      }

      // The display layer exists before the window: the renderer needs it
      // when constructed, and the window's size is known only once the media
      // is open. Only a video track brings a window to show it.
      let stats = PlaybackStats()
      let display = DisplayLayerHandle()
      let renderer = makeRenderer(layer: display.layer)
      // Made whatever the options: a picture only the system can show goes to its layer.
      let pictureInPicture = renderer.flatMap(PictureInPictureSetup.init(main:))
      // The system's renderer: it spatializes multichannel sound, follows the
      // output device, and keeps the time for sound and picture alike.
      let audioOutput: (any AudioOutput)?
      if !sound {
        audioOutput = nil
      } else if engineAudio {
        audioOutput = EngineAudioOutput()
      } else {
        audioOutput = SampleBufferAudioOutput()
      }
      let session = PlaybackSession(
        source: source,
        audioOutput: audioOutput,
        videoRenderer: (pictureInPicture?.renderer as (any VideoRenderer)?) ?? renderer,
        objectAudio: objectAudio, diagnostics: diagnostics
      )

      try await session.load()
      print(String(format: "opened in %.0f ms", Date().timeIntervalSince(startedAt) * 1000))

      if let subtitle {
        // Shown at once: passing a file on the command line is choosing it.
        let track = try await session.addExternalSubtitle(
          try UmbelFileSource(url: subtitle), title: subtitle.lastPathComponent)
        try await session.selectSubtitleTrack(track.id)
      }

      let tracks = await session.tracks
      let duration = await session.duration
      print("\(tracks.count) tracks, \(format(duration)) long")
      for track in tracks {
        print("  [\(track.id.rawValue)] \(track.kind.rawValue) \(track.codecName)"
              + (track.language.map { " (\($0))" } ?? "")
              + (track.isForced ? " forced" : "") + (track.isExternal ? " external" : "")
              + (track.isDecodable ? "" : " not decodable")
              + (track.video?.dynamicHDR.map { " \($0.label)" } ?? ""))
      }
      print("system DV display: \(SampleBufferVideoRenderer.systemCanShowDV ? "available" : "unavailable")")
      print("audio output: \(sound ? (engineAudio ? "engine" : "sample buffer") : "none")")
      print("audio route: \(CommandInput.label(await session.audioRoute))")
      // The copies actually loaded: another FFmpeg or libass in an app would show here.
      print("libraries: FFmpeg \(Umbel.ffmpegVersion ?? "unknown") (\(Umbel.ffmpegLicense ?? "no license")), libass \(Umbel.libassVersion)")
      let route = await session.videoPresentationStatus.route
      let systemShowsPicture = route == .systemPixels || route == .systemCompressed

      var window: PlayerWindow?
      if let description = tracks.first(where: { $0.kind == .video })?.video, renderer != nil {
        // A plain executable may not come to the front; without this no window appears.
        NSApplication.shared.setActivationPolicy(.regular)
        // The picture as shown: DVD and broadcast pixels are not square, and
        // a phone's picture may be stored sideways.
        let fitted = fittedWindowSize(width: description.displayWidth, height: description.displayHeight)
        let created = PlayerWindow(
          session: session,
          stats: stats,
          layer: display.layer,
          width: fitted.width,
          height: fitted.height)
        created.show()
        created.startDisplayLoop()
        created.startKeyboardControl(duration: duration)
        if let pictureInPicture, let view = created.contentView {
          pictureInPicture.attach(
            to: view, picture: created.pictureView, below: systemShowsPicture,
            session: session, controls: pip)
          if pip { created.onPictureInPicture = { pictureInPicture.toggle() } }
        }
        window = created
        print("keys: ← → back and forward 10 s, 0–9 to tenths of the way, space pause and play, a next audio track, s next subtitles")
        print(String(format: "display EDR headroom: up to %.1f", headroom().potential))
      } else if !tracks.contains(where: { $0.kind == .audio }) {
        throw UmbelError.videoRenderUnavailable(
          reason: "neither a video track that can be drawn nor an audio track")
      }

      print("playing; stopping in \(Int(seconds)) s…")
      try await session.play()
      let playerWindow = window
      let commands = CommandInput.start(
        session: session, stats: stats, pictureInPicture: { pictureInPicture?.toggle() },
        window: { words in playerWindow?.command(words) })

      // Time to sound: from asking to play until the clock really moves.
      // Audio anchors move the clock, so its moving means the speaker is
      // playing the first samples.
      var soundedAt: Date?
      for _ in 0..<600 {
        if await session.currentTime > .zero { soundedAt = Date(); break }
        try await Task.sleep(nanoseconds: 5_000_000)
      }
      if let soundedAt {
        print(String(format: sound ? "sound after %.0f ms" : "clock moving after %.0f ms",
                     soundedAt.timeIntervalSince(startedAt) * 1000))
      } else {
        print("no sound within three seconds")
      }

      // A line of diagnostics every 5 seconds: drift is a number the eye
      // cannot judge, so it is written down. "offset" = clock position − wall
      // time elapsed: how far the audio clock has parted from the host clock.
      // "frame" = how early or late the latest frame was against the clock.
      let playBegan = Date()
      let deadline = playBegan.addingTimeInterval(seconds)
      var nextReport = 5.0
      var lastPhase: UmbelPlaybackPhase?
      var lastRoute: UmbelAudioRoute?
      while Date() < deadline {
        // Traced, stalls are timed; a fifth of a second is too coarse.
        try await Task.sleep(nanoseconds: Trace.isOn ? 5_000_000 : 200_000_000)
        let wall = Date().timeIntervalSince(playBegan)

        // How the sound plays can change by itself: the system player given back.
        let route = await session.audioRoute
        if route != lastRoute {
          if lastRoute != nil { print("audio route now \(CommandInput.label(route))") }
          lastRoute = route
        }

        // Every phase change gets its own line, so a stall on screen can be
        // matched against what the session reported at the same moment.
        let phase = await session.phase
        if phase != lastPhase {
          lastPhase = phase
          let buffered = await session.bufferedDuration
          var line = String(
            format: "wall %@ | phase %@ | buffered %.1f s",
            format(CMTime(seconds: wall, preferredTimescale: 600)),
            phase.rawValue, buffered.seconds)
          if phase == .failed, let reason = await session.failureReason {
            line += " | reason \(reason.localizedDescription)"
          }
          print(line)
          fflush(stdout)
          Trace.log("phase \(phase.rawValue)")
        }

        guard wall >= nextReport else { continue }
        nextReport += 5
        let now = await session.currentTime
        let shown = await stats.presented
        let lost = await stats.dropped
        let offset = await stats.lastOffsetMilliseconds
        let skipped = await stats.skipped
        let seeked = await stats.hasSeeked
        let paused = await stats.hasPaused
        let rateChanged = await stats.hasChangedRate
        let line = String(
          format: "wall %@ | position %@ | offset %@ | frame %+.0f ms | shown %d dropped %d skipped %d | memory %.0f MB | EDR %.1f",
          format(CMTime(seconds: wall, preferredTimescale: 600)),
          format(now),
          seeked
            ? "n/a after a seek" as NSString
            : paused
            ? "n/a after a pause" as NSString
            : rateChanged
            ? "n/a after a change of rate" as NSString
            : String(format: "%+.3f s", now.seconds - wall) as NSString,
          offset, shown, lost, skipped, footprintMB(), headroom().current)
        print(line)
        fflush(stdout)
      }

      let shown = await stats.presented
      let lost = await stats.dropped
      Trace.log("end presented \(shown) dropped \(lost)")
      commands.cancel()
      window?.stopKeyboardControl()
      window?.stopDisplayLoop()
      await session.stop()
      if let diskCache {
        let held = await diskCache.cachedBytes(forKey: url.absoluteString)
        let used = await diskCache.usedBytes
        print(String(
          format: "disk cache: %.1f MB of this, %.1f MB in all", Double(held) / 1_000_000, Double(used) / 1_000_000))
      }
      print("done.")
      status = 0
    } catch {
      print("failed: \(error)")
      status = 1
    }
    diagnosticExport?.cancel()
    await diagnosticExport?.value
    return status
  }

  /// Where the example keeps network media: the user's cache folder, which
  /// the system may clear when space runs short.
  private static func cacheDirectory() -> URL {
    FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("UmbelPlay")
  }

  /// Without a Metal device there is no picture, but sound still plays: the
  /// example should not quit for being unable to draw.
  ///
  /// HDR is shown as HDR where the system can; `UMBEL_SDR=1` asks for
  /// standard range instead, to compare the two.
  private static func makeRenderer(layer: sending CAMetalLayer) -> MetalVideoRenderer? {
    guard let device = MTLCreateSystemDefaultDevice() else { return nil }
    let standard = ProcessInfo.processInfo.environment["UMBEL_SDR"] == "1"
    print(standard ? "dynamic range: standard (HDR tone-mapped to SDR)" : "dynamic range: automatic (HDR where it can be shown)")
    return try? MetalVideoRenderer(
      layer: layer,
      device: device,
      dynamicRange: standard ? .standard : .automatic,
      tolerance: CMTime(seconds: 0.02, preferredTimescale: 600))
  }

  /// How far above SDR white the main screen can go, and goes now. Above 1
  /// now means the system is showing something in extended dynamic range:
  /// the one sign of HDR a screenshot cannot give.
  @MainActor
  private static func headroom() -> (potential: Double, current: Double) {
    guard let screen = NSScreen.main else { return (1, 1) }
    return (
      Double(screen.maximumPotentialExtendedDynamicRangeColorComponentValue),
      Double(screen.maximumExtendedDynamicRangeColorComponentValue))
  }

  /// The process's physical memory footprint: over a long run, does it only
  /// climb?
  private static func footprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    guard result == KERN_SUCCESS else { return -1 }
    return Double(info.phys_footprint) / 1024 / 1024
  }

  private static func format(_ time: CMTime) -> String {
    guard time.isValid, !time.isIndefinite else { return "unknown" }
    let total = Int(time.seconds)
    return String(format: "%02d:%02d", total / 60, total % 60)
  }
}
