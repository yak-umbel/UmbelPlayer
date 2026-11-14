import Darwin
import Foundation
import XCTest

/// An SSH server of the machine's own, run as the user who runs the tests, on
/// a loopback port, with a directory to serve and keys made for the occasion.
/// Tests that need it skip where the tools are not there.
///
/// Only keys log in: a server not run by root cannot check a password.
final class SSHDFixture {
  let directory: URL
  let port: UInt16
  let username = NSUserName()
  let hostFingerprint: String
  let ed25519Key: URL
  let rsaKey: URL
  let encryptedKey: URL
  let encryptedKeyPassphrase = "key-passphrase"
  let strangerKey: URL
  private let process: Process
  private let logURL: URL

  /// Where the files to serve are put.
  var root: URL { directory.appendingPathComponent("served") }

  static func start() throws -> SSHDFixture {
    for tool in ["/usr/sbin/sshd", "/usr/bin/ssh-keygen", "/usr/libexec/sftp-server"]
    where !FileManager.default.isExecutableFile(atPath: tool) {
      throw XCTSkip("\(tool) is not on this machine")
    }
    return try SSHDFixture()
  }

  private init() throws {
    let manager = FileManager.default
    let directory = manager.temporaryDirectory.appendingPathComponent("umbel-sshd-\(UUID().uuidString)")
    self.directory = directory
    try manager.createDirectory(at: directory.appendingPathComponent("served"), withIntermediateDirectories: true)
    func key(_ name: String, type: String, extra: [String] = [], passphrase: String = "") throws -> URL {
      let file = directory.appendingPathComponent(name)
      try Self.run("/usr/bin/ssh-keygen", ["-q", "-t", type] + extra + ["-N", passphrase, "-f", file.path])
      return file
    }
    let host = try key("hostkey", type: "ed25519")
    ed25519Key = try key("client_ed25519", type: "ed25519")
    rsaKey = try key("client_rsa", type: "rsa", extra: ["-b", "2048", "-m", "PEM"])
    encryptedKey = try key("client_encrypted", type: "ed25519", passphrase: encryptedKeyPassphrase)
    strangerKey = try key("stranger", type: "ed25519")
    let authorized = try [ed25519Key, rsaKey, encryptedKey].map {
      try String(contentsOf: $0.appendingPathExtension("pub"), encoding: .utf8)
    }.joined()
    try authorized.write(to: directory.appendingPathComponent("authorized_keys"), atomically: true, encoding: .utf8)
    hostFingerprint = try Self.run("/usr/bin/ssh-keygen", ["-l", "-E", "sha256", "-f", host.path + ".pub"])
      .split(separator: " ")[1].description
    port = try Self.freePort()
    logURL = directory.appendingPathComponent("sshd.log")
    let config = """
      Port \(port)
      ListenAddress 127.0.0.1
      HostKey \(host.path)
      AuthorizedKeysFile \(directory.path)/authorized_keys
      PidFile \(directory.path)/sshd.pid
      UsePAM no
      StrictModes no
      PasswordAuthentication no
      KbdInteractiveAuthentication no
      PubkeyAuthentication yes
      Subsystem sftp /usr/libexec/sftp-server
      LogLevel DEBUG1
      """
    let configURL = directory.appendingPathComponent("sshd_config")
    try config.write(to: configURL, atomically: true, encoding: .utf8)
    manager.createFile(atPath: logURL.path, contents: nil)
    process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/sshd")
    process.arguments = ["-D", "-e", "-f", configURL.path]
    process.standardError = try FileHandle(forWritingTo: logURL)
    process.standardOutput = process.standardError
    try process.run()
    try waitUntilListening()
  }

  private func waitUntilListening() throws {
    for _ in 0..<100 {
      guard process.isRunning else { throw XCTSkip("sshd would not run here:\n\(log)") }
      if Self.canConnect(port) { return }
      Thread.sleep(forTimeInterval: 0.05)
    }
    stop()
    throw XCTSkip("sshd did not come up:\n\(log)")
  }

  var log: String { (try? String(contentsOf: logURL, encoding: .utf8)) ?? "" }

  /// The log, once `text` is in it or a while has passed.
  func log(waitingFor text: String, seconds: TimeInterval = 3) -> String {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end, !log.contains(text) { Thread.sleep(forTimeInterval: 0.05) }
    return log
  }

  func serve(_ name: String, _ data: Data) throws -> String {
    try data.write(to: root.appendingPathComponent(name))
    return root.appendingPathComponent(name).path
  }

  func url(path: String, user: String? = nil, password: String? = nil) -> URL {
    var parts = URLComponents()
    parts.scheme = "sftp"
    parts.host = "127.0.0.1"
    parts.port = Int(port)
    parts.user = user ?? username
    parts.password = password
    parts.path = path
    return parts.url!
  }

  /// Every process the server started for connections.
  func connectionProcesses() -> [pid_t] {
    var found: [pid_t] = []
    var frontier = [process.processIdentifier]
    let table = (try? Self.run("/bin/ps", ["-axo", "pid=,ppid="])) ?? ""
    let pairs = table.split(separator: "\n").compactMap { line -> (pid_t, pid_t)? in
      let numbers = line.split(separator: " ").compactMap { pid_t($0) }
      return numbers.count == 2 ? (numbers[0], numbers[1]) : nil
    }
    while let parent = frontier.popLast() {
      for (pid, ppid) in pairs where ppid == parent { found.append(pid); frontier.append(pid) }
    }
    return found
  }

  func stop() {
    if process.isRunning {
      for pid in connectionProcesses() { kill(pid, SIGCONT) }
      process.terminate()
      // Not waitUntilExit(), which on a thread of the cooperative pool can wait
      // for ever for an exit that has happened.
      let end = Date().addingTimeInterval(5)
      while process.isRunning, Date() < end { Thread.sleep(forTimeInterval: 0.05) }
      if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
    try? FileManager.default.removeItem(at: directory)
  }

  // ── Helpers ─────────────────────────────────────────

  @discardableResult
  static func run(_ tool: String, _ arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let text = String(decoding: data, as: UTF8.self)
    guard process.terminationStatus == 0 else {
      throw XCTSkip("\(tool) failed: \(text)")
    }
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func freePort() throws -> UInt16 {
    let made = socket(AF_INET, SOCK_STREAM, 0)
    defer { Darwin.close(made) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(made, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard bound == 0 else { throw XCTSkip("no loopback port") }
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(made, $0, &length) }
    }
    return UInt16(bigEndian: address.sin_port)
  }

  private static func canConnect(_ port: UInt16) -> Bool {
    let made = socket(AF_INET, SOCK_STREAM, 0)
    defer { Darwin.close(made) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
    return withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(made, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
      }
    }
  }
}

/// A server that takes connections and says nothing: what a peer that has
/// stopped answering looks like.
final class SilentServer: @unchecked Sendable {
  let port: UInt16
  private let listener: Int32
  private let lock = NSLock()
  private var accepted: [Int32] = []

  init() throws {
    let made = socket(AF_INET, SOCK_STREAM, 0)
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(made, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard bound == 0, listen(made, 4) == 0 else {
      Darwin.close(made)
      throw XCTSkip("no loopback port")
    }
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(made, $0, &length) }
    }
    listener = made
    port = UInt16(bigEndian: address.sin_port)
    let thread = Thread { [self] in
      while true {
        let peer = accept(listener, nil, nil)
        if peer < 0 { return }
        lock.withLock { accepted.append(peer) }
      }
    }
    thread.start()
  }

  func stop() {
    shutdown(listener, SHUT_RDWR)
    Darwin.close(listener)
    lock.withLock {
      for peer in accepted { Darwin.close(peer) }
      accepted = []
    }
  }
}
