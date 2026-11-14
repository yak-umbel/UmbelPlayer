import Foundation

/// The segments of one run, one after another, as a single stream in order:
/// what the demuxer for that run reads.
///
/// A run of fragmented MP4 starts with its initialisation segment, which
/// the segments after it need to be read at all.
///
/// It ends at the run's end — the next run gets a demuxer of its own — or
/// at a segment that cannot be had, which it records in `failure` for the
/// caller to decide on. The sources beneath do their own retrying; a failure
/// here has outlasted it.
internal actor HLSSegmentStream: UmbelStreamingSource {
  struct Location: Equatable, Sendable {
    let index: Int
    let start: Double
    let duration: Double
  }

  private struct Delivered {
    let location: Location
    let start: Int64
    var end: Int64
  }

  struct Failure: Sendable {
    let segmentIndex: Int
    let error: Error
  }

  private struct Open {
    let source: any UmbelRandomAccessSource
    var position: Int64
    let end: Int64?
    let decryptor: HLSDecryptor?
    /// The initialisation segment, read before the segment `nextIndex`.
    let isMap: Bool
    let location: Location?
  }

  private let segments: any HLSSegmentSource
  private let open: @Sendable (URL) async -> any UmbelRandomAccessSource
  private let keys: HLSKeys
  private let diagnostics: UmbelPlaybackDiagnostics?
  /// The run being read: the first segment's, once it is known.
  private var run: Int?
  private var current: Open?
  private var isInvalidated = false
  private var logicalPosition: Int64 = 0
  private var delivered: [Delivered] = []

  /// The segment to read next; once the run is over, where the next begins.
  private(set) var nextIndex: Int
  private(set) var completedSegments = 0
  private(set) var failure: Failure?

  init(
    segments: any HLSSegmentSource, startingAt index: Int,
    open: @escaping @Sendable (URL) async -> any UmbelRandomAccessSource,
    keys: HLSKeys? = nil,
    diagnostics: UmbelPlaybackDiagnostics? = nil
  ) {
    self.segments = segments
    self.open = open
    self.keys = keys ?? HLSKeys(open: open)
    self.diagnostics = diagnostics
    self.nextIndex = index
  }

  var contentLength: Int64? { nil }

  /// Input can be prefetched far beyond the packet currently returned.
  func segment(containing position: Int64) -> Location? {
    var low = 0
    var high = delivered.count
    while low < high {
      let middle = (low + high) / 2
      if delivered[middle].end <= position { low = middle + 1 } else { high = middle }
    }
    guard low < delivered.count, position >= delivered[low].start else { return nil }
    return delivered[low].location
  }

  func readNext(maxLength: Int) async throws -> Data {
    while !isInvalidated {
      if current == nil {
        guard failure == nil else { return Data() }
        let next: HLSMediaPlaylist.Segment?
        do {
          // A live list waits here for a segment yet to come.
          next = try await segments.segment(at: nextIndex)
        } catch {
          if isInvalidated { break }
          failure = Failure(segmentIndex: nextIndex, error: error)
          return Data()
        }
        guard let segment = next, segment.run == run ?? segment.run else { return Data() }
        if run == nil {
          run = segment.run
          if let map = segment.map {
            current = Open(
              source: await open(map.url), position: map.byteRange?.lowerBound ?? 0,
              end: map.byteRange?.upperBound, decryptor: nil, isMap: true, location: nil)
            continue
          }
        }
        var decryptor: HLSDecryptor?
        if let key = segment.key {
          do {
            decryptor = try HLSDecryptor(
              key: try await keys.key(at: key.url),
              iv: key.iv ?? HLSDecryptor.iv(forSequence: segment.sequence))
          } catch {
            if isInvalidated { break }
            failure = Failure(segmentIndex: nextIndex, error: error)
            return Data()
          }
        }
        diagnostics?.record("hls_segment_open", values: [
          "segment": Double(nextIndex), "run": Double(segment.run), "sequence": Double(segment.sequence),
          "start": segment.start, "duration": segment.duration])
        current = Open(
          source: await open(segment.url),
          position: segment.byteRange?.lowerBound ?? 0,
          end: segment.byteRange?.upperBound, decryptor: decryptor, isMap: false,
          location: Location(index: nextIndex, start: segment.start, duration: segment.duration))
      }
      guard var reading = current else { continue }
      let wanted = reading.end.map { min(Int64(maxLength), $0 - reading.position) } ?? Int64(maxLength)
      if wanted <= 0 {
        await finishSegment()
        continue
      }
      let data: Data
      do {
        data = try await reading.source.read(offset: reading.position, maxLength: Int(wanted))
      } catch {
        if isInvalidated { break }
        failure = Failure(segmentIndex: nextIndex, error: error)
        await reading.source.invalidate()
        current = nil
        return Data()
      }
      if data.isEmpty {
        let tail = try? reading.decryptor?.finish()
        await finishSegment()
        if let tail, !tail.isEmpty { return deliver(tail, from: reading.location) }
        continue
      }
      reading.position += Int64(data.count)
      current = reading
      guard let decryptor = reading.decryptor else { return deliver(data, from: reading.location) }
      do {
        let plain = try decryptor.update(data)
        if plain.isEmpty { continue }
        return deliver(plain, from: reading.location)
      } catch {
        failure = Failure(segmentIndex: nextIndex, error: error)
        await reading.source.invalidate()
        current = nil
        return Data()
      }
    }
    throw UmbelError.interrupted
  }

  func invalidate() async {
    isInvalidated = true
    await current?.source.invalidate()
    current = nil
  }

  private func deliver(_ data: Data, from location: Location?) -> Data {
    let end = logicalPosition + Int64(data.count)
    if let location {
      if delivered.last?.location == location {
        delivered[delivered.count - 1].end = end
      } else {
        delivered.append(Delivered(location: location, start: logicalPosition, end: end))
      }
    }
    logicalPosition = end
    return data
  }

  private func finishSegment() async {
    let wasMap = current?.isMap ?? false
    await current?.source.invalidate()
    current = nil
    guard !wasMap else { return }
    nextIndex += 1
    completedSegments += 1
  }
}
