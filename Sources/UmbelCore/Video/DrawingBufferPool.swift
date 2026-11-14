import CoreVideo

/// The buffers a renderer draws into: one pool, of one size and format.
internal struct DrawingBufferPool {
  private var pool: (pool: CVPixelBufferPool, width: Int, height: Int, format: OSType)?

  /// The format of the pool in use; nil before the first buffer, and after a reset.
  var format: OSType? { pool?.format }

  /// Lets the pool go; the next buffer comes from a new one.
  mutating func reset() { pool = nil }

  /// A buffer from a pool of this size, made again when the size changes.
  /// The layer keeps what it shows; the pool hands out only buffers let go.
  mutating func buffer(width: Int, height: Int, format: OSType) throws -> CVPixelBuffer {
    if pool == nil || pool?.width != width || pool?.height != height || pool?.format != format {
      let attributes: [CFString: Any] = [
        kCVPixelBufferPixelFormatTypeKey: format,
        kCVPixelBufferWidthKey: width,
        kCVPixelBufferHeightKey: height,
        kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any](),
        kCVPixelBufferMetalCompatibilityKey: true,
      ]
      var made: CVPixelBufferPool?
      CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &made)
      guard let made else {
        throw UmbelError.videoRenderUnavailable(reason: "cannot create a buffer pool")
      }
      pool = (made, width, height, format)
    }
    var buffer: CVPixelBuffer?
    guard let pool, CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool.pool, &buffer)
            == kCVReturnSuccess, let buffer else {
      throw UmbelError.videoRenderUnavailable(reason: "no buffer to draw into")
    }
    return buffer
  }
}
