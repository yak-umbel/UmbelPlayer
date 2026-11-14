import UmbelFFmpegSupport

/// Serial actor owner of a decoder engine, returning each packet's results
/// before accepting the next packet.
internal actor VideoDecodeSession {
  private let engine: VideoDecodeEngine

  internal init(
    decoder: FFmpegVideoDecoder, baseLayer: UmbelDVBaseLayer? = nil, deinterlacer: VideoDeinterlacer? = nil
  ) {
    engine = VideoDecodeEngine(decoder: decoder, baseLayer: baseLayer, deinterlacer: deinterlacer)
  }

  internal var rebuildCount: Int { engine.rebuildCount }
  internal var rejectedPacketCount: Int { engine.rejectedPacketCount }
  internal var decodedFrameCount: Int { engine.decodedFrameCount }
  internal var decodingCounts: UmbelDecodingCounts? { engine.decodingCounts }
  internal var isHardwareAccelerated: Bool { engine.isHardwareAccelerated }
  internal var decoderStatus: UmbelVideoDecoderStatus? { engine.decoderStatus }
  internal var skipsNonReference: Bool { engine.skipsNonReference }

  internal func decode(_ packet: DemuxPacket, hidden: Bool = false) throws -> [VideoFrame] {
    try engine.decode(packet, hidden: hidden)
  }
  internal func drain() throws -> [VideoFrame] { try engine.drain() }
  internal func flush() { engine.flush() }
  internal func renew() throws { try engine.renew() }
  internal func close() { engine.close() }
  internal func setSkipsNonReference(_ skips: Bool) { engine.setSkipsNonReference(skips) }
}
