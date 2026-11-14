import Foundation
import UmbelFFmpegSupport

/// The thread that reads a network stream and hands its bytes to a queue.
///
/// The reads block, so they have a thread of their own: neither the
/// cooperative pool nor an actor may be blocked on a socket. The thread owns
/// the reader from opening to closing; from outside there are only
/// `stop()` and the queue.
final class NetworkStreamPump: @unchecked Sendable {
  let queue: LiveByteQueue
  private let reader: any FFmpegByteReading
  private let lock = NSLock()
  private var started = false

  private static let readSize = 64 << 10

  init(reader: any FFmpegByteReading, queue: LiveByteQueue) {
    self.reader = reader
    self.queue = queue
  }

  /// Opens and reads on a new thread; the first call only.
  func startIfNeeded() {
    lock.lock()
    let first = !started
    started = true
    lock.unlock()
    guard first else { return }
    let thread = Thread { [self] in run() }
    thread.name = "umbel.network"
    thread.stackSize = 512 * 1024
    thread.start()
  }

  /// Ends the stream from outside, from any thread: what is blocked is
  /// interrupted, reads fail as interrupted, and the connection is let go as
  /// the thread returns.
  func stop() {
    reader.requestInterrupt()
    queue.close()
  }

  private func run() {
    do {
      try reader.open()
    } catch {
      queue.finish(.failure(Self.umbelError(for: error)))
      reader.close()
      return
    }
    while true {
      queue.waitForRoom()
      do {
        let data = try reader.read(maxLength: Self.readSize)
        if data.isEmpty {
          queue.finish(.end)
          break
        }
        queue.append(data)
      } catch {
        queue.finish(.failure(Self.umbelError(for: error)))
        break
      }
    }
    reader.close()
  }

  /// Said without the address, which carries tokens, and without FFmpeg's
  /// own wording, which follows no language setting.
  static func umbelError(for error: Error) -> UmbelError {
    // A module's reader throws what the host is to read: not worded again.
    if let told = error as? UmbelError { return told }
    guard let failure = error as? FFmpegStreamFailure else {
      return .sourceUnavailable(detail: UmbelError.detail(for: error))
    }
    switch failure {
    case .interrupted:
      return .interrupted
    case .timedOut(.connecting):
      return .sourceUnavailable(detail: "connection timed out")
    case .timedOut(.receiving):
      return .sourceUnavailable(detail: "no data received")
    case .failed(.io(let code)):
      return .sourceUnavailable(detail: "network error \(code)")
    case .failed(.invalidData):
      return .sourceUnavailable(detail: "network error \(FFmpegErrorCode.invalidDataRaw)")
    case .failed(.endOfFile):
      // A reader told to count the end as a failure: see
      // `FFmpegPacketRepackager.Configuration.endIsFailure`.
      return .sourceUnavailable(detail: "stream ended")
    case .failed(.interrupted):
      return .interrupted
    }
  }
}
