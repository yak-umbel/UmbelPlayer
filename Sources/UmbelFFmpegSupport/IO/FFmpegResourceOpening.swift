import FFmpeg
import Foundation

/// What a demuxer reading by address asks to open: a playlist, a segment,
/// a key.
public struct FFmpegResource: Sendable {
  /// AES-128 in CBC mode over the whole resource.
  public struct AES128: Sendable, Equatable {
    public let key: Data
    public let iv: Data
  }

  public let address: String
  /// Set for a segment FFmpeg's playlist reading found encrypted: the opener
  /// hands over what it holds decrypted. Asked for this way, FFmpeg would
  /// otherwise read the segment with its own decryption, past the opener.
  public let aes128: AES128?
  /// Set for a segment that is part of a file on the web: the opener hands
  /// over that part alone, its first byte at offset 0. FFmpeg's playlist
  /// reading leaves a web address's range to the web protocol and does not
  /// seek to it; for any other address it seeks there itself, and this is nil.
  public let byteRange: Range<Int64>?
}

/// Opens what a demuxer reading by address asks for through the caller's
/// own I/O.
public typealias FFmpegResourceOpener = @Sendable (FFmpegResource) async throws -> FFmpegIOCallbacks

/// Everything a demuxer reading by address opens goes through here, never
/// FFmpeg's own network code: the format context's open and close hooks
/// point at it. The caller's opener decides what may be opened and how —
/// with a site's headers, through its own cache, or not at all.
///
/// Holds every I/O context handed out until FFmpeg closes it, or the demuxer
/// closes.
final class FFmpegResourceTable {
  private let opener: FFmpegResourceOpener
  private let bufferSize: Int
  private let isInterrupted: @Sendable () -> Bool
  private let abandonment: ReadAbandonment?
  private var open: [UnsafeMutablePointer<AVIOContext>: (context: FFmpegIOContext, callbacks: FFmpegIOCallbacks)] = [:]
  /// The error an opener threw last; FFmpeg only sees a code.
  private var failure: Error?

  init(
    opener: @escaping FFmpegResourceOpener, bufferSize: Int, isInterrupted: @escaping @Sendable () -> Bool,
    abandonment: ReadAbandonment? = nil
  ) {
    self.opener = opener
    self.bufferSize = bufferSize
    self.isInterrupted = isInterrupted
    self.abandonment = abandonment
  }

  /// Points the context's open and close hooks here.
  func attach(to context: UnsafeMutablePointer<AVFormatContext>) {
    context.pointee.opaque = Unmanaged.passUnretained(self).toOpaque()
    context.pointee.io_open = umbelResourceOpen
    context.pointee.io_close2 = umbelResourceClose
  }

  fileprivate func open(_ resource: FFmpegResource) -> (UnsafeMutablePointer<AVIOContext>?, Int32) {
    if isInterrupted() { return (nil, FFmpegErrorCode.exitRaw) }
    let opener = self.opener
    do {
      let callbacks = try blockingCall { try await opener(resource) }
      let context = try FFmpegIOContext(
        callbacks: callbacks, bufferSize: bufferSize, isInterrupted: isInterrupted, abandonment: abandonment)
      guard let pointer = context.rawPointer else {
        Self.finish(callbacks)
        return (nil, FFmpegErrorCode.invalidDataRaw)
      }
      open[pointer] = (context, callbacks)
      return (pointer, 0)
    } catch {
      failure = error
      return (nil, FFmpegErrorCode.exitRaw)
    }
  }

  fileprivate func close(_ pointer: UnsafeMutablePointer<AVIOContext>) {
    guard let closed = open.removeValue(forKey: pointer) else { return }
    closed.context.release()
    Self.finish(closed.callbacks)
  }

  /// Tells the opener nothing more will be read, without waiting on it.
  private static func finish(_ callbacks: FFmpegIOCallbacks) {
    guard let close = callbacks.close else { return }
    Task { await close() }
  }

  /// The opener's error, or else one a read beneath hit; forgotten once taken.
  func takePendingFailure() -> Error? {
    if let failure {
      self.failure = nil
      return failure
    }
    for entry in open.values {
      if let failure = entry.context.takePendingFailure() { return failure }
    }
    return nil
  }

  /// Frees what FFmpeg did not close. Only after the format context is closed.
  func releaseAll() {
    for entry in open.values {
      entry.context.release()
      Self.finish(entry.callbacks)
    }
    open.removeAll()
  }
}

// ── C hooks ────────────────────────────────────────────

private func umbelResourceOpen(
  _ format: UnsafeMutablePointer<AVFormatContext>?,
  _ pb: UnsafeMutablePointer<UnsafeMutablePointer<AVIOContext>?>?,
  _ url: UnsafePointer<CChar>?,
  _ flags: Int32,
  _ options: UnsafeMutablePointer<OpaquePointer?>?
) -> Int32 {
  guard let format, let pb, let url, let opaque = format.pointee.opaque else {
    return FFmpegErrorCode.invalidDataRaw
  }
  // Read only: nothing a playlist names is written to.
  guard flags & AVIO_FLAG_WRITE == 0 else { return -EPERM }
  guard let resource = resource(String(cString: url), options: options?.pointee) else {
    return -EINVAL
  }
  let table = Unmanaged<FFmpegResourceTable>.fromOpaque(opaque).takeUnretainedValue()
  let (context, code) = table.open(resource)
  pb.pointee = context
  return code
}

/// FFmpeg's playlist reading asks for an encrypted segment as
/// `crypto+<address>` (or `crypto:<path>`), the key and IV in hex among the
/// options, for its own decryption to read it; nil when those are missing.
/// A part of a file comes with its range among the options, `offset` and
/// `end_offset`, for its web protocol to ask the server for.
private func resource(_ url: String, options: OpaquePointer?) -> FFmpegResource? {
  guard let prefix = ["crypto+", "crypto:"].first(where: url.hasPrefix) else {
    var range: Range<Int64>?
    let web = ["http:", "https:"].contains { url.lowercased().hasPrefix($0) }
    if web, let offset = integer("offset", in: options), let end = integer("end_offset", in: options),
       offset >= 0, end > offset {
      range = offset..<end
    }
    return FFmpegResource(address: url, aes128: nil, byteRange: range)
  }
  func bytes(_ name: String) -> Data? {
    guard let entry = av_dict_get(options, name, nil, 0), let value = entry.pointee.value else {
      return nil
    }
    let hex = Array(String(cString: value).utf8)
    guard hex.count == 32 else { return nil }
    var data = Data()
    for index in stride(from: 0, to: 32, by: 2) {
      guard let byte = UInt8(String(decoding: hex[index..<index + 2], as: UTF8.self), radix: 16) else {
        return nil
      }
      data.append(byte)
    }
    return data
  }
  guard let key = bytes("key"), let iv = bytes("iv") else { return nil }
  // A range here is not taken: FFmpeg seeks to it itself, since the crypto
  // protocol is not a web one, and decrypted data cannot seek.
  return FFmpegResource(
    address: String(url.dropFirst(prefix.count)), aes128: .init(key: key, iv: iv), byteRange: nil)
}

private func integer(_ name: String, in options: OpaquePointer?) -> Int64? {
  guard let entry = av_dict_get(options, name, nil, 0), let value = entry.pointee.value else {
    return nil
  }
  return Int64(String(cString: value))
}

private func umbelResourceClose(
  _ format: UnsafeMutablePointer<AVFormatContext>?,
  _ pb: UnsafeMutablePointer<AVIOContext>?
) -> Int32 {
  guard let format, let pb, let opaque = format.pointee.opaque else { return 0 }
  Unmanaged<FFmpegResourceTable>.fromOpaque(opaque).takeUnretainedValue().close(pb)
  return 0
}
