import Foundation
import UmbelFFmpegSupport

/// A file on a server, read from anywhere by blocking calls: what a module that
/// brings a network library of its own writes, to be made a source by
/// `UmbelBlockingFileSource`.
///
/// Every call but `abandonCurrentCall()` and `requestInterrupt()` is made from
/// one thread, a thread of the source's own, one at a time. Failures are
/// thrown as `UmbelError` and reach the host as they are: no address, which
/// may hold a password, in any of them.
public protocol UmbelBlockingFileReader: AnyObject, Sendable {
  /// Connects and opens the file. Called again after `close()`, when the next
  /// read needs a connection once more.
  func open() throws
  /// The length of the file, as of `open()`; nil where the server does not say.
  func size() -> Int64?
  /// Up to `maxLength` bytes at `offset`; empty means the offset is at the end
  /// or past it. A read from where the last one ended goes on over the same
  /// transfer; one from elsewhere is the reader's to reposition for.
  func read(offset: Int64, maxLength: Int) throws -> Data
  /// Ends the call now blocked, by throwing `UmbelError.interrupted` from it,
  /// and no other call. What the connection was doing is then unknown: the
  /// source closes it, and opens it again for the next read. Called from any
  /// thread.
  func abandonCurrentCall()
  /// Ends the call now blocked, and every one after, by throwing
  /// `UmbelError.interrupted`. Called from any thread; the reader is not used
  /// again but to be closed.
  func requestInterrupt()
  /// Lets the connection go. Followed by `open()` again unless the reader was
  /// interrupted.
  func close()
}

/// A file from a reader that blocks, as a source that can be read from
/// anywhere, so that the session can seek in it.
///
/// A read that is cancelled gives up at once, and the connection, left in a
/// state nobody knows, is closed; the next read opens one again. One read at
/// a time: a read given up on closes the connection, which the read after it
/// must not begin on. Nothing is retried: a read that fails says so, and the
/// host decides.
public actor UmbelBlockingFileSource: UmbelRandomAccessSource {
  private let reader: any UmbelBlockingFileReader
  /// The reads block, so they run on a thread of their own, one at a time.
  private let thread = SerialWorkerThread(name: "umbel.file")
  private let gate = ReadGate()
  private var isOpen = false
  private var length: Int64?
  private var isInvalidated = false

  /// Nothing is opened until the first use.
  public init(reader: any UmbelBlockingFileReader) {
    self.reader = reader
  }

  /// Released without being invalidated: the connection still goes.
  deinit {
    reader.requestInterrupt()
    thread.shutdown()
  }

  public var contentLength: Int64? {
    get async {
      if let length { return length }
      guard !isInvalidated else { return nil }
      await gate.enter()
      defer { gate.leave() }
      do {
        try await ensureOpen()
        return length
      } catch {
        return nil
      }
    }
  }

  public func read(offset: Int64, maxLength: Int) async throws -> Data {
    guard !isInvalidated, !Task.isCancelled else { throw UmbelError.interrupted }
    guard offset >= 0, maxLength > 0 else { return Data() }
    await gate.enter()
    defer { gate.leave() }
    guard !isInvalidated, !Task.isCancelled else { throw UmbelError.interrupted }
    let reader = self.reader
    do {
      try await ensureOpen()
      return try await withTaskCancellationHandler {
        try await thread.run { try reader.read(offset: offset, maxLength: maxLength) }
      } onCancel: {
        reader.abandonCurrentCall()
      }
    } catch {
      await discardConnection()
      throw Self.umbelError(for: error)
    }
  }

  public func invalidate() async {
    isInvalidated = true
    let reader = self.reader
    reader.requestInterrupt()
    // The call blocked, if one is, returns at once; then the connection goes.
    _ = try? await thread.run { reader.close() }
    thread.shutdown()
  }

  private func ensureOpen() async throws {
    guard !isOpen else { return }
    let reader = self.reader
    do {
      // Connecting is a call that blocks, and a cancelled read must not wait it out.
      length = try await withTaskCancellationHandler {
        try await thread.run { try reader.open(); return reader.size() }
      } onCancel: {
        reader.abandonCurrentCall()
      }
    } catch {
      await discardConnection()
      throw Self.umbelError(for: error)
    }
    isOpen = true
  }

  /// Closes what may be in a state nobody knows; the next read opens again.
  private func discardConnection() async {
    isOpen = false
    let reader = self.reader
    _ = try? await thread.run { reader.close() }
  }

  /// An error already told as ours is not told again, or worded twice.
  private static func umbelError(for error: Error) -> UmbelError {
    if let told = error as? UmbelError { return told }
    if error is UmbelSerialWorkerError { return .interrupted }
    return .sourceUnavailable(detail: UmbelError.detail(for: error))
  }
}

/// One read at a time: a read given up on closes the connection, which the
/// read after it must not have begun on.
private final class ReadGate: @unchecked Sendable {
  private let lock = NSLock()
  private var isBusy = false
  private var waiting: [CheckedContinuation<Void, Never>] = []

  func enter() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      lock.lock()
      if isBusy {
        waiting.append(continuation)
        lock.unlock()
      } else {
        isBusy = true
        lock.unlock()
        continuation.resume()
      }
    }
  }

  func leave() {
    lock.lock()
    if waiting.isEmpty {
      isBusy = false
      lock.unlock()
    } else {
      let next = waiting.removeFirst()
      lock.unlock()
      next.resume()
    }
  }
}
