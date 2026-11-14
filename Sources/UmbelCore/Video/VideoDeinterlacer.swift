import CoreMedia
import CoreVideo
import Foundation
import Metal

/// Makes interlaced frames progressive as they leave the decoder: each
/// becomes two pictures, its first field's at the frame's time and its
/// second's half a frame later. Progressive frames, and everything while
/// switched off, pass as they are.
///
/// How long a frame is comes from what the stream states of it; with nothing
/// stated, from how its frames are spaced, once that is steady.
///
/// Keeps the last interlaced frame, to tell still from moving; a seek or a
/// new decoder forgets it (`reset()`). A failure — no GPU, a pass that did
/// not complete — lets the frame through woven and is noted; it never stops
/// playback. Owned by one decoding engine and called only as the engine is:
/// by its actor, or on its queue.
internal final class VideoDeinterlacer: @unchecked Sendable {
  private enum KernelState {
    case untried
    case ready(DeinterlaceKernel)
    case unavailable
  }

  private let setting: DeinterlaceSwitch
  private let nominalFrameRate: Double?
  private let diagnostics: UmbelPlaybackDiagnostics?
  private let makeKernel: () throws -> DeinterlaceKernel
  private let hostSeconds: () -> Double
  private var kernel = KernelState.untried
  private var previous: CVPixelBuffer?
  private var estimator = FramePeriodEstimator()
  private var lastFailureNoted = -Double.infinity
  private var failuresWithheld = 0

  init(
    setting: DeinterlaceSwitch, nominalFrameRate: Double?, diagnostics: UmbelPlaybackDiagnostics? = nil,
    makeKernel: @escaping () throws -> DeinterlaceKernel = VideoDeinterlacer.systemKernel,
    hostSeconds: @escaping () -> Double = { CMClockGetTime(CMClockGetHostTimeClock()).seconds }
  ) {
    self.setting = setting
    self.nominalFrameRate = nominalFrameRate
    self.diagnostics = diagnostics
    self.makeKernel = makeKernel
    self.hostSeconds = hostSeconds
  }

  /// The system's GPU; made the first time an interlaced frame comes.
  static func systemKernel() throws -> DeinterlaceKernel {
    guard let device = MTLCreateSystemDefaultDevice() else {
      throw UmbelError.videoRenderUnavailable(reason: "no graphics device for deinterlacing")
    }
    return try DeinterlaceKernel(device: device)
  }

  /// Whether a frame is held to judge motion by.
  var hasPreviousFrame: Bool { previous != nil }

  func process(_ frames: [VideoFrame]) -> [VideoFrame] { frames.flatMap(process) }

  /// Forgets the frame before: after a seek or with a new decoder it no
  /// longer comes before anything. How fast the frames come is the stream's,
  /// and stays.
  func reset() {
    previous = nil
    estimator.forgetPosition()
  }

  private func process(_ frame: VideoFrame) -> [VideoFrame] {
    guard setting.mode == .automatic else {
      previous = nil
      return [frame]
    }
    // Every frame is watched, interlaced or not: the spacing is that of all.
    estimator.observe(frame.presentationTime)
    guard let order = frame.fieldOrder, let current = frame.pixelBuffer, let kernel = readyKernel() else {
      return [frame]
    }
    let first: VideoField = order == .topFirst ? .top : .bottom
    let second: VideoField = first == .top ? .bottom : .top
    // What the stream states first; failing that, how its frames are spaced.
    let step = FieldTiming.step(
      duration: frame.duration, declaredFrameRate: frame.declaredFrameRate, nominalFrameRate: nominalFrameRate)
      ?? estimator.period.map { CMTimeMultiplyByRatio($0, multiplier: 1, divisor: 2) }
    defer { previous = current }
    do {
      let earlier = try kernel.picture(from: current, previous: previous, keeping: first, isFirst: true)
      var pictures = [frame.progressive(earlier, at: frame.presentationTime, lasting: step)]
      if let step, frame.presentationTime.isNumeric {
        let later = try kernel.picture(from: current, previous: previous, keeping: second, isFirst: false)
        pictures.append(frame.progressive(later, at: frame.presentationTime + step, lasting: step))
      }
      return pictures
    } catch {
      noteFailure(error)
      return [frame]
    }
  }

  /// A failure that repeats with every frame is noted once a second, with
  /// how many were left out since the last note.
  private func noteFailure(_ error: Error) {
    guard let diagnostics else { return }
    let now = hostSeconds()
    guard now - lastFailureNoted >= 1 else {
      failuresWithheld += 1
      return
    }
    lastFailureNoted = now
    diagnostics.record(
      "video_deinterlace_failed", values: ["withheld": Double(failuresWithheld)], labels: ["reason": "\(error)"])
    failuresWithheld = 0
  }

  private func readyKernel() -> DeinterlaceKernel? {
    switch kernel {
    case .ready(let made):
      return made
    case .unavailable:
      return nil
    case .untried:
      do {
        let made = try makeKernel()
        kernel = .ready(made)
        return made
      } catch {
        kernel = .unavailable
        noteFailure(error)
        return nil
      }
    }
  }
}

extension VideoFrame {
  /// This frame's picture made progressive: other pixels, another time, no
  /// field order; the rest as it was.
  fileprivate func progressive(_ buffer: CVPixelBuffer, at time: CMTime, lasting step: CMTime?) -> VideoFrame {
    var picture = VideoFrame(
      presentationTime: time, pixelBuffer: buffer, width: width, height: height, color: color,
      pixelAspectRatio: pixelAspectRatio, rotation: rotation)
    picture.duration = step ?? .invalid
    picture.sourcePixelDescription = sourcePixelDescription
    picture.hasDynamicMetadata = false
    picture.dynamicMetadataInvalidated = hasDynamicMetadata || dynamicMetadataInvalidated
    picture.chromaLocationCode = chromaLocationCode
    picture.conversionReason = conversionReason
    return picture
  }
}
