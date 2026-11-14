import Darwin
import Foundation
import XCTest

/// An RTSP server and an RTP sender for the loopback, for sources that open
/// the connection themselves. Interleaved over TCP, one client, one media
/// description; no RTCP.
enum LoopbackRTSP {
  /// A session description with one media section, e.g. `m=audio 0 RTP/AVP 0`.
  static func sdp(media: String) -> String {
    ["v=0", "o=- 1 1 IN IP4 127.0.0.1", "s=Test", "c=IN IP4 0.0.0.0", "t=0 0", media, "a=control:streamid=0", ""]
      .joined(separator: "\r\n")
  }

  static func rtpPacket(
    payloadType: UInt8, sequence: UInt16, timestamp: UInt32, payload: Data, ssrc: UInt32 = 0x1234_5678
  ) -> Data {
    var packet = Data([0x80, payloadType & 0x7F])
    packet.append(contentsOf: [UInt8(sequence >> 8), UInt8(sequence & 0xFF)])
    packet.append(contentsOf: [UInt8(timestamp >> 24), UInt8((timestamp >> 16) & 0xFF),
                               UInt8((timestamp >> 8) & 0xFF), UInt8(timestamp & 0xFF)])
    packet.append(contentsOf: [UInt8(ssrc >> 24), UInt8((ssrc >> 16) & 0xFF), UInt8((ssrc >> 8) & 0xFF), UInt8(ssrc & 0xFF)])
    packet.append(payload)
    return packet
  }

  /// Twenty milliseconds of mu-law silence at 8 kHz, `count` times over.
  static func silentMuLaw(packets count: Int) -> [Data] {
    (0..<count).map {
      rtpPacket(payloadType: 0, sequence: UInt16($0), timestamp: UInt32($0 * 160), payload: Data(repeating: 0xFF, count: 160))
    }
  }

  /// A transport stream, seven of its 188-byte packets to an RTP packet
  /// (payload type 33).
  static func transportStream(_ data: Data) -> [Data] {
    let size = 188 * 7
    return stride(from: 0, to: data.count, by: size).enumerated().map { index, offset in
      rtpPacket(
        payloadType: 33, sequence: UInt16(truncatingIfNeeded: index), timestamp: UInt32(index * 3000),
        payload: Data(data[offset..<min(offset + size, data.count)]))
    }
  }

  /// Serves one client: answers its requests, and after PLAY sends `packets`
  /// once, then answers whatever else comes until it goes. `onEnd` is called
  /// when it has: after TEARDOWN, once its connection is closed, or when the
  /// connection is lost. With `cutAfterPlay` the connection is reset a second
  /// after the packets are sent, as a network that fails would.
  static func serve(
    sdp: String, packets: [Data], pacing: useconds_t = 1_000, cutAfterPlay: Bool = false,
    onEnd: @escaping @Sendable () -> Void = {}
  ) throws -> LoopbackTCPServer {
    try LoopbackTCPServer { connection in
      defer { onEnd() }
      while let request = connection.receiveText(until: "\r\n\r\n", timeout: 15) {
        let lines = request.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ").map(String.init)
        let method = parts.first ?? ""
        let target = parts.count > 1 ? parts[1] : ""
        let cseq = lines.first { $0.lowercased().hasPrefix("cseq:") }
          .map { $0.dropFirst(5).trimmingCharacters(in: .whitespaces) } ?? "0"
        func reply(_ headers: [String] = [], body: String = "") {
          var text = "RTSP/1.0 200 OK\r\nCSeq: \(cseq)\r\n" + headers.map { $0 + "\r\n" }.joined()
          if !body.isEmpty { text += "Content-Length: \(body.utf8.count)\r\n" }
          connection.send(Data((text + "\r\n" + body).utf8))
        }
        switch method {
        case "OPTIONS":
          reply(["Public: OPTIONS, DESCRIBE, SETUP, PLAY, TEARDOWN"])
        case "DESCRIBE":
          reply(["Content-Type: application/sdp", "Content-Base: \(target)/"], body: sdp)
        case "SETUP":
          reply(["Transport: RTP/AVP/TCP;unicast;interleaved=0-1", "Session: 12345678"])
        case "PLAY":
          reply(["Session: 12345678", "Range: npt=0.000-"])
          for packet in packets {
            var framed = Data([0x24, 0x00, UInt8(packet.count >> 8), UInt8(packet.count & 0xFF)])
            framed.append(packet)
            connection.send(framed)
            usleep(pacing)
          }
          if cutAfterPlay {
            sleep(1)
            connection.reset()
            return
          }
        case "TEARDOWN":
          reply(["Session: 12345678"])
          _ = connection.waitForPeerClose(timeout: 2)
          return
        default:
          reply()
        }
      }
    }
  }
}

/// Sends a transport stream as RTP datagrams (payload type 33) to a port on
/// the loopback, over and over, so that a reader joining at any moment gets
/// the tables it needs.
final class LoopbackRTPSender: @unchecked Sendable {
  private let lock = NSLock()
  private var stopped = false

  init(port: UInt16, transportStream: Data) {
    let packets = LoopbackRTSP.transportStream(transportStream)
    let thread = Thread { [self] in
      let descriptor = socket(AF_INET, SOCK_DGRAM, 0)
      defer { Darwin.close(descriptor) }
      var address = LoopbackTCPServer.loopback(port: port)
      var sequence: UInt16 = 0
      var timestamp: UInt32 = 0
      while !isStopped {
        for packet in packets where !isStopped {
          var datagram = packet
          // Fresh sequence numbers and times: it is one stream, going on.
          datagram.replaceSubrange(2..<4, with: [UInt8(sequence >> 8), UInt8(sequence & 0xFF)])
          datagram.replaceSubrange(4..<8, with: [UInt8(timestamp >> 24), UInt8((timestamp >> 16) & 0xFF),
                                                  UInt8((timestamp >> 8) & 0xFF), UInt8(timestamp & 0xFF)])
          sequence &+= 1
          timestamp &+= 3000
          _ = datagram.withUnsafeBytes { raw in
            withUnsafePointer(to: &address) {
              $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(descriptor, raw.baseAddress, raw.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
              }
            }
          }
          usleep(2_000)
        }
      }
    }
    thread.name = "loopback.rtp"
    thread.start()
  }

  deinit { stop() }

  func stop() {
    lock.lock(); stopped = true; lock.unlock()
  }

  private var isStopped: Bool {
    lock.lock(); defer { lock.unlock() }
    return stopped
  }
}

/// A real RTSP server for the one thing the in-process one cannot be: H.264
/// and AAC as a camera sends them, and, with a certificate, the same stream
/// over RTMPS. Needs `mediamtx` and `ffmpeg` on the machine, as a developer's
/// has; without them the test says so.
enum LocalMediaMTX {
  struct Ports {
    var rtsp: UInt16
    var rtmps: UInt16?
  }

  /// Starts `mediamtx` on the loopback and a publisher feeding `path`, and
  /// returns the RTSP port. `teardown` is given what stops them.
  static func publishing(path: String, teardown: (@escaping @Sendable () -> Void) -> Void) throws -> UInt16 {
    try start(path: path, certificate: nil, teardown: teardown).rtsp
  }

  /// The same, with the stream also served over RTMPS (and not over plain
  /// RTMP), under the given key and certificate.
  static func publishingWithRTMPS(
    path: String, key: URL, certificate: URL, teardown: (@escaping @Sendable () -> Void) -> Void
  ) throws -> (rtsp: UInt16, rtmps: UInt16) {
    let ports = try start(path: path, certificate: (key, certificate), teardown: teardown)
    return (ports.rtsp, ports.rtmps ?? 0)
  }

  private static func tool(_ name: String) -> String? {
    ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)"].first { FileManager.default.isExecutableFile(atPath: $0) }
  }

  private static func start(
    path: String, certificate: (key: URL, certificate: URL)?, teardown: (@escaping @Sendable () -> Void) -> Void
  ) throws -> Ports {
    guard let mediamtx = tool("mediamtx"), let ffmpeg = tool("ffmpeg") else {
      throw XCTSkip("no mediamtx and ffmpeg to serve a camera's stream")
    }
    let port = LoopbackTCPServer.unusedPort(type: SOCK_STREAM)
    let rtmpsPort = certificate == nil ? nil : LoopbackTCPServer.unusedPort(type: SOCK_STREAM)
    let rtmp: String
    if let certificate, let rtmpsPort {
      rtmp = """
        rtmp: yes
        rtmpAddress: 127.0.0.1:\(LoopbackTCPServer.unusedPort(type: SOCK_STREAM))
        rtmpEncryption: strict
        rtmpsAddress: 127.0.0.1:\(rtmpsPort)
        rtmpServerKey: \(certificate.key.path)
        rtmpServerCert: \(certificate.certificate.path)
        """
    } else {
      rtmp = "rtmp: no"
    }
    let config = FileManager.default.temporaryDirectory.appendingPathComponent("mediamtx-\(port).yml")
    try """
      logLevel: error
      rtsp: yes
      rtspAddress: 127.0.0.1:\(port)
      rtspTransports: [tcp]
      \(rtmp)
      hls: no
      webrtc: no
      srt: no
      api: no
      metrics: no
      pprof: no
      playback: no
      paths:
        all_others:
      """.write(to: config, atomically: true, encoding: .utf8)
    let server = Process()
    server.executableURL = URL(fileURLWithPath: mediamtx)
    server.arguments = [config.path]
    // It writes a certificate and key of its own to where it runs; not into the repository.
    server.currentDirectoryURL = FileManager.default.temporaryDirectory
    server.standardOutput = FileHandle.nullDevice
    server.standardError = FileHandle.nullDevice
    try server.run()
    let publisher = Process()
    publisher.executableURL = URL(fileURLWithPath: ffmpeg)
    publisher.arguments = [
      "-hide_banner", "-loglevel", "quiet", "-re", "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=25",
      "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000", "-c:v", "libx264", "-preset", "ultrafast",
      "-pix_fmt", "yuv420p", "-g", "25", "-c:a", "aac", "-t", "60", "-f", "rtsp", "-rtsp_transport", "tcp",
      "rtsp://127.0.0.1:\(port)/\(path)",
    ]
    publisher.standardOutput = FileHandle.nullDevice
    publisher.standardError = FileHandle.nullDevice
    // The server has to be listening before a publisher can come.
    for _ in 0..<50 {
      let probe = socket(AF_INET, SOCK_STREAM, 0)
      var address = LoopbackTCPServer.loopback(port: port)
      let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(probe, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
      }
      Darwin.close(probe)
      if connected == 0 { break }
      usleep(100_000)
    }
    try publisher.run()
    teardown {
      if publisher.isRunning { publisher.terminate() }
      if server.isRunning { server.terminate() }
      try? FileManager.default.removeItem(at: config)
    }
    return Ports(rtsp: port, rtmps: rtmpsPort)
  }

  /// A key and a certificate for 127.0.0.1, made with the system's `openssl`,
  /// in a folder that `teardown` removes; skips where there is none.
  static func selfSignedCertificate(
    teardown: (@escaping @Sendable () -> Void) -> Void
  ) throws -> (key: URL, certificate: URL) {
    let openssl = "/usr/bin/openssl"
    guard FileManager.default.isExecutableFile(atPath: openssl) else { throw XCTSkip("no openssl to make a certificate") }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("umbel-cert-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    teardown { try? FileManager.default.removeItem(at: folder) }
    let key = folder.appendingPathComponent("key.pem")
    let certificate = folder.appendingPathComponent("cert.pem")
    let maker = Process()
    maker.executableURL = URL(fileURLWithPath: openssl)
    maker.arguments = [
      "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key.path, "-out", certificate.path, "-days", "2",
      "-subj", "/CN=127.0.0.1", "-addext", "subjectAltName=IP:127.0.0.1",
      // What the system asks of a certificate for a TLS server: without the
      // server-authentication usage it is refused, however it is trusted.
      "-addext", "extendedKeyUsage=serverAuth", "-addext", "keyUsage=digitalSignature,keyEncipherment",
    ]
    maker.standardOutput = FileHandle.nullDevice
    maker.standardError = FileHandle.nullDevice
    try maker.run()
    maker.waitUntilExit()
    guard maker.terminationStatus == 0 else { throw XCTSkip("openssl could not make a certificate") }
    return (key, certificate)
  }
}
