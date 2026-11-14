import Foundation

extension PlaybackSession {
  /// Whether interlaced video is made progressive; `.automatic` until set.
  public var deinterlacing: UmbelDeinterlacing { deinterlace.mode }

  /// From the next frame decoded on; pictures already waiting to be shown
  /// stay as they are.
  public func setDeinterlacing(_ mode: UmbelDeinterlacing) async {
    deinterlace.mode = mode
  }
}
