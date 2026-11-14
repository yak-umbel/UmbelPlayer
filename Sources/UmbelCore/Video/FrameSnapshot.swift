import CoreGraphics
import Foundation
import Metal

/// Internal access to the last picture a renderer actually displayed.
internal protocol SnapshotFrameProviding: Actor {
  var snapshotFrame: VideoFrame? { get async }
  var snapshotDevice: SnapshotDevice? { get async }
}

/// The device a renderer draws with, handed to whoever captures its picture.
/// A Metal device may be used from any thread; newer SDKs declare it
/// Sendable, and this says so to the older ones that do not.
internal struct SnapshotDevice: @unchecked Sendable {
  let device: MTLDevice
}

internal enum FrameSnapshot {
  static func image(
    of frame: VideoFrame, size: CGSize, subtitles: [UmbelSubtitleBitmap], device: MTLDevice,
    adjustments: UmbelVideoAdjustments = .init(), diagnostics: UmbelPlaybackDiagnostics? = nil
  ) throws -> CGImage {
    guard !frame.presentationRoute.isSystem else {
      throw UmbelError.snapshotUnavailable(reason: "system display pixels have no verified capture")
    }
    let width = Int(size.width.rounded())
    let height = Int(size.height.rounded())
    guard width > 0, height > 0 else {
      throw UmbelError.snapshotUnavailable(reason: "the picture has no size")
    }
    let pipeline = try MetalPipeline(device: device)
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
    descriptor.usage = [.renderTarget, .shaderRead]
    descriptor.storageMode = .shared
    guard let target = device.makeTexture(descriptor: descriptor) else {
      throw UmbelError.videoRenderUnavailable(reason: "cannot allocate the snapshot texture")
    }
    let kind = VideoOutput.choose(for: frame.color.transfer, systemShowsHDR: false,
      bitDepth: frame.preferredWorkingBits, primaries: frame.color.workingPrimaries,
      permitsFloat32: pipeline.supports(.rgba32Float))
    let workingOutput = kind.pixelFormat == .bgra8Unorm ? kind.withFormat(.rgba16Float) : kind
    let workingDescriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: workingOutput.pixelFormat, width: width, height: height, mipmapped: false)
    workingDescriptor.usage = [.renderTarget, .shaderRead]
    workingDescriptor.storageMode = .private
    guard let working = device.makeTexture(descriptor: workingDescriptor) else {
      throw UmbelError.videoRenderUnavailable(reason: "cannot allocate the snapshot working texture")
    }
    var overlay = SubtitleOverlay()
    overlay.update(subtitles, device: device)
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = working
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].storeAction = .store
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
    guard let command = pipeline.commandQueue.makeCommandBuffer(),
          let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
      throw UmbelError.videoRenderUnavailable(reason: "cannot encode the snapshot")
    }
    do {
      let bounds = CGRect(x: 0, y: 0, width: width, height: height)
      try pipeline.encode(
        frame, output: workingOutput, subtitles: overlay,
        layout: PictureLayout(picture: bounds, visible: bounds),
        adjustments: adjustments, into: encoder)
    } catch {
      encoder.endEncoding()
      throw error
    }
    encoder.endEncoding()
    let exportPass = MTLRenderPassDescriptor()
    exportPass.colorAttachments[0].texture = target
    exportPass.colorAttachments[0].loadAction = .dontCare
    exportPass.colorAttachments[0].storeAction = .store
    guard let exportEncoder = command.makeRenderCommandEncoder(descriptor: exportPass) else {
      throw UmbelError.videoRenderUnavailable(reason: "cannot encode the snapshot color conversion")
    }
    pipeline.encodeExport(working, encoding: workingOutput.shaderCode, into: exportEncoder)
    exportEncoder.endEncoding()
    command.commit()
    command.waitUntilCompleted()
    guard command.status == .completed else {
      throw UmbelError.videoRenderUnavailable(reason: "snapshot rendering did not complete")
    }

    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    target.getBytes(&bytes, bytesPerRow: width * 4,
                    from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
    pipeline.releaseRetainedTextures()
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let provider = CGDataProvider(data: Data(bytes) as CFData),
          let image = CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
              | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    else {
      throw UmbelError.videoRenderUnavailable(reason: "cannot make the snapshot image")
    }
    var changes: [String] = []
    if (frame.sourcePixelDescription?.effectiveBits ?? frame.effectiveBitDepth ?? 0) > 8 { changes.append("bitDepthReduction") }
    if frame.color.isHDR { changes.append("dynamicRangeMapping") }
    if frame.color.workingPrimaries == .bt2020 { changes.append("gamutMapping") }
    diagnostics?.record("video_export", labels: ["stage": "snapshot", "outputFormat": "BGRA8",
      "changes": changes.joined(separator: ","), "reason": "exportFormatConstraint"])
    return image
  }
}
