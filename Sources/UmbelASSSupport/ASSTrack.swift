import Foundation
import LibASS

/// One subtitle track as libass holds it: styles and events.
///
/// Not thread-safe; see `ASSLibrary`.
public final class ASSTrack: @unchecked Sendable {
  let pointer: UnsafeMutablePointer<ASS_Track>
  /// Kept alive for as long as the track: libass frees tracks through it.
  private let library: ASSLibrary

  /// An empty track, to be fed a header and then events one packet at a time.
  public init(library: ASSLibrary) {
    self.library = library
    pointer = ass_new_track(library.pointer)!
  }

  /// A whole script read at once — an external `.ass` file. libass parses
  /// everything, including fonts embedded in a `[Fonts]` section. Nil when the
  /// data is not a script it can read. Expects UTF-8.
  public init?(library: ASSLibrary, scriptData: Data) {
    // ass_read_memory takes a mutable buffer; hand it a copy.
    var bytes = [CChar](repeating: 0, count: scriptData.count)
    scriptData.withUnsafeBytes { source in
      bytes.withUnsafeMutableBytes { $0.copyMemory(from: source) }
    }
    guard let track = bytes.withUnsafeMutableBufferPointer({ buffer in
      ass_read_memory(library.pointer, buffer.baseAddress, buffer.count, nil)
    }) else { return nil }
    self.library = library
    pointer = track
  }

  deinit {
    ass_free_track(pointer)
  }

  /// The script header — styles and resolution — as a container stores it.
  public func processCodecPrivate(_ header: Data) {
    header.withUnsafeBytes { bytes in
      guard let base = bytes.baseAddress else { return }
      ass_process_codec_private(
        pointer, base.assumingMemoryBound(to: CChar.self), Int32(bytes.count))
    }
  }

  /// One event in the Matroska block format (`ReadOrder,Layer,Style,...`),
  /// which is what MKV stores. The same event twice is kept once: libass
  /// deduplicates by ReadOrder, so feeding a stretch again after a seek is
  /// harmless.
  public func processChunk(
    _ chunk: Data, startMilliseconds: Int64, durationMilliseconds: Int64
  ) {
    chunk.withUnsafeBytes { bytes in
      guard let base = bytes.baseAddress else { return }
      ass_process_chunk(
        pointer, base.assumingMemoryBound(to: CChar.self), Int32(bytes.count),
        startMilliseconds, durationMilliseconds)
    }
  }

  /// The script's resolution, which positions and sizes are written in.
  public var scriptResolution: (width: Int, height: Int) {
    (Int(pointer.pointee.PlayResX), Int(pointer.pointee.PlayResY))
  }
}
