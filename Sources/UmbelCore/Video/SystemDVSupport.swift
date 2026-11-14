import VideoToolbox

/// Whether the system can decode and show DV on this device: its hardware
/// decoder takes the DV codec type. Where it does, the system also maps the
/// picture to the display at hand; the simulator has no such decoder.
internal enum SystemDVSupport {
  static var isAvailable: Bool {
    VTIsHardwareDecodeSupported(kCMVideoCodecType_DolbyVisionHEVC)
  }
}

/// A renderer that can hand pictures to the system to decode and show: one
/// with a sample buffer display layer behind it.
internal protocol SystemDecodedVideoShowing: VideoRenderer {
  /// Whether the system here can show DV without a base layer of its own.
  var showsSystemDecodedDV: Bool { get async }
}

internal protocol SystemPixelVideoShowing: VideoRenderer {
  var showsP84SystemPixels: Bool { get async }
  var showsP81SystemPixels: Bool { get async }
  var showsP5SystemPixels: Bool { get async }
}

extension SystemPixelVideoShowing {
  /// A renderer that says nothing about P8.1 keeps its pictures on the base layer.
  var showsP81SystemPixels: Bool { get async { false } }
  var showsP5SystemPixels: Bool { get async { false } }
}

extension SampleBufferVideoRenderer: SystemPixelVideoShowing {
  var showsP5SystemPixels: Bool {
    // Older systems cannot require a hardware decoder for native P5 pixels.
    // Keep their existing compressed system display path.
    if #available(iOS 17, tvOS 17, macCatalyst 17, *) {
      return showsP81SystemPixels
    }
    return false
  }
  var showsP84SystemPixels: Bool {
    #if targetEnvironment(simulator)
    return false
    #else
    return SystemDVSupport.isAvailable
    #endif
  }

  /// The same condition as P8.4, kept as a property of its own: the system decodes DV in hardware
  /// and maps the picture to the display, as it does for the system player's own pictures.
  var showsP81SystemPixels: Bool {
    #if targetEnvironment(simulator)
    return false
    #else
    return showsSystemDecodedDV
    #endif
  }
}

extension SwitchingVideoRenderer: SystemPixelVideoShowing {
  var showsP5SystemPixels: Bool {
    get async { await p5SystemPixelCapability }
  }
  var showsP84SystemPixels: Bool {
    get async { await systemPixelCapability }
  }
  var showsP81SystemPixels: Bool {
    get async { await p81SystemPixelCapability }
  }
}

extension SampleBufferVideoRenderer {
  /// Whether the system on this device can decode and show DV without a
  /// base layer of its own (profile 5): a host may say so, or offer such
  /// films only where it can.
  public static var systemCanShowDV: Bool { SystemDVSupport.isAvailable }
}
