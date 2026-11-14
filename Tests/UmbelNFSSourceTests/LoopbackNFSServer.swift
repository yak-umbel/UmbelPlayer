import Darwin
import Foundation
import XCTest

/// A minimal NFS version 3 server on a loopback port, for the tests: the MOUNT
/// and NFS programs of RFC 1813 over TCP in ONC RPC (RFC 5531), with the few
/// calls that mounting a share and reading a file need, and nothing that
/// writes. NFS and MOUNT are on the one port, so no portmapper is run.
///
/// It is written to the RFCs, and the client it is tried with is another's:
/// a reply the client cannot read fails the test. One thread for each
/// connection, serving what is under `directory` as the export `exportName`.
final class LoopbackNFSServer: @unchecked Sendable {
  let port: UInt16
  let exportName: String
  let directory: URL
  /// The largest read it says it takes, which makes the client read in pieces.
  let readSize: UInt32

  private let listener: Int32
  private let lock = NSLock()
  private var stopping = false
  private var connections: [Int32] = []
  private var paths: [UInt64: String] = [:]   // file handle → path under the export
  private var handles: [String: UInt64] = [:]
  private var holding = false
  private var calls: [String] = []
  private var credentials: (uid: UInt32, gid: UInt32)?
  private var refusedExports: Set<String> = []

  // Program, version and procedure numbers (RFC 1813, appendix I).
  private enum Program { static let mount: UInt32 = 100_005, nfs: UInt32 = 100_003 }
  private enum Status { static let ok: UInt32 = 0, noEntry: UInt32 = 2, access: UInt32 = 13, stale: UInt32 = 70, notDirectory: UInt32 = 20 }

  init(exportName: String = "/media", readSize: UInt32 = 32_768) throws {
    self.exportName = exportName
    self.readSize = readSize
    directory = FileManager.default.temporaryDirectory.appendingPathComponent("umbelnfs-\(UInt32.random(in: 0..<999_999))")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let made = socket(AF_INET, SOCK_STREAM, 0)
    var address = Self.loopback(0)
    var on: Int32 = 1
    setsockopt(made, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(made, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard bound == 0, listen(made, 8) == 0 else {
      Darwin.close(made)
      throw XCTSkip("no loopback port")
    }
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    var named = Self.loopback(0)
    _ = withUnsafeMutablePointer(to: &named) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(made, $0, &length) }
    }
    listener = made
    port = UInt16(bigEndian: named.sin_port)
    // The root of the export is handle 1.
    paths[1] = ""
    handles[""] = 1
    Thread { [self] in acceptLoop() }.start()
  }

  // ── What the tests ask of it ────────────────────────

  @discardableResult
  func serve(_ path: String, _ data: Data) throws -> String {
    let url = directory.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
    return path
  }

  /// Stops answering, as a server that has hung does; the calls are still taken.
  func hold(_ value: Bool) { lock.withLock { holding = value } }

  /// The user and group the last call said it was from (AUTH_SYS).
  var lastCredentials: (uid: UInt32, gid: UInt32)? { lock.withLock { credentials } }

  /// The procedures called so far, as "NFS3 READ" and the like.
  var procedures: [String] { lock.withLock { calls } }

  func refuseMounting(_ name: String) { lock.withLock { _ = refusedExports.insert(name) } }

  func stop() {
    lock.withLock { stopping = true }
    shutdown(listener, SHUT_RDWR)
    Darwin.close(listener)
    for descriptor in lock.withLock({ connections }) { shutdown(descriptor, SHUT_RDWR) }
    try? FileManager.default.removeItem(at: directory)
  }

  // ── Connections ─────────────────────────────────────

  private func acceptLoop() {
    while true {
      let peer = accept(listener, nil, nil)
      if peer < 0 { return }
      var on: Int32 = 1
      setsockopt(peer, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
      lock.withLock { connections.append(peer) }
      Thread { [self] in serve(peer) }.start()
    }
  }

  private func serve(_ peer: Int32) {
    defer { Darwin.close(peer) }
    while !lock.withLock({ stopping }) {
      guard let record = readRecord(peer) else { return }
      guard let reply = answer(record) else { continue }
      // A server that has hung takes the call and says nothing.
      while lock.withLock({ holding && !stopping }) { Thread.sleep(forTimeInterval: 0.02) }
      if lock.withLock({ stopping }) { return }
      var framed = Data()
      var header = UInt32(reply.count) | 0x8000_0000
      withUnsafeBytes(of: &header) { framed.append(contentsOf: Array($0.reversed())) }
      framed.append(reply)
      guard writeAll(peer, framed) else { return }
    }
  }

  private func readRecord(_ peer: Int32) -> Data? {
    var record = Data()
    while true {
      guard let header = readExactly(peer, 4) else { return nil }
      let value = header.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
      guard let fragment = readExactly(peer, Int(value & 0x7FFF_FFFF)) else { return nil }
      record.append(fragment)
      if value & 0x8000_0000 != 0 { return record }
    }
  }

  private func readExactly(_ peer: Int32, _ count: Int) -> Data? {
    var data = Data(count: count)
    var got = 0
    while got < count {
      let n = data.withUnsafeMutableBytes { recv(peer, $0.baseAddress! + got, count - got, 0) }
      if n <= 0 { return nil }
      got += n
    }
    return data
  }

  private func writeAll(_ peer: Int32, _ data: Data) -> Bool {
    var sent = 0
    while sent < data.count {
      let n = data.withUnsafeBytes { send(peer, $0.baseAddress! + sent, data.count - sent, 0) }
      if n <= 0 { return false }
      sent += n
    }
    return true
  }

  // ── RPC ─────────────────────────────────────────────

  /// The reply to one call, or nil for what is not a call.
  private func answer(_ record: Data) -> Data? {
    var call = XDRReader(record)
    guard let xid = call.u32(), call.u32() == 0, call.u32() == 2, let program = call.u32(), let version = call.u32(),
      let procedure = call.u32(), let flavor = call.u32(), let credentialLength = call.u32()
    else { return nil }
    let body = call.take(Int(credentialLength + 3) & ~3)
    if flavor == 1, var credential = body.map({ XDRReader($0) }) {
      _ = credential.u32()                // stamp
      _ = credential.string()             // machine name
      if let uid = credential.u32(), let gid = credential.u32() { lock.withLock { credentials = (uid, gid) } }
    }
    _ = call.u32()                        // verifier flavor
    if let verifierLength = call.u32() { _ = call.take(Int(verifierLength + 3) & ~3) }
    var reply = XDRWriter()
    reply.u32(xid)
    reply.u32(1)   // REPLY
    reply.u32(0)   // MSG_ACCEPTED
    reply.u32(0)   // verifier: none
    reply.u32(0)
    let known = (program == Program.mount && version == 3) || (program == Program.nfs && version == 3)
    guard known else {
      reply.u32(program == Program.mount || program == Program.nfs ? 2 : 1)   // PROG_MISMATCH / PROG_UNAVAIL
      if program == Program.mount || program == Program.nfs { reply.u32(3); reply.u32(3) }
      return reply.data
    }
    var result = XDRWriter()
    let name = program == Program.mount ? "MOUNT3 \(procedure)" : "NFS3 \(procedure)"
    lock.withLock { calls.append(name) }
    let handled = program == Program.mount ? mount(procedure, &call, &result) : nfs(procedure, &call, &result)
    guard handled else {
      reply.u32(3)   // PROC_UNAVAIL
      return reply.data
    }
    reply.u32(0)     // SUCCESS
    reply.data.append(result.data)
    return reply.data
  }

  // ── MOUNT version 3 ─────────────────────────────────

  private func mount(_ procedure: UInt32, _ call: inout XDRReader, _ result: inout XDRWriter) -> Bool {
    switch procedure {
    case 0, 3: return true   // NULL, UMNT: nothing to say
    case 1:                  // MNT
      let requested = call.string() ?? ""
      if lock.withLock({ refusedExports.contains(requested) }) {
        result.u32(13)   // MNT3ERR_ACCES
      } else if requested != exportName {
        result.u32(2)    // MNT3ERR_NOENT
      } else {
        result.u32(0)
        result.opaque(handle(for: ""))
        result.u32(1)    // one authentication flavor: AUTH_SYS
        result.u32(1)
      }
      return true
    default: return false
    }
  }

  // ── NFS version 3 ───────────────────────────────────

  private func nfs(_ procedure: UInt32, _ call: inout XDRReader, _ result: inout XDRWriter) -> Bool {
    switch procedure {
    case 0: return true      // NULL
    case 1:                  // GETATTR
      guard let path = path(of: call.opaque()) else { result.u32(Status.stale); return true }
      guard let attributes = attributes(of: path) else { result.u32(Status.noEntry); return true }
      result.u32(Status.ok)
      result.data.append(attributes)
      return true
    case 3:                  // LOOKUP
      guard let directory = path(of: call.opaque()), let name = call.string() else { result.u32(Status.stale); result.u32(0); return true }
      let path = directory.isEmpty ? name : "\(directory)/\(name)"
      guard let attributes = attributes(of: path) else {
        result.u32(Status.noEntry)
        result.u32(0)    // no directory attributes
        return true
      }
      result.u32(Status.ok)
      result.opaque(handle(for: path))
      result.u32(1); result.data.append(attributes)
      result.u32(0)
      return true
    case 4:                  // ACCESS: everything asked is allowed
      guard let path = path(of: call.opaque()), let asked = call.u32(), let attributes = attributes(of: path) else {
        result.u32(Status.stale); result.u32(0); return true
      }
      result.u32(Status.ok)
      result.u32(1); result.data.append(attributes)
      result.u32(asked)
      return true
    case 6:                  // READ
      guard let path = path(of: call.opaque()), let offset = call.u64(), let count = call.u32() else {
        result.u32(Status.stale); result.u32(0); return true
      }
      guard let handle = try? FileHandle(forReadingFrom: self.directory.appendingPathComponent(path)),
        let attributes = attributes(of: path)
      else { result.u32(Status.noEntry); result.u32(0); return true }
      defer { try? handle.close() }
      try? handle.seek(toOffset: offset)
      let data = (try? handle.read(upToCount: Int(min(count, readSize)))) ?? Data()
      let size = fileSize(path) ?? 0
      result.u32(Status.ok)
      result.u32(1); result.data.append(attributes)
      result.u32(UInt32(data.count))
      result.u32(offset + UInt64(data.count) >= size ? 1 : 0)   // eof
      result.opaque(data)
      return true
    case 19:                 // FSINFO
      guard path(of: call.opaque()) != nil else { result.u32(Status.stale); result.u32(0); return true }
      result.u32(Status.ok)
      result.u32(0)          // no attributes
      for value in [readSize, readSize, 4_096, 65_536, 65_536, 4_096, 8_192] { result.u32(value) }   // rtmax rtpref rtmult wtmax wtpref wtmult dtpref
      result.u64(UInt64.max >> 1)   // maxfilesize
      result.u32(0); result.u32(1)  // time_delta
      result.u32(0x1b)       // properties: link, symlink, homogeneous, cansettime
      return true
    default: return false
    }
  }

  // ── The files ───────────────────────────────────────

  private func handle(for path: String) -> Data {
    let number = lock.withLock { () -> UInt64 in
      if let known = handles[path] { return known }
      let made = UInt64(handles.count + 1)
      handles[path] = made
      paths[made] = path
      return made
    }
    var data = Data()
    for shift in stride(from: 56, through: 0, by: -8) { data.append(UInt8(truncatingIfNeeded: number >> UInt64(shift))) }
    return data
  }

  private func path(of handle: Data?) -> String? {
    guard let handle, handle.count == 8 else { return nil }
    let number = handle.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
    return lock.withLock { paths[number] }
  }

  private func fileSize(_ path: String) -> UInt64? {
    guard let size = (try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(path).path))?[.size] as? NSNumber
    else { return nil }
    return size.uint64Value
  }

  /// fattr3 (RFC 1813, 2.5), or nil for a path that is not there.
  private func attributes(of path: String) -> Data? {
    var isDirectory: ObjCBool = false
    let url = directory.appendingPathComponent(path)
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }
    let size = isDirectory.boolValue ? 4_096 : (fileSize(path) ?? 0)
    var writer = XDRWriter()
    writer.u32(isDirectory.boolValue ? 2 : 1)         // type: NF3DIR, NF3REG
    writer.u32(isDirectory.boolValue ? 0o755 : 0o644) // mode
    writer.u32(1)                                    // nlink
    writer.u32(501); writer.u32(20)                  // uid, gid
    writer.u64(size); writer.u64(size)               // size, used
    writer.u32(0); writer.u32(0)                     // rdev
    writer.u64(1)                                    // fsid
    writer.u64(UInt64(abs(path.hashValue % 1_000_000)) + 2)   // fileid
    for _ in 0..<3 { writer.u32(1_700_000_000); writer.u32(0) }   // atime, mtime, ctime
    return writer.data
  }

  private static func loopback(_ port: UInt16) -> sockaddr_in {
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
    return address
  }
}

// ── XDR (RFC 4506) ────────────────────────────────────

struct XDRReader {
  private let data: Data
  private var offset = 0
  init(_ data: Data) { self.data = data }

  mutating func take(_ count: Int) -> Data? {
    guard count >= 0, offset + count <= data.count else { return nil }
    defer { offset += count }
    return data.subdata(in: data.startIndex + offset..<data.startIndex + offset + count)
  }
  mutating func u32() -> UInt32? { take(4)?.reduce(UInt32(0)) { $0 << 8 | UInt32($1) } }
  mutating func u64() -> UInt64? { take(8)?.reduce(UInt64(0)) { $0 << 8 | UInt64($1) } }
  /// Variable-length opaque data, as its bytes.
  mutating func opaque() -> Data? {
    guard let length = u32(), let bytes = take(Int(length)) else { return nil }
    _ = take((4 - Int(length) % 4) % 4)
    return bytes
  }
  mutating func string() -> String? { opaque().map { String(decoding: $0, as: UTF8.self) } }
}

struct XDRWriter {
  var data = Data()
  mutating func u32(_ value: UInt32) { for shift in stride(from: 24, through: 0, by: -8) { data.append(UInt8(truncatingIfNeeded: value >> UInt32(shift))) } }
  mutating func u64(_ value: UInt64) { u32(UInt32(truncatingIfNeeded: value >> 32)); u32(UInt32(truncatingIfNeeded: value)) }
  mutating func opaque(_ bytes: Data) {
    u32(UInt32(bytes.count))
    data.append(bytes)
    data.append(Data(repeating: 0, count: (4 - bytes.count % 4) % 4))
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
    Thread { [self] in
      while true {
        let peer = accept(listener, nil, nil)
        if peer < 0 { return }
        lock.withLock { accepted.append(peer) }
      }
    }.start()
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
