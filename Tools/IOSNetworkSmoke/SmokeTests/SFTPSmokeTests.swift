import Foundation
import UmbelCore
import UmbelSFTPSource
import XCTest

/// Reads a file from an SSH server the host Mac runs, which `servers.sh` starts and
/// describes in the environment (`TEST_RUNNER_…` reaches the runner without the prefix).
final class SFTPSmokeTests: XCTestCase {
  private struct Server {
    let host: String, port: String, key: String, fingerprint: String, user: String, file: String, size: Int
  }

  private func server() throws -> Server {
    let env = ProcessInfo.processInfo.environment
    let host = env["UMBEL_SMOKE_HOST"] ?? "127.0.0.1"
    guard let port = env["UMBEL_SMOKE_SSH_PORT"], let key = env["UMBEL_SMOKE_SSH_KEY"],
      let fingerprint = env["UMBEL_SMOKE_SSH_FINGERPRINT"], let user = env["UMBEL_SMOKE_USER"],
      let file = env["UMBEL_SMOKE_SSH_FILE"], let size = Int(env["UMBEL_SMOKE_FILE_SIZE"] ?? "")
    else { throw XCTSkip("no SSH server in the environment") }
    return Server(host: host, port: port, key: key, fingerprint: fingerprint, user: user, file: file, size: size)
  }

  private func source(_ server: Server, trusting: [String]) throws -> UmbelSFTPSource {
    try UmbelSFTPSource(
      url: URL(string: "sftp://\(server.user)@\(server.host):\(server.port)\(server.file)")!,
      configuration: .init(connectTimeout: 15, authentication: .privateKey(file: URL(fileURLWithPath: server.key))),
      hostKeyVerifier: UmbelSFTPSource.trusting(fingerprints: trusting))
  }

  func testAFileIsReadWholeOverSFTP() async throws {
    let server = try server()
    let source = try source(server, trusting: [server.fingerprint])
    let length = await source.contentLength
    XCTAssertEqual(length, Int64(server.size))
    var all = Data()
    while true {
      let piece = try await source.read(offset: Int64(all.count), maxLength: 262_144)
      if piece.isEmpty { break }
      all.append(piece)
    }
    XCTAssertEqual(all.count, server.size)
    let expected = Data((0..<server.size).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ ($0 >> 8)) })
    XCTAssertEqual(all, expected)
    await source.invalidate()
  }

  func testAHostKeyNobodyTrustsIsRefused() async throws {
    let server = try server()
    let source = try source(server, trusting: ["SHA256:" + String(repeating: "A", count: 43)])
    do {
      _ = try await source.read(offset: 0, maxLength: 100)
      XCTFail("a read went through")
    } catch {
      XCTAssertEqual(error as? UmbelError, .sourceUnavailable(detail: "host key not trusted"))
    }
    await source.invalidate()
  }
}
