import FFmpeg
import Foundation

public enum FFmpegResamplerError: Error, Sendable {
  case allocationFailed
  case initialisationFailed(Int32)
  case conversionFailed(Int32)
  case unsupportedInputFormat(Int32)
}

/// Turns decoders' output into planar float32 in the format sound is played
/// in: the sample format always, and the rate and channel count where they
/// differ.
///
/// The output builds its buffers in the format it was prepared in, so every
/// frame has to arrive in it; content whose format changes midway — an ad
/// spliced into a stream — is converted here, not there.
public final class FFmpegResampler {
  /// Input sample formats: only those decoders actually put out.
  public enum InputFormat: Sendable {
    case signedInt16Interleaved
    case signedInt16Planar
    /// TrueHD and MLP, and PCM of 24 or 32 bits.
    case signedInt32Interleaved
    case signedInt32Planar
    case float32Interleaved
    case float32Planar
    case double64Planar

    fileprivate var rawValue: AVSampleFormat {
      switch self {
      case .signedInt16Interleaved: return AV_SAMPLE_FMT_S16
      case .signedInt16Planar: return AV_SAMPLE_FMT_S16P
      case .signedInt32Interleaved: return AV_SAMPLE_FMT_S32
      case .signedInt32Planar: return AV_SAMPLE_FMT_S32P
      case .float32Interleaved: return AV_SAMPLE_FMT_FLT
      case .float32Planar: return AV_SAMPLE_FMT_FLTP
      case .double64Planar: return AV_SAMPLE_FMT_DBLP
      }
    }

    /// From FFmpeg's raw enumeration value; nil if not one of these.
    public static func from(rawValue: Int32) -> InputFormat? {
      switch AVSampleFormat(rawValue) {
      case AV_SAMPLE_FMT_S16: return .signedInt16Interleaved
      case AV_SAMPLE_FMT_S16P: return .signedInt16Planar
      case AV_SAMPLE_FMT_S32: return .signedInt32Interleaved
      case AV_SAMPLE_FMT_S32P: return .signedInt32Planar
      case AV_SAMPLE_FMT_FLT: return .float32Interleaved
      case AV_SAMPLE_FMT_FLTP: return .float32Planar
      case AV_SAMPLE_FMT_DBLP: return .double64Planar
      default: return nil
      }
    }

    /// Planar formats have a plane per channel; interleaved ones a single one.
    ///
    /// Public because the decoder decides by it how many planes to pass to
    /// the resampler — its one user is in another file.
    public var isPlanarLayout: Bool {
      switch self {
      case .signedInt16Interleaved, .signedInt32Interleaved, .float32Interleaved: return false
      case .signedInt16Planar, .signedInt32Planar, .float32Planar, .double64Planar: return true
      }
    }
  }

  private let outputChannelCount: Int
  private var context: OpaquePointer?

  /// Converts the sample format only.
  public convenience init(inputFormat: InputFormat, channelCount: Int, sampleRate: Int32) throws {
    try self.init(
      inputFormat: inputFormat, inputChannelCount: channelCount, inputSampleRate: sampleRate,
      outputChannelCount: channelCount, outputSampleRate: sampleRate)
  }

  public init(
    inputFormat: InputFormat, inputChannelCount: Int, inputSampleRate: Int32,
    outputChannelCount: Int, outputSampleRate: Int32
  ) throws {
    self.outputChannelCount = outputChannelCount

    var inLayout = AVChannelLayout()
    var outLayout = AVChannelLayout()
    av_channel_layout_default(&inLayout, Int32(inputChannelCount))
    av_channel_layout_default(&outLayout, Int32(outputChannelCount))
    defer {
      av_channel_layout_uninit(&inLayout)
      av_channel_layout_uninit(&outLayout)
    }

    var created: OpaquePointer?
    let result = swr_alloc_set_opts2(
      &created,
      &outLayout, AV_SAMPLE_FMT_FLTP, outputSampleRate,
      &inLayout, inputFormat.rawValue, inputSampleRate,
      0, nil
    )
    guard result == 0, let created else {
      throw FFmpegResamplerError.allocationFailed
    }

    let initResult = swr_init(created)
    if initResult < 0 {
      var mutable: OpaquePointer? = created
      swr_free(&mutable)
      throw FFmpegResamplerError.initialisationFailed(initResult)
    }
    self.context = created
  }

  deinit {
    release()
  }

  /// Converts input planes to planar float32 in the output's format.
  ///
  /// `planes` needs one element for an interleaved format, one per channel
  /// for a planar one. Converting the rate, as many frames need not come
  /// out as went in: the count out is `result.count / outputChannelCount`.
  public func convert(
    planes: [UnsafeMutableRawPointer],
    frameCount: Int
  ) throws -> [Float] {
    guard frameCount > 0 else { return [] }
    guard let context else { throw FFmpegResamplerError.allocationFailed }

    let capacity = Int(swr_get_out_samples(context, Int32(frameCount)))
    guard capacity > 0 else { return [] }
    let channels = outputChannelCount
    var output = [Float](repeating: 0, count: capacity * channels)
    var inputPointers: [UnsafePointer<UInt8>?] = planes.map {
      UnsafeRawPointer($0).assumingMemoryBound(to: UInt8.self)
    }

    let produced: Int32 = output.withUnsafeMutableBufferPointer { buffer -> Int32 in
      guard let base = buffer.baseAddress else { return 0 }
      // Planar: each channel starts `capacity` floats after the last.
      var outputPointers: [UnsafeMutablePointer<UInt8>?] = (0..<channels).map { channel in
        UnsafeMutableRawPointer(base + channel * capacity).assumingMemoryBound(to: UInt8.self)
      }
      return outputPointers.withUnsafeMutableBufferPointer { outBuf in
        inputPointers.withUnsafeMutableBufferPointer { inBuf in
          swr_convert(
            context,
            outBuf.baseAddress, Int32(capacity),
            inBuf.baseAddress, Int32(frameCount)
          )
        }
      }
    }

    if produced < 0 { throw FFmpegResamplerError.conversionFailed(produced) }
    let count = Int(produced)
    guard count < capacity else { return output }
    // Fewer than room was made for: close each channel up behind the last.
    var compact: [Float] = []
    compact.reserveCapacity(count * channels)
    for channel in 0..<channels {
      let start = channel * capacity
      compact.append(contentsOf: output[start..<(start + count)])
    }
    return compact
  }

  /// Releases the context beneath. Can be called again.
  public func release() {
    guard context != nil else { return }
    // Has to stay optional: swr_free takes a pointer to an optional pointer.
    var mutable: OpaquePointer? = context
    context = nil
    swr_free(&mutable)
  }
}

extension FFmpegResampler {
  /// The channel mask of FFmpeg's default layout for a channel count — the
  /// order this resampler delivers channels in. FFmpeg's masks follow the
  /// WAVE convention bit for bit (front left, front right, centre, LFE, back
  /// pair, …), and so do CoreAudio's channel bitmaps. Nil when the default
  /// layout is not described by a mask.
  public static func defaultChannelMask(channelCount: Int) -> UInt64? {
    var layout = AVChannelLayout()
    av_channel_layout_default(&layout, Int32(channelCount))
    defer { av_channel_layout_uninit(&layout) }
    guard layout.order == AV_CHANNEL_ORDER_NATIVE else { return nil }
    return layout.u.mask
  }
}
