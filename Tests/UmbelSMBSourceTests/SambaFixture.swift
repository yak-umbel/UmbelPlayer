import Darwin
import Foundation
import XCTest

/// A Samba server run as the user who runs the tests, on a loopback port, with
/// a private configuration and password database, and a directory to serve.
/// Tests that need it skip where Samba is not installed (`brew install samba`,
/// which names its server `samba-dot-org-smbd` so as not to meet the system's).
///
/// The directory has to be short: Samba makes Unix sockets in it, and a path
/// to one may not pass a hundred bytes.
final class SambaFixture {
  enum Mode: String { case off = "disabled", optional = "auto", required = "mandatory" }

  let directory: URL
  let port: UInt16
  let username = NSUserName()
  let password = "pass-for-the-test-1"
  private let process: Process

  /// Where the files of the share `share` are put.
  var root: URL { directory.appendingPathComponent("share") }

  static func start(signing: Mode = .optional, encryption: Mode = .optional) throws -> SambaFixture {
    guard let server = ["/opt/homebrew/sbin/samba-dot-org-smbd", "/usr/local/sbin/samba-dot-org-smbd"]
      .first(where: { FileManager.default.isExecutableFile(atPath: $0) }),
      let pdbedit = ["/opt/homebrew/bin/pdbedit", "/usr/local/bin/pdbedit"]
        .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    else { throw XCTSkip("Samba is not installed (brew install samba)") }
    return try SambaFixture(server: server, pdbedit: pdbedit, signing: signing, encryption: encryption)
  }

  private init(server: String, pdbedit: String, signing: Mode, encryption: Mode) throws {
    let manager = FileManager.default
    let made = manager.temporaryDirectory.appendingPathComponent("umbelsmb-\(UInt32.random(in: 0..<999_999))")
    guard made.path.utf8.count < 70 else { throw XCTSkip("the temporary directory's path is too long for Samba's sockets") }
    directory = made
    for sub in ["share", "private", "lock", "state", "cache", "pid", "ncalrpc"] {
      try manager.createDirectory(at: made.appendingPathComponent(sub), withIntermediateDirectories: true)
    }
    port = try Self.freePort()
    let path = made.path
    let config = """
      [global]
        server role = standalone server
        workgroup = TESTGROUP
        netbios name = UMBELTEST
        security = user
        map to guest = Bad User
        guest account = \(username)
        passdb backend = tdbsam:\(path)/private/passdb.tdb
        private dir = \(path)/private
        lock directory = \(path)/lock
        state directory = \(path)/state
        cache directory = \(path)/cache
        pid directory = \(path)/pid
        ncalrpc dir = \(path)/ncalrpc
        log file = \(path)/log.%m
        max log size = 1000
        smb ports = \(port)
        interfaces = 127.0.0.1
        bind interfaces only = yes
        disable netbios = yes
        load printers = no
        printcap name = /dev/null
        disable spoolss = yes
        server min protocol = SMB2
        usershare max shares = 0
        log level = \(ProcessInfo.processInfo.environment["UMBEL_KEEP_FIXTURE"] == nil ? 0 : 3)
        server signing = \(signing.rawValue)
        smb encrypt = \(encryption.rawValue)

      [share]
        path = \(path)/share
        read only = yes
        guest ok = no

      [open]
        path = \(path)/share
        read only = yes
        guest ok = yes
      """
    try config.write(to: made.appendingPathComponent("smb.conf"), atomically: true, encoding: .utf8)
    try Self.addUser(pdbedit: pdbedit, config: made.appendingPathComponent("smb.conf").path, user: username, password: password)
    process = Process()
    process.executableURL = URL(fileURLWithPath: server)
    process.arguments = ["--foreground", "--no-process-group", "-s", made.appendingPathComponent("smb.conf").path]
    // Not the test runner's environment, whose library search paths are for its own libraries.
    process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory(), "LANG": "C"]
    // What it says on starting goes to a file, which a skip then shows.
    let output = made.appendingPathComponent("smbd.out")
    manager.createFile(atPath: output.path, contents: nil)
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = try FileHandle(forWritingTo: output)
    process.standardError = process.standardOutput
    try process.run()
    try waitUntilListening()
  }

  private func waitUntilListening() throws {
    for _ in 0..<100 {
      guard process.isRunning else {
        throw XCTSkip("smbd would not run here (\(process.terminationReason == .exit ? "exit" : "signal") \(process.terminationStatus)):\n\(log)")
      }
      if Self.canConnect(port) { return }
      Thread.sleep(forTimeInterval: 0.05)
    }
    stop()
    throw XCTSkip("smbd did not come up:\n\(log)")
  }

  var log: String {
    (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?
      .filter { $0.hasPrefix("log.") || $0 == "smbd.out" }
      .compactMap { try? String(contentsOf: directory.appendingPathComponent($0), encoding: .utf8) }
      .joined(separator: "\n") ?? ""
  }

  func serve(_ name: String, _ data: Data) throws -> String {
    try data.write(to: root.appendingPathComponent(name))
    return name
  }

  /// `smb://user:password@127.0.0.1:port/share/path`, the login left out where nil.
  func url(share: String = "share", path: String, user: String? = nil, password: String? = nil, login: Bool = true) -> URL {
    var parts = URLComponents()
    parts.scheme = "smb"
    parts.host = "127.0.0.1"
    parts.port = Int(port)
    if login {
      parts.user = user ?? username
      parts.password = password ?? self.password
    }
    parts.path = "/\(share)/\(path)"
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
    // Kept for looking at Samba's own log, where asked.
    if ProcessInfo.processInfo.environment["UMBEL_KEEP_FIXTURE"] != nil {
      print("SMB fixture kept: \(directory.path)")
    } else {
      try? FileManager.default.removeItem(at: directory)
    }
  }

  // ── Helpers ─────────────────────────────────────────

  private static func addUser(pdbedit: String, config: String, user: String, password: String) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: pdbedit)
    process.arguments = ["-s", config, "-a", "-u", user, "-t"]
    let input = Pipe()
    process.standardInput = input
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    input.fileHandleForWriting.write(Data("\(password)\n\(password)\n".utf8))
    try? input.fileHandleForWriting.close()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw XCTSkip("pdbedit could not make the test user") }
  }

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
    return String(decoding: data, as: UTF8.self)
  }

  static func loopback(_ port: UInt16) -> sockaddr_in {
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
    return address
  }

  private static func freePort() throws -> UInt16 {
    let made = socket(AF_INET, SOCK_STREAM, 0)
    defer { Darwin.close(made) }
    var address = loopback(0)
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
    var address = loopback(port)
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
    var address = SambaFixture.loopback(0)
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
