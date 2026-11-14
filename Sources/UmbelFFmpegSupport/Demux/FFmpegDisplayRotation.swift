import FFmpeg
import Foundation

/// How far a stream's display matrix says its picture is turned to be shown
/// upright.
///
/// A container writes it beside a stream — an MP4's track header, a
/// Matroska display matrix — and FFmpeg keeps it in the stream's codec
/// parameters as side data. This reduces it to one of the four turns a
/// picture can be shown at, counted clockwise.
public enum FFmpegDisplayRotation {
  /// The clockwise degrees to turn the stored picture by: 0, 90, 180 or 270.
  ///
  /// A matrix that flips the picture, turns it by anything but a right angle
  /// (to within a degree, for fixed point's rounding), or is no matrix at
  /// all gives 0: such a picture is shown as stored. The flip is looked for
  /// first, since the angle alone reads a horizontal flip as a half turn.
  public static func clockwiseDegrees(matrix: [Int32]) -> Int32 {
    guard matrix.count == 9 else { return 0 }
    // The upper left 2×2 block carries turn and flip, in 16.16 fixed point:
    // a negative determinant is a flip.
    let determinant = Int64(matrix[0]) * Int64(matrix[4]) - Int64(matrix[1]) * Int64(matrix[3])
    guard determinant > 0 else { return 0 }
    // FFmpeg counts counter-clockwise.
    let counterClockwise = matrix.withUnsafeBufferPointer { av_display_rotation_get($0.baseAddress) }
    guard counterClockwise.isFinite else { return 0 }
    let quarterTurns = (counterClockwise / 90).rounded()
    guard abs(counterClockwise - quarterTurns * 90) <= 1 else { return 0 }
    let clockwise = ((-Int(quarterTurns) % 4) + 4) % 4
    return Int32(clockwise * 90)
  }
}

extension FFmpegDisplayRotation {
  /// From a stream's codec parameters; 0 when they carry no matrix.
  internal static func clockwiseDegrees(
    codecParameters parameters: UnsafePointer<AVCodecParameters>
  ) -> Int32 {
    guard let side = av_packet_side_data_get(
            parameters.pointee.coded_side_data, parameters.pointee.nb_coded_side_data,
            AV_PKT_DATA_DISPLAYMATRIX),
          side.pointee.size >= 9 * MemoryLayout<Int32>.size,
          let bytes = side.pointee.data else { return 0 }
    let matrix = (0..<9).map {
      UnsafeRawPointer(bytes).loadUnaligned(
        fromByteOffset: $0 * MemoryLayout<Int32>.size, as: Int32.self)
    }
    return clockwiseDegrees(matrix: matrix)
  }
}
