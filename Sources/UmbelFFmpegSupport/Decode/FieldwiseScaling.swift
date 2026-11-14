import CoreVideo
import FFmpeg
import Foundation

/// How a frame is handed to swscale: whole, or one field at a time.
///
/// Turning 4:2:2, 4:4:4 or 4:1:1 into 4:2:0 halves the chroma rows, each
/// result row made of two neighbours. In an interlaced frame those two belong
/// to different fields, so a whole-frame conversion averages the colours of two
/// moments, and the smear stays through everything after it. The chroma rows
/// of an interlaced 4:2:0 picture belong to the fields in turn, the even ones
/// to the top field and the odd ones to the bottom — which is what a
/// conversion of each field on its own, written into every other row, gives.
internal enum FieldwiseScaling {
  /// A call of swscale: its planes' addresses and strides, and how many rows
  /// of the source it takes.
  struct Pass {
    let sources: [UnsafePointer<UInt8>?]
    let sourceStrides: [Int32]
    let destinations: [UnsafeMutablePointer<UInt8>?]
    let destinationStrides: [Int32]
    let rows: Int32
  }

  /// Whether `frame` is converted a field at a time: it is a woven pair of
  /// fields, of an even number of rows, and its chroma is not already halved
  /// in height — then there is nothing to mix.
  static func applies(
    to frame: UnsafeMutablePointer<AVFrame>, source: AVPixelFormat, height: Int32, codecName: String
  ) -> Bool {
    guard height % 2 == 0,
          FFmpegVideoDecoder.reportsInterlaced(
            flagged: frame.pointee.flags & AV_FRAME_FLAG_INTERLACED != 0, codecName: codecName),
          let description = av_pix_fmt_desc_get(source) else { return false }
    return description.pointee.log2_chroma_h == 0
  }

  /// The calls that convert `frame` into the two planes of `buffer`: one for
  /// the whole picture, or two, each for the rows of one field.
  static func passes(
    of frame: UnsafeMutablePointer<AVFrame>, into buffer: CVPixelBuffer, height: Int32, byField: Bool
  ) -> [Pass] {
    let sources: [UnsafeMutablePointer<UInt8>?] = [
      frame.pointee.data.0, frame.pointee.data.1, frame.pointee.data.2, frame.pointee.data.3,
    ]
    let sourceStrides: [Int32] = [
      frame.pointee.linesize.0, frame.pointee.linesize.1,
      frame.pointee.linesize.2, frame.pointee.linesize.3,
    ]
    let planar = CVPixelBufferGetPlaneCount(buffer) > 0
    let destinations: [UnsafeMutablePointer<UInt8>?] = planar ? (0..<2).map {
      CVPixelBufferGetBaseAddressOfPlane(buffer, $0)?.assumingMemoryBound(to: UInt8.self)
    } + [nil, nil] : [CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self), nil, nil, nil]
    let destinationStrides: [Int32] = planar ? (0..<2).map {
      Int32(CVPixelBufferGetBytesPerRowOfPlane(buffer, $0))
    } + [0, 0] : [Int32(CVPixelBufferGetBytesPerRow(buffer)), 0, 0, 0]

    guard byField else {
      return [Pass(
        sources: sources.map { $0.map { UnsafePointer($0) } }, sourceStrides: sourceStrides,
        destinations: destinations, destinationStrides: destinationStrides, rows: height)]
    }
    // A field is every other row: start `field` rows down, step two rows.
    return (0..<2).map { field in
      Pass(
        sources: zip(sources, sourceStrides).map { plane, stride in
          plane.map { UnsafePointer($0 + field * Int(stride)) }
        },
        sourceStrides: sourceStrides.map { $0 * 2 },
        destinations: zip(destinations, destinationStrides).map { plane, stride in
          plane.map { $0 + field * Int(stride) }
        },
        destinationStrides: destinationStrides.map { $0 * 2 },
        rows: height / 2)
    }
  }
}
