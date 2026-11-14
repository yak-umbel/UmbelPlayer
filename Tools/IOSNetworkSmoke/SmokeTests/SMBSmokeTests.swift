import Foundation
import UmbelCore
import UmbelSMBSource
import XCTest

/// Reads a file from a Samba server the host Mac runs, which `servers.sh` starts.
final class SMBSmokeTests: XCTestCase {
  private struct Server { let host: String, port: String, user: String, password: String, size: Int }

  private func server() throws -> Server {
    let env = ProcessInfo.processInfo.environment
    let host = env["UMBEL_SMOKE_HOST"] ?? "127.0.0.1"
    guard let port = env["UMBEL_SMOKE_SMB_PORT"], let user = env["UMBEL_SMOKE_USER"],
      let password = env["UMBEL_SMOKE_SMB_PASSWORD"], let size = Int(env["UMBEL_SMOKE_FILE_SIZE"] ?? "")
    else { throw XCTSkip("no SMB server in the environment") }
    return Server(host: host, port: port, user: user, password: password, size: size)
  }

  private func readAll(_ source: UmbelSMBSource) async throws -> Data {
    var all = Data()
    while true {
      let piece = try await source.read(offset: Int64(all.count), maxLength: 400_000)
      if piece.isEmpty { return all }
      all.append(piece)
    }
  }

  private func expected(_ size: Int) -> Data {
    Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ ($0 >> 8)) })
  }

  func testAFileIsReadWholeOverSMBWithALogin() async throws {
    let server = try server()
    let source = try UmbelSMBSource(
      url: URL(string: "smb://\(server.user):\(server.password)@\(server.host):\(server.port)/share/movie.bin")!)
    let length = await source.contentLength
    XCTAssertEqual(length, Int64(server.size))
    let all = try await readAll(source)
    XCTAssertEqual(all, expected(server.size))
    await source.invalidate()
  }

  func testAFileIsReadOverEncryptedSMB() async throws {
    let server = try server()
    let source = try UmbelSMBSource(
      url: URL(string: "smb://\(server.user):\(server.password)@\(server.host):\(server.port)/share/movie.bin")!,
      configuration: .init(requireEncryption: true))
    let all = try await readAll(source)
    XCTAssertEqual(all, expected(server.size))
    await source.invalidate()
  }

  func testAGuestReadsWhatAShareOffersGuests() async throws {
    let server = try server()
    let source = try UmbelSMBSource(url: URL(string: "smb://\(server.host):\(server.port)/open/movie.bin")!)
    let data = try await source.read(offset: 0, maxLength: 1_000)
    XCTAssertEqual(data.count, 1_000)
    await source.invalidate()
  }

  func testAWrongPasswordIsRefused() async throws {
    let server = try server()
    let source = try UmbelSMBSource(
      url: URL(string: "smb://\(server.user):not-the-password@\(server.host):\(server.port)/share/movie.bin")!)
    do {
      _ = try await source.read(offset: 0, maxLength: 100)
      XCTFail("a read went through")
    } catch {
      XCTAssertEqual(error as? UmbelError, .sourceUnavailable(detail: "authentication failed"))
    }
    await source.invalidate()
  }
}
