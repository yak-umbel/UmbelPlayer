import Foundation

/// A separate process can enter dispatchMain without taking over XCTest's
/// run loop. On macOS that queue may then run on a non-main pthread.
@main
struct DisplayLayerAccessCheck {
  private enum ExpectedFailure: Error { case operation }

  static func main() {
    switch CommandLine.arguments.dropFirst().first {
    case "main-thread":
      precondition(Thread.isMainThread)
      checkAccess()
    case "main-queue":
      DispatchQueue.global().async {
        DispatchQueue.main.async {
          dispatchPrecondition(condition: .onQueue(.main))
          checkAccess()
          exit(0)
        }
      }
      dispatchMain()
    case "background":
      DispatchQueue.global().async {
        dispatchPrecondition(condition: .notOnQueue(.main))
        checkAccess()
        exit(0)
      }
      dispatchMain()
    default:
      fatalError("expected an entry mode")
    }
  }

  private static func checkAccess() {
    let result = DisplayLayerAccess.sync {
      dispatchPrecondition(condition: .onQueue(.main))
      return DisplayLayerAccess.sync { 42 }
    }
    precondition(result == 42, "nested synchronous access must return its result")
    do {
      try DisplayLayerAccess.sync { throw ExpectedFailure.operation }
      fatalError("the operation's error was lost")
    } catch ExpectedFailure.operation {
      // The same error must reach the synchronous caller.
    } catch {
      fatalError("unexpected error: \(error)")
    }
  }
}
