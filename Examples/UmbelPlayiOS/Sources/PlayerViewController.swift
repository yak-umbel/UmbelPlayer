import AVFoundation
import CoreMedia
@preconcurrency import Metal  // MTLDevice is not Sendable in the older SDKs
import QuartzCore
import UIKit
import UmbelCore
import UmbelUI

/// The picture in a Metal layer, a second layer for picture in picture
/// under it, a row of buttons and a status line.
final class PlayerViewController: UIViewController {
  private let options: LaunchOptions
  private let metalView = MetalLayerView()
  private let sampleView = SampleBufferView()
  private let status = UILabel()
  private var session: PlaybackSession?
  private var renderer: SwitchingVideoRenderer?
  private var pictureInPicture: UmbelPictureInPicture?
  private var displayDriver: UmbelDisplayDriver?
  private nonisolated(unsafe) var referenceLink: CADisplayLink?
  private var referenceRendering = false
  private var referenceTicks = 0
  private var referenceRenders = 0
  private var referenceErrors = 0
  private var referencePreviousTick: CFTimeInterval?
  private var referenceMaximumTickInterval: CFTimeInterval = 0
  private var referenceMaximumRenderDuration: CFTimeInterval = 0
  private nonisolated(unsafe) var stallTimer: Timer?
  private var commandInput: Task<Void, Never>?
  private var diagnosticExport: Task<Void, Never>?
  private var isPlaying = true

  init(options: LaunchOptions) {
    self.options = options
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { fatalError("not from a storyboard") }

  deinit {
    commandInput?.cancel()
    diagnosticExport?.cancel()
    stallTimer?.invalidate()
    referenceLink?.invalidate()
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    if options.mainThreadDisplay { startReferenceDisplayLoop() }
    else {
      displayDriver?.setDrawableAvailable(metalView.window != nil)
      displayDriver?.start()
    }
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    if pictureInPicture?.isActive != true {
      displayDriver?.stop()
      referenceLink?.invalidate()
      referenceLink = nil
    }
    stallTimer?.invalidate()
    stallTimer = nil
  }

  @objc private func wentToBackground() {
    referenceLink?.isPaused = true
    referencePreviousTick = nil
    guard pictureInPicture?.isActive != true, let session else { return }
    guard !options.backgroundDecoding else { return print("status: in the background, picture still decoded") }
    print("status: in the background, picture not decoded")
    Task { await session.setVideoSuspended(true) }
  }

  @objc private func audioInterrupted(_ notification: Notification) {
    guard let session, let info = notification.userInfo,
          let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
          let kind = AVAudioSession.InterruptionType(rawValue: raw) else { return }
    if kind == .began {
      print("status: audio interrupted, paused")
      Task { await session.pause() }
      return
    }
    let options = AVAudioSession.InterruptionOptions(
      rawValue: info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
    print("status: interruption over, \(options.contains(.shouldResume) && isPlaying ? "resuming" : "staying paused")")
    guard options.contains(.shouldResume), isPlaying else { return }
    Task {
      try? AVAudioSession.sharedInstance().setActive(true)
      try? await session.play()
    }
  }

  @objc private func audioRouteChanged(_ notification: Notification) {
    guard let session, let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
          let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
    let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
      .map { "\($0.portType.rawValue) \($0.channels?.count ?? 0)ch" }.joined(separator: ", ")
    print("status: audio route \(reason.rawValue) now \(outputs)")
    guard reason == .oldDeviceUnavailable else { return }
    isPlaying = false
    Task { await session.pause() }
  }

  @objc private func cameBack() {
    referenceLink?.isPaused = false
    guard let session else { return }
    print("status: back, picture decoded again")
    Task { await session.setVideoSuspended(false) }
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .black
    // In the background with no picture in picture, nothing shows the
    // picture: its decoding stops, sound plays on, and it comes back with
    // the app.
    let center = NotificationCenter.default
    center.addObserver(self, selector: #selector(wentToBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
    center.addObserver(self, selector: #selector(cameBack), name: UIApplication.willEnterForegroundNotification, object: nil)
    // The audio session is the host's to coordinate: a call or another
    // app's sound pauses, and resumes when the system says it may; the
    // headphones taken out pause, as sound must not move to the speaker.
    center.addObserver(self, selector: #selector(audioInterrupted(_:)), name: AVAudioSession.interruptionNotification, object: nil)
    center.addObserver(self, selector: #selector(audioRouteChanged(_:)), name: AVAudioSession.routeChangeNotification, object: nil)
    for picture in [sampleView, metalView] {
      picture.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview(picture)
    }
    status.textColor = .white
    status.font = .monospacedDigitSystemFont(ofSize: 14, weight: .regular)
    status.numberOfLines = 2
    let buttons = UIStackView(arrangedSubviews: [
      button("⏯") { $0.togglePlay() },
      button("−10") { $0.skip(-10) },
      button("+10") { $0.skip(10) },
      button("0.5×") { $0.setRate(0.5) },
      button("1×") { $0.setRate(1) },
      button("2×") { $0.setRate(2) },
      button("PiP") { $0.togglePictureInPicture() },
    ])
    buttons.distribution = .fillEqually
    for other in [status, buttons] as [UIView] {
      other.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview(other)
    }
    let guide = view.safeAreaLayoutGuide
    NSLayoutConstraint.activate([
      metalView.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
      metalView.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
      metalView.topAnchor.constraint(equalTo: guide.topAnchor),
      metalView.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -8),
      sampleView.leadingAnchor.constraint(equalTo: metalView.leadingAnchor),
      sampleView.trailingAnchor.constraint(equalTo: metalView.trailingAnchor),
      sampleView.topAnchor.constraint(equalTo: metalView.topAnchor),
      sampleView.bottomAnchor.constraint(equalTo: metalView.bottomAnchor),
      status.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 12),
      status.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -12),
      status.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -8),
      buttons.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
      buttons.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
      buttons.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
      buttons.heightAnchor.constraint(equalToConstant: 48),
    ])
    Task { await start() }
  }

  private func button(_ title: String, _ action: @escaping (PlayerViewController) -> Void) -> UIButton {
    let button = UIButton(type: .system)
    button.setTitle(title, for: .normal)
    button.titleLabel?.font = .systemFont(ofSize: 18, weight: .semibold)
    button.addAction(UIAction { [weak self] _ in if let self { action(self) } }, for: .touchUpInside)
    return button
  }

  private func start() async {
    guard let device = MTLCreateSystemDefaultDevice() else { return show("no Metal device") }
    let tolerance = CMTime(seconds: 0.02, preferredTimescale: 600)
    do {
      let diagnostics = options.timestampDiagnostics ? UmbelPlaybackDiagnostics() : nil
      if let diagnostics { diagnosticExport = Self.exportDiagnostics(diagnostics) }
      // Through handles: the renderers draw into the layers from their own
      // executors, the main thread only lays the views out.
      let metal = LayerHandle(layer: metalView.metalLayer)
      let sample = LayerHandle(layer: sampleView.displayLayer)
      let main = try MetalVideoRenderer(layer: metal.layer, device: device, tolerance: tolerance)
      let second = try SampleBufferVideoRenderer(layer: sample.layer, device: device, tolerance: tolerance)
      let renderer = SwitchingVideoRenderer(main: main, pictureInPicture: second)
      let source: UmbelSource = options.url.isFileURL
        ? try UmbelFileSource(url: options.url)
        : UmbelBufferedSource(wrapping: UmbelHTTPSource(url: options.url))
      let output: any AudioOutput = options.engineAudio ? EngineAudioOutput() : SampleBufferAudioOutput()
      let session = PlaybackSession(
        source: source, audioOutput: output, videoRenderer: renderer,
        buffering: options.bufferTarget.map { BufferingConfiguration(target: $0) } ?? BufferingConfiguration(),
        objectAudio: options.objectAudio, diagnostics: diagnostics)
      self.session = session
      self.renderer = renderer
      if options.muted { await session.setMuted(true) }
      try await session.load()
      if let subtitleURL = options.subtitleURL {
        let track = try await session.addExternalSubtitle(
          try UmbelFileSource(url: subtitleURL), title: subtitleURL.lastPathComponent)
        try await session.selectSubtitleTrack(track.id)
      }
      for track in await session.tracks {
        print("track: [\(track.id.rawValue)] \(track.kind.rawValue) \(track.codecName)"
              + (track.video?.dynamicHDR.map { " \($0.label)" } ?? "")
              + (track.isDecodable ? "" : " not decodable"))
      }
      print("system DV display: \(SampleBufferVideoRenderer.systemCanShowDV ? "available" : "unavailable")")
      print("audio output: \(options.engineAudio ? "engine" : "sample buffer")")
      print("audio route: \(PlayerCommands.label(await session.audioRoute))")
      // The copies actually loaded: another FFmpeg or libass in an app would show here.
      print("libraries: FFmpeg \(Umbel.ffmpegVersion ?? "unknown") (\(Umbel.ffmpegLicense ?? "no license")), libass \(Umbel.libassVersion)")
      if let seek = options.seek { try await session.seek(to: CMTime(seconds: seek, preferredTimescale: 600)) }
      if let rate = options.rate { await session.setRate(rate) }
      try await session.play()
      pictureInPicture = UmbelPictureInPicture(layer: sampleView.displayLayer, session: session, renderer: renderer)
      if options.sampleLayerInPlace {
        metalView.isHidden = true
        await renderer.show(.pictureInPicture)
      }
      if options.mainThreadDisplay { startReferenceDisplayLoop() }
      else {
        let driver = UmbelDisplayDriver(session: session)
        displayDriver = driver
        // Picture in picture goes on moving in the background.
        pictureInPicture?.displayDriver = driver
        driver.setDrawableAvailable(metalView.window != nil)
        driver.start()
      }
      if let duration = options.mainThreadStall {
        stallTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
          print(String(format: "status: main thread stall %.3f s", duration))
          Thread.sleep(forTimeInterval: duration)
        }
      }
      startStatus()
      if let commandsURL = options.commandsURL {
        commandInput = PlayerCommands.start(
          session: session, file: commandsURL,
          pictureInPicture: { [weak self] in self?.togglePictureInPicture() },
          playing: { [weak self] in self?.isPlaying = $0 })
      }
      if let after = options.pictureInPictureAfter {
        try? await Task.sleep(nanoseconds: UInt64(after * 1_000_000_000))
        togglePictureInPicture()
        if let open = options.pictureInPictureFor {
          try? await Task.sleep(nanoseconds: UInt64(open * 1_000_000_000))
          togglePictureInPicture()
        }
      }
    } catch {
      show("failed: \(error)")
    }
  }

  private func startStatus() {
    Task {
      var lastRoute: UmbelAudioRoute?
      while let session {
        // How the sound plays can change by itself: the system player given back.
        let route = await session.audioRoute
        if route != lastRoute, lastRoute != nil { print("status: audio route now \(PlayerCommands.label(route))") }
        lastRoute = route
        let now = await session.currentTime.seconds
        let duration = await session.duration
        let phase = await session.phase
        let rate = await session.rate
        let active = pictureInPicture?.isActive == true ? "  picture in picture" : ""
        let total = duration.isNumeric ? String(format: " / %.0f s", duration.seconds) : " / live"
        let reason = phase == .failed ? await session.failureReason.map { "  \($0.localizedDescription)" } ?? "" : ""
        status.text = String(format: "%.1f s", now) + total + "  \(phase.rawValue)  \(rate)×" + active + reason
          + (options.mainThreadDisplay ? "  main display" : "  independent display")
        let display = displayDriver?.statistics
        let decoding = await session.decodingStatistics
        print("status: \(status.text ?? "")" + String(format: " | memory %.0f MB | thermal %d | reported dropped %d | display ticks %d busy %d renders %d empty %d errors %d last error %@",
              Self.footprintMB(), ProcessInfo.processInfo.thermalState.rawValue,
              display?.reportedDroppedFrameCount ?? 0, display?.tickCount ?? 0,
              display?.busyTickCount ?? 0, display?.presentedFrameCount ?? 0,
              display?.emptyRenderCount ?? 0, display?.errorCount ?? 0,
              display?.lastError ?? "none")
          + String(format: " | main reference ticks %d renders %d errors %d",
                   referenceTicks, referenceRenders, referenceErrors)
          + String(format: " | maximum tick ms %.2f render ms %.2f",
                   1_000 * (display?.maximumTickInterval ?? referenceMaximumTickInterval),
                   1_000 * (display?.maximumRenderDuration ?? referenceMaximumRenderDuration))
          + Self.describe(decoding))
        try? await Task.sleep(nanoseconds: 1_000_000_000)
      }
    }
  }

  private static func describe(_ statistics: UmbelDecodingStatistics) -> String {
    func counts(_ name: String, _ counts: UmbelDecodingCounts?) -> String {
      guard let counts else { return " | \(name) decoded by the system" }
      return " | \(name) decoded \(counts.decodedFrames) rejected \(counts.rejectedPackets) damaged \(counts.damagedFrames)"
    }
    return counts("video", statistics.video) + counts("audio", statistics.audio)
  }

  private static func exportDiagnostics(_ diagnostics: UmbelPlaybackDiagnostics) -> Task<Void, Never> {
    Task.detached(priority: .utility) {
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      encoder.outputFormatting = .sortedKeys
      var sequence: UInt64 = 0
      func export() {
        let snapshot = diagnostics.snapshot(after: sequence)
        if let first = snapshot.events.first, first.sequence > sequence + 1 {
          print("[playback-diagnostic] lost \(first.sequence - sequence - 1) events")
        }
        for event in snapshot.events {
          do {
            let data = try encoder.encode(event)
            print("[playback-diagnostic] \(String(decoding: data, as: UTF8.self))")
          } catch { print("[playback-diagnostic] export failed: \(error)") }
        }
        sequence = snapshot.latestSequence
      }
      while !Task.isCancelled {
        export()
        try? await Task.sleep(nanoseconds: 500_000_000)
      }
      export()
    }
  }

  private func startReferenceDisplayLoop() {
    guard referenceLink == nil, session != nil else { return }
    referencePreviousTick = nil
    let link = CADisplayLink(target: self, selector: #selector(referenceTick))
    link.add(to: .main, forMode: .common)
    referenceLink = link
  }

  @objc private func referenceTick() {
    let now = CACurrentMediaTime()
    if let previous = referencePreviousTick {
      referenceMaximumTickInterval = max(referenceMaximumTickInterval, now - previous)
    }
    referencePreviousTick = now
    referenceTicks += 1
    guard !referenceRendering, let session else { return }
    referenceRendering = true
    Task { @MainActor [weak self] in
      let started = CACurrentMediaTime()
      defer {
        self?.referenceRendering = false
        if let self {
          referenceMaximumRenderDuration = max(referenceMaximumRenderDuration, CACurrentMediaTime() - started)
        }
      }
      do {
        if try await session.renderVideoFrame() != nil { self?.referenceRenders += 1 }
      } catch {
        self?.referenceErrors += 1
        print("display render failed: \(error)")
      }
    }
  }

  /// The process's physical footprint, as the system counts it against its limit.
  private static func footprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
  }

  private func show(_ text: String) {
    status.text = text
    print("status: \(text)")
  }

  // ── Buttons ─────────────────────────────────────────

  private func togglePlay() {
    guard let session else { return }
    isPlaying.toggle()
    let playing = isPlaying
    Task { if playing { try? await session.play() } else { await session.pause() } }
  }

  private func skip(_ seconds: Double) {
    guard let session else { return }
    Task {
      let now = await session.currentTime
      try? await session.seek(to: CMTimeAdd(now, CMTime(seconds: seconds, preferredTimescale: 600)))
    }
  }

  private func setRate(_ rate: Double) {
    guard let session else { return }
    Task { await session.setRate(rate) }
  }

  private func togglePictureInPicture() {
    guard let pictureInPicture else { return show("picture in picture: not available") }
    if pictureInPicture.isActive { pictureInPicture.stop() } else { pictureInPicture.start() }
    print("status: picture in picture \(pictureInPicture.isActive ? "off" : "on") asked")
  }
}

/// A layer handed to a renderer. The compiler cannot prove sharing it safe;
/// the discipline is that the renderer draws, the main thread lays out.
struct LayerHandle<Layer: CALayer>: @unchecked Sendable {
  let layer: Layer
}

/// A view backed by a Metal layer whose drawable follows its size in pixels.
final class MetalLayerView: UIView {
  override class var layerClass: AnyClass { CAMetalLayer.self }
  var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

  override func layoutSubviews() {
    super.layoutSubviews()
    let scale = window?.screen.scale ?? UIScreen.main.scale
    metalLayer.contentsScale = scale
    metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
  }
}

/// A view backed by the sample buffer display layer picture in picture
/// takes its content from.
final class SampleBufferView: UIView {
  override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
  var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
}
