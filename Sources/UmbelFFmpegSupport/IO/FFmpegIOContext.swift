import FFmpeg
import Foundation

public enum FFmpegIOError: Error, Sendable {
  /// The buffer beneath could not be allocated.
  case bufferAllocationFailed(size: Int)
  /// The I/O context beneath could not be made.
  case contextAllocationFailed
}

/// The three things custom I/O needs, as closures.
///
/// No protocol referred to, on purpose: this module does not know
/// UmbelSource exists, and should not — the dependency runs one way, and
/// the other way would make a cycle.
public struct FFmpegIOCallbacks: Sendable {
  /// Reads up to n bytes in order. Empty means the end.
  public let read: @Sendable (Int) async throws -> Data
  /// Seeks to an absolute offset; throws where that is not supported.
  public let seek: @Sendable (Int64) async throws -> Void
  /// The total length; nil if unknown.
  public let totalLength: @Sendable () async -> Int64?
  public let canSeek: Bool
  /// Called once nothing more will be read — for what a demuxer reading by
  /// address opened, when FFmpeg closes it or the demuxer closes — so the
  /// caller can let a connection go. Not awaited.
  public let close: (@Sendable () async -> Void)?

  public init(
    read: @escaping @Sendable (Int) async throws -> Data,
    seek: @escaping @Sendable (Int64) async throws -> Void,
    totalLength: @escaping @Sendable () async -> Int64?,
    canSeek: Bool,
    close: (@Sendable () async -> Void)? = nil
  ) {
    self.read = read
    self.seek = seek
    self.totalLength = totalLength
    self.canSeek = canSeek
    self.close = close
  }
}

/// Holds the callbacks, the buffer and the I/O context beneath.
///
/// The caller manages its lifetime explicitly (`release()`), not deinit: the
/// context beneath may be freed only after the format context is closed,
/// an order not to be left to reference counting.
public final class FFmpegIOContext {
  fileprivate final class Box {
    let callbacks: FFmpegIOCallbacks
    /// The interrupt query. **Interruption has to happen here**, not through
    /// the interrupt callback beneath: custom I/O's read path never consults
    /// that callback, and even when it fires while probing, the stream
    /// analysis overwrites its error. A callback we control is the one
    /// reliable place to stop.
    let isInterrupted: @Sendable () -> Bool
    /// Where a read blocked in the source can be given up; see `ReadAbandonment`.
    let abandonment: ReadAbandonment?
    var position: Int64 = 0
    var failure: Error?
    /// A failure set aside by `beginRead()`, not yet told. See `takePendingFailure()`.
    var setAside: Error?
    /// Called when a read finds the end — not when one fails.
    var onEnd: (() -> Void)?

    init(
      callbacks: FFmpegIOCallbacks, isInterrupted: @escaping @Sendable () -> Bool,
      abandonment: ReadAbandonment?
    ) {
      self.callbacks = callbacks
      self.isInterrupted = isInterrupted
      self.abandonment = abandonment
    }
  }

  private let box: Box
  private var context: UnsafeMutablePointer<AVIOContext>?

  /// Returns the source's own error and forgets it. FFmpeg only ever sees an
  /// error code; the original error is recovered from here.
  ///
  /// Forgetting matters: a failure left behind would be reported again by the
  /// next unrelated error — a later stop would read as the old network error.
  /// A failure set aside by `beginRead()` is told when no newer one is, unless
  /// the stop is ours: FFmpeg reads ahead of the packet it returns, so the
  /// failure is often hit in a call that still succeeds, and the call that
  /// cannot be served then has only the bare code of an interruption.
  public func takePendingFailure() -> Error? {
    defer { box.failure = nil; box.setAside = nil }
    if let failure = box.failure { return failure }
    return box.isInterrupted() ? nil : box.setAside
  }

  /// A fresh read begins: a failure not yet told is set aside, so that the
  /// source is asked again — it may have recovered — but not lost should
  /// FFmpeg be unable to go on without asking.
  public func beginRead() {
    if let failure = box.failure { box.setAside = failure }
    box.failure = nil
  }

  public var rawPointer: UnsafeMutablePointer<AVIOContext>? { context }

  /// What to do when a read finds the end of the source. Runs on the thread
  /// that is reading, in the middle of the read.
  var onEnd: (() -> Void)? {
    get { box.onEnd }
    set { box.onEnd = newValue }
  }

  public init(
    callbacks: FFmpegIOCallbacks,
    bufferSize: Int,
    isInterrupted: @escaping @Sendable () -> Bool = { false },
    abandonment: ReadAbandonment? = nil
  ) throws {
    self.box = Box(callbacks: callbacks, isInterrupted: isInterrupted, abandonment: abandonment)

    guard let buffer = av_malloc(bufferSize) else {
      throw FFmpegIOError.bufferAllocationFailed(size: bufferSize)
    }

    guard let context = avio_alloc_context(
      buffer.assumingMemoryBound(to: UInt8.self),
      Int32(bufferSize),
      0,
      Unmanaged.passUnretained(box).toOpaque(),
      umbelIORead,
      nil,
      umbelIOSeek
    ) else {
      av_free(buffer)
      throw FFmpegIOError.contextAllocationFailed
    }

    // 0 means it cannot seek (the header: "or 0 when the stream is not
    // seekable").
    context.pointee.seekable = callbacks.canSeek ? Int32(AVIO_SEEKABLE_NORMAL) : 0
    self.context = context
  }

  /// Frees the context beneath. Only after the format context is closed.
  /// Can be called again.
  public func release() {
    guard self.context != nil else { return }
    // Has to stay optional: avio_context_free takes a pointer to an optional
    // pointer.
    var context: UnsafeMutablePointer<AVIOContext>? = self.context
    self.context = nil
    if let buffer = context?.pointee.buffer {
      av_free(buffer)
    }
    avio_context_free(&context)
  }
}

// ── C callbacks ────────────────────────────────────────
// Top-level functions, as they have to be: @convention(c) captures nothing,
// and state travels through the opaque pointer.

private func umbelIORead(
  _ opaque: UnsafeMutableRawPointer?,
  _ buffer: UnsafeMutablePointer<UInt8>?,
  _ size: Int32
) -> Int32 {
  guard let opaque, let buffer, size > 0 else { return FFmpegErrorCode.invalidDataRaw }
  let box = Unmanaged<FFmpegIOContext.Box>.fromOpaque(opaque).takeUnretainedValue()
  if box.isInterrupted() { return FFmpegErrorCode.exitRaw }
  // A source that has failed is not asked again until the failure is told.
  // After a read fails FFmpeg asks whether the end of the input was reached
  // (`avio_feof`), which it finds out by clearing the end and reading once
  // more — and a demuxer that does so before it tries a sample again asks
  // the source a second time. Useless of a source that has failed for good,
  // and a second wait for one that waited before it gave up.
  if box.failure != nil { return FFmpegErrorCode.exitRaw }
  // Only the @Sendable closure goes into the blocking call, not the whole
  // Box: the Box holds mutable state touched on this thread only, and
  // capturing it would need @unchecked Sendable — switching the compiler's
  // check off where it is not needed at all.
  let read = box.callbacks.read
  do {
    let data = try blockingCall(abandonment: box.abandonment) { try await read(Int(size)) }
    if data.isEmpty {
      box.onEnd?()
      return FFmpegErrorCode.endOfFileRaw
    }
    data.withUnsafeBytes { raw in
      guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
      buffer.update(from: base, count: data.count)
    }
    box.position += Int64(data.count)
    return Int32(data.count)
  } catch {
    box.failure = error
    return FFmpegErrorCode.exitRaw
  }
}

private func umbelIOSeek(
  _ opaque: UnsafeMutableRawPointer?,
  _ offset: Int64,
  _ whence: Int32
) -> Int64 {
  guard let opaque else { return Int64(FFmpegErrorCode.invalidDataRaw) }
  let box = Unmanaged<FFmpegIOContext.Box>.fromOpaque(opaque).takeUnretainedValue()
  if box.isInterrupted() { return Int64(FFmpegErrorCode.exitRaw) }

  let totalLength = box.callbacks.totalLength

  // AVSEEK_SIZE: asks the total length, without moving.
  if whence & AVSEEK_SIZE != 0 {
    let length = blockingValue(default: nil) { await totalLength() }
    return length ?? Int64(FFmpegErrorCode.invalidDataRaw)
  }

  guard box.callbacks.canSeek else { return Int64(FFmpegErrorCode.invalidDataRaw) }

  let target: Int64
  switch whence & ~AVSEEK_FORCE {
  case Int32(SEEK_SET):
    target = offset
  case Int32(SEEK_CUR):
    target = box.position + offset
  case Int32(SEEK_END):
    guard let length = blockingValue(default: nil, { await totalLength() }) else {
      return Int64(FFmpegErrorCode.invalidDataRaw)
    }
    target = length + offset
  default:
    return Int64(FFmpegErrorCode.invalidDataRaw)
  }

  guard target >= 0 else { return Int64(FFmpegErrorCode.invalidDataRaw) }
  let seek = box.callbacks.seek
  do {
    try blockingCall { try await seek(target) }
    box.position = target
    return target
  } catch {
    box.failure = error
    return Int64(FFmpegErrorCode.exitRaw)
  }
}
