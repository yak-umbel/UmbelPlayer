import Foundation

/// The session requests go out on, shared by a source and the sources opened
/// from it, and swapped for a fresh one after a request times out.
///
/// A timed-out request can leave its connection in the session's pool, open
/// but silent, and HTTP/2 puts the next request on that same connection: a
/// retry on the session times out the same way. A new session has a pool of
/// its own.
///
/// Fresh sessions come from the caller's maker; without one, from the given
/// session's configuration, but only when that session has no delegate — a
/// delegate may hold the caller's trust or sign-in decisions, which a session
/// made here would not have. The given session is never invalidated; one
/// made for the lane is, once replaced or once no source uses the lane.
final class HTTPSessionLane: @unchecked Sendable {
  private let lock = NSLock()
  private let renewal: (@Sendable () -> URLSession)?
  private var current: URLSession
  private var generation = 0
  /// `current`, when it was made for the lane.
  private var made: URLSession?

  init(session: URLSession, makeSession: (@Sendable () -> URLSession)?) {
    current = session
    if let makeSession {
      renewal = makeSession
    } else if session.delegate == nil {
      let configuration = session.configuration
      renewal = { URLSession(configuration: configuration) }
    } else {
      renewal = nil
    }
  }

  deinit { made?.finishTasksAndInvalidate() }

  /// The session for a new request, and its generation, to name it by after
  /// a timeout.
  var session: (session: URLSession, generation: Int) {
    lock.lock(); defer { lock.unlock() }
    return (current, generation)
  }

  /// After a request on the session of `generation` timed out: a fresh
  /// session for the requests to come, unless another timeout has already
  /// replaced it. True when this call replaced it.
  func renew(after generation: Int) -> Bool {
    lock.lock()
    guard generation == self.generation, let renewal else {
      lock.unlock()
      return false
    }
    // Made under the lock, so that timeouts seen together make one session.
    let fresh = renewal()
    let replaced = made
    current = fresh
    made = fresh
    self.generation += 1
    lock.unlock()
    // Requests still going on it finish first.
    replaced?.finishTasksAndInvalidate()
    return true
  }
}
