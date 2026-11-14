import CoreMedia
import Foundation

internal struct PresentationSettings: Sendable, Equatable {
  var videoAdjustments = UmbelVideoAdjustments()
  var aspectRatio: Double?
  var scaling = UmbelPictureScaling.fit
  var subtitleDelay: TimeInterval = 0
  var subtitleScale = 1.0
  var audioDelay: TimeInterval = 0

  static let subtitleScales: ClosedRange<Double> = 0.25...4
  static let audioDelays: ClosedRange<TimeInterval> = -10...10

  var audioDelayTime: CMTime {
    CMTime(seconds: audioDelay, preferredTimescale: 48_000)
  }
}
