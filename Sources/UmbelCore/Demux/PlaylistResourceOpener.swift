import Foundation
import UmbelFFmpegSupport

/// What FFmpeg's own playlist reading opens the addresses it finds with: the
/// playlist, its segments and keys, each through the source's opener, never
/// FFmpeg's network code.
internal enum PlaylistResourceOpener {
  static func make(_ open: @escaping HLSPlaylistLoader.Opener) -> FFmpegResourceOpener {
    { resource in
      guard let url = URL(string: resource.address) else {
        throw UmbelError.sourceUnavailable(detail: "not an address: \(resource.address)")
      }
      // Closed, a transfer read only in part lets its connection go.
      let source = await open(url)
      if let aes = resource.aes128 {
        let reader = try HLSDecryptingReader(source: source, key: aes.key, iv: aes.iv)
        return FFmpegIOCallbacks(
          read: { try await reader.read(maxLength: $0) },
          seek: { _ in throw UmbelError.seekUnsupported },
          totalLength: { nil },
          canSeek: false, close: { await source.invalidate() })
      }
      let cursor = RandomAccessCursor(source: source, window: resource.byteRange)
      // A web range is a response window, offsets counting from its first
      // byte. Advertising file seeking turns on FFmpeg's consecutive range
      // reuse, which can end fragmented MP4 at its first segment: a ranged
      // resource is opened per range instead. Local files keep file seeking.
      return FFmpegIOCallbacks(
        read: { try await cursor.read(maxLength: $0) },
        seek: { try await cursor.seek(toOffset: $0) },
        totalLength: { await cursor.totalLength },
        canSeek: resource.byteRange == nil, close: { await source.invalidate() })
    }
  }
}
