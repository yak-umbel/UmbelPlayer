import CoreMedia
import Foundation
import UmbelFFmpegSupport

/// A sound track as fragmented MP4: the initialization segment FFmpeg's
/// writer makes, and fragments written here, each carrying its own time.
///
/// Fragments are written here rather than by that writer so that one can
/// start anywhere: after a seek, the segment asked for next may be far from
/// the last one written, and its time must be where it stands in the film.
internal struct FragmentedAudioTrack: Sendable {
  let initSegment: Data
  /// The track the initialization segment declares; fragments name it.
  let trackID: UInt32
  /// Its time scale: fragment times and durations are in these units.
  let timescale: UInt32
  /// Added to every time written. A fragment's time cannot be negative, and
  /// encoders start sound a few milliseconds before 0 (E-AC-3: 5 ms), so the
  /// whole track is moved that much later; the system player's time is the
  /// film's plus this.
  let shift: CMTime

  /// The initialization segment from the stream's parameters and a few
  /// leading packets, which the writer parses for the stream description.
  static func make(
    parameters: FFmpegCodecParameters, leading: [DemuxPacket], shift: CMTime = .zero
  ) throws -> FragmentedAudioTrack {
    let initSegment = try FFmpegInitSegment.make(parameters: parameters, packets: leading.map(microsecondPacket))
    guard let header = MP4Box.find(["moov", "trak", "tkhd"], in: initSegment),
          let media = MP4Box.find(["moov", "trak", "mdia", "mdhd"], in: initSegment) else {
      throw FFmpegInitSegment.Failure.noMovieBox
    }
    // Version 0 or 1 decides how wide the times before these fields are.
    let wide = initSegment[header.lowerBound] == 1
    let trackID = MP4Box.readUInt32(initSegment, at: header.lowerBound + (wide ? 20 : 12))
    let mediaWide = initSegment[media.lowerBound] == 1
    let timescale = MP4Box.readUInt32(initSegment, at: media.lowerBound + (mediaWide ? 20 : 12))
    return FragmentedAudioTrack(initSegment: initSegment, trackID: trackID, timescale: timescale, shift: shift)
  }

  /// `moof` and `mdat` for `packets`, which follow one another. The first
  /// packet's time, shifted, is the fragment's.
  func fragment(sequence: UInt32, packets: [DemuxPacket]) -> Data {
    let scale = Double(timescale)
    let start = packets.first.map {
      UInt64(max(0, (($0.presentationTime + shift).seconds * scale).rounded()))
    } ?? 0
    let durations = sampleDurations(packets, scale: scale)

    var header = Data()
    header.appendUInt32(sequence)
    var tfdt = Data()
    tfdt.appendUInt64(start)
    var track = Data()
    track.appendUInt32(trackID)
    var runs = Data()
    runs.appendUInt32(UInt32(packets.count))
    runs.appendUInt32(0) // data offset, set below
    for (packet, duration) in zip(packets, durations) {
      runs.appendUInt32(duration)
      runs.appendUInt32(UInt32(packet.data.count))
    }
    // Offsets count from the start of moof: the base is the moof itself.
    let movie = { (runs: Data) in
      MP4Box.make("moof", MP4Box.makeFull("mfhd", version: 0, flags: 0, header) + MP4Box.make("traf",
        MP4Box.makeFull("tfhd", version: 0, flags: 0x02_0000, track)
          + MP4Box.makeFull("tfdt", version: 1, flags: 0, tfdt)
          + MP4Box.makeFull("trun", version: 0, flags: 0x00_0301, runs)))
    }
    let offset = UInt32(movie(runs).count + 8)
    runs.replaceSubrange(4..<8, with: [UInt8(offset >> 24), UInt8(offset >> 16 & 0xFF), UInt8(offset >> 8 & 0xFF), UInt8(offset & 0xFF)])
    return movie(runs) + MP4Box.make("mdat", packets.reduce(Data()) { $0 + $1.data })
  }

  /// Each packet's duration in the time scale: its own when it has one, the
  /// gap to the next otherwise, the last known for the last.
  private func sampleDurations(_ packets: [DemuxPacket], scale: Double) -> [UInt32] {
    var known: UInt32 = 0
    return packets.enumerated().map { index, packet in
      if packet.duration.isValid, packet.duration.seconds > 0 {
        known = UInt32((packet.duration.seconds * scale).rounded())
      } else if index + 1 < packets.count, packets[index + 1].presentationTime.isValid, packet.presentationTime.isValid {
        known = UInt32(((packets[index + 1].presentationTime - packet.presentationTime).seconds * scale).rounded())
      }
      return known
    }
  }

  private static func microsecondPacket(_ packet: DemuxPacket) -> FFmpegPacket {
    func ticks(_ time: CMTime) -> Int64 {
      guard time.isValid, time.isNumeric else { return FFmpegPacket.noTimestamp }
      return Int64((time.seconds * 1_000_000).rounded())
    }
    return FFmpegPacket(
      streamIndex: 0, data: packet.data, pts: ticks(packet.presentationTime), dts: ticks(packet.decodeTime),
      duration: packet.duration.isValid ? Int64((packet.duration.seconds * 1_000_000).rounded()) : 0,
      timeBaseNum: 1, timeBaseDen: 1_000_000, isKeyframe: packet.isKeyframe)
  }
}
