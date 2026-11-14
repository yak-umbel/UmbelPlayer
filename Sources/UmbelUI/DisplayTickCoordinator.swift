import Foundation
import UmbelCore

/// Observations from display callbacks and render calls. A returned frame means
/// the renderer accepted work, not that the GPU or screen finished showing it.
public struct UmbelDisplayStatistics: Sendable {
  public let tickCount: Int
  public let busyTickCount: Int
  public let presentedFrameCount: Int
  public let emptyRenderCount: Int
  public let errorCount: Int
  public let reportedDroppedFrameCount: Int
  public let lastTickInterval: TimeInterval?
  public let maximumTickInterval: TimeInterval?
  public let lastRenderDuration: TimeInterval?
  public let maximumRenderDuration: TimeInterval?
  public let lastError: String?
  public let isRendering: Bool
}

/// Shared by the iOS display link and deterministic tests. Its lock, not the
/// main actor, guards completion so a blocked UI thread cannot hold the gate.
final class DisplayTickCoordinator: @unchecked Sendable {
  typealias Render = @Sendable () async throws -> PresentedFrame?

  private let lock = NSLock()
  private let render: Render
  private var running = false
  private var generation = 0
  private var task: Task<Void, Never>?
  private var rendering = false
  private var previousTick: TimeInterval?
  private var tickCount = 0
  private var busyTickCount = 0
  private var presentedFrameCount = 0
  private var emptyRenderCount = 0
  private var errorCount = 0
  private var reportedDroppedFrameCount = 0
  private var lastTickInterval: TimeInterval?
  private var maximumTickInterval: TimeInterval?
  private var lastRenderDuration: TimeInterval?
  private var maximumRenderDuration: TimeInterval?
  private var lastError: String?

  init(render: @escaping Render) { self.render = render }

  func start() {
    lock.withLock {
      guard !running else { return }
      generation &+= 1
      running = true
      previousTick = nil
    }
  }

  func stop() {
    let old = lock.withLock { () -> Task<Void, Never>? in
      guard running else { return nil }
      generation &+= 1
      running = false
      previousTick = nil
      return task
    }
    old?.cancel()
  }

  func tick(at time: TimeInterval) {
    lock.withLock {
      guard running else { return }
      tickCount += 1
      if let previousTick, time >= previousTick {
        let interval = time - previousTick
        lastTickInterval = interval
        maximumTickInterval = max(maximumTickInterval ?? 0, interval)
      }
      previousTick = time
      guard !rendering else {
        busyTickCount += 1
        return
      }
      rendering = true
      let current = generation
      task = Task.detached(priority: .userInitiated) { [self] in
        let started = ProcessInfo.processInfo.systemUptime
        let result: Result<PresentedFrame?, Error>
        do {
          try Task.checkCancellation()
          result = .success(try await render())
        }
        catch { result = .failure(error) }
        let duration = ProcessInfo.processInfo.systemUptime - started
        lock.withLock {
          rendering = false
          task = nil
          guard running, generation == current else { return }
          lastRenderDuration = duration
          maximumRenderDuration = max(maximumRenderDuration ?? 0, duration)
          switch result {
          case .success(.some(let frame)):
            presentedFrameCount += 1
            reportedDroppedFrameCount += frame.droppedFrames
            lastError = nil
          case .success(.none):
            emptyRenderCount += 1
            lastError = nil
          case .failure(let error):
            errorCount += 1
            lastError = String(describing: error)
          }
        }
      }
    }
  }

  var snapshot: UmbelDisplayStatistics {
    lock.withLock {
      UmbelDisplayStatistics(
        tickCount: tickCount, busyTickCount: busyTickCount,
        presentedFrameCount: presentedFrameCount, emptyRenderCount: emptyRenderCount,
        errorCount: errorCount, reportedDroppedFrameCount: reportedDroppedFrameCount,
        lastTickInterval: lastTickInterval, maximumTickInterval: maximumTickInterval,
        lastRenderDuration: lastRenderDuration, maximumRenderDuration: maximumRenderDuration,
        lastError: lastError, isRendering: rendering)
    }
  }
}
