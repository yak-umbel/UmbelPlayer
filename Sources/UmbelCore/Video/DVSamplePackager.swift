import CoreMedia
import Foundation
import UmbelFFmpegSupport

/// DV profile 5 packaged for the system: a description it takes, and the
/// packets as samples it decodes and shows itself.
///
/// The system takes DV typed dvh1, its parameter sets in the description.
/// Files often carry it otherwise — dvhe, the parameter sets in the stream
/// and none in the hvcC — and shown so, nothing appears. The description is
/// made here: from the container's hvcC when it has the parameter sets,
/// else by the system from parameter sets found in the stream; either way
/// with the DV record beside it. The picture data itself is not touched
/// beyond its NAL unit framing.
///
/// Streams put their parameter sets where they like: with the keyframe, or
/// at the tail of the sample before it, or only at the very start. So they
/// are taken from any packet, kept across seeks, and new ones apply from the
/// next keyframe; the route primes them from the stream's start when it can.
internal struct DVSamplePackager {
  private let record: FFmpegDOVIConfiguration
  private let width: Int
  private let height: Int
  /// The length size of the container's samples; nil for Annex B, as a
  /// transport stream gives them.
  private let inputLengthSize: Int?
  /// The description in use; nil until one can be made.
  private(set) var description: CMVideoFormatDescription?
  /// Its parameter sets, to tell when the stream brings others.
  private var sets: HEVCParameterSets.Sets?
  /// Others seen since, for the next keyframe.
  private var pending: HEVCParameterSets.Sets?
  /// The description is the container's hvcC: samples keep their framing.
  private var usesContainerRecord = false
  private var sawKeyframe = false
  /// Keyframes come by with no parameter sets to decode them against: at
  /// `keyframesToWait` the stream has none to give, and fails with that.
  private var keyframesWithout = 0
  private static let keyframesToWait = 3

  init(
    extradata: Data, record: FFmpegDOVIConfiguration, width: Int, height: Int,
    primed: HEVCParameterSets.Sets? = nil
  ) throws {
    self.record = record
    self.width = width
    self.height = height
    // An hvcC record starts with its version, 1; anything else is Annex B.
    guard extradata.first == 1, extradata.count >= 23 else {
      inputLengthSize = nil
      return
    }
    inputLengthSize = HEVCParameterSets.lengthSize(ofHvcC: extradata)
    if let found = HEVCParameterSets.arrays(inHvcC: extradata) {
      description = try Self.description(hvcC: extradata, record: record, width: width, height: height)
      sets = found
      usesContainerRecord = true
    } else if let primed {
      description = try Self.description(sets: primed, record: record)
      sets = primed
    }
  }

  /// A packet as a sample: nil before the first keyframe, which nothing
  /// could be decoded against. Not a keyframe → marked not sync; `hidden` →
  /// decoded but not shown.
  mutating func sample(
    data: Data, presentationTime: CMTime, decodeTime: CMTime, isKeyframe: Bool, hidden: Bool
  ) throws -> CMSampleBuffer? {
    let units = HEVCParameterSets.units(in: data, lengthSize: inputLengthSize)
    if let found = HEVCParameterSets.parameterSets(in: units), !Self.same(found, sets) {
      pending = found
    }
    // New parameter sets start with a keyframe: the pictures before it were
    // encoded with the old ones.
    if isKeyframe, let next = pending {
      description = try Self.description(sets: next, record: record)
      sets = next
      pending = nil
      usesContainerRecord = false
    }
    if isKeyframe {
      sawKeyframe = true
      if description == nil {
        keyframesWithout += 1
        guard keyframesWithout < Self.keyframesToWait else {
          throw UmbelError.unsupportedCodec("DV P\(record.profile): no parameter sets in the stream to decode it with")
        }
      }
    }
    guard sawKeyframe, let description, !units.isEmpty else { return nil }
    let payload = usesContainerRecord ? data : HEVCParameterSets.lengthPrefixed(units)
    return try Self.sample(
      payload, description: description, presentationTime: presentationTime,
      decodeTime: decodeTime, isKeyframe: isKeyframe, hidden: hidden)
  }

  /// After a seek: nothing is sent until a keyframe comes. The parameter
  /// sets stay: the keyframe landed on need not carry them.
  mutating func reset() {
    sawKeyframe = false
  }

  // ── Descriptions ────────────────────────────────────

  private static func same(_ a: HEVCParameterSets.Sets, _ b: HEVCParameterSets.Sets?) -> Bool {
    guard let b else { return false }
    return a.vps == b.vps && a.sps == b.sps && a.pps == b.pps
  }

  /// The container's own hvcC, the record beside it.
  private static func description(
    hvcC: Data, record: FFmpegDOVIConfiguration, width: Int, height: Int
  ) throws -> CMVideoFormatDescription {
    let atoms: [String: Any] = ["hvcC": hvcC, record.boxType: record.boxPayload]
    return try dvh1(
      extensions: [kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String: atoms],
      width: Int32(width), height: Int32(height))
  }

  /// The system's hvcC for these parameter sets, the record beside it.
  private static func description(
    sets: HEVCParameterSets.Sets, record: FFmpegDOVIConfiguration
  ) throws -> CMVideoFormatDescription {
    let all = [sets.vps, sets.sps, sets.pps]
    let joined = all.reduce(Data(), +)
    let hevc: CMFormatDescription? = joined.withUnsafeBytes { raw in
      guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
      let pointers = [base, base + sets.vps.count, base + sets.vps.count + sets.sps.count]
      var made: CMFormatDescription?
      let status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
        allocator: kCFAllocatorDefault, parameterSetCount: 3, parameterSetPointers: pointers,
        parameterSetSizes: all.map(\.count), nalUnitHeaderLength: 4, extensions: nil,
        formatDescriptionOut: &made)
      return status == noErr ? made : nil
    }
    guard let hevc else {
      throw UmbelError.unsupportedCodec("DV P\(record.profile): parameter sets the system does not take")
    }
    var extensions = (CMFormatDescriptionGetExtensions(hevc) as? [String: Any]) ?? [:]
    let key = kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String
    var atoms = (extensions[key] as? [String: Any]) ?? [:]
    atoms[record.boxType] = record.boxPayload
    extensions[key] = atoms
    let size = CMVideoFormatDescriptionGetDimensions(hevc)
    return try dvh1(extensions: extensions, width: size.width, height: size.height)
  }

  private static func dvh1(
    extensions: [String: Any], width: Int32, height: Int32
  ) throws -> CMVideoFormatDescription {
    var made: CMVideoFormatDescription?
    CMVideoFormatDescriptionCreate(
      allocator: kCFAllocatorDefault, codecType: kCMVideoCodecType_DolbyVisionHEVC,
      width: width, height: height, extensions: extensions as CFDictionary,
      formatDescriptionOut: &made)
    guard let made else { throw UmbelError.unsupportedCodec("DV: no description the system takes") }
    return made
  }

  // ── Samples ─────────────────────────────────────────

  private static func sample(
    _ payload: Data, description: CMVideoFormatDescription,
    presentationTime: CMTime, decodeTime: CMTime, isKeyframe: Bool, hidden: Bool
  ) throws -> CMSampleBuffer {
    var block: CMBlockBuffer?
    var status = CMBlockBufferCreateWithMemoryBlock(
      allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: payload.count,
      blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
      dataLength: payload.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
    guard status == noErr, let block else { throw Self.failure }
    status = payload.withUnsafeBytes { raw in
      CMBlockBufferReplaceDataBytes(
        with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: payload.count)
    }
    guard status == noErr else { throw Self.failure }
    var timing = CMSampleTimingInfo(
      duration: .invalid, presentationTimeStamp: presentationTime, decodeTimeStamp: decodeTime)
    var size = payload.count
    var made: CMSampleBuffer?
    status = CMSampleBufferCreateReady(
      allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: description,
      sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
      sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &made)
    guard status == noErr, let made else { throw Self.failure }
    if !isKeyframe || hidden,
       let attachments = CMSampleBufferGetSampleAttachmentsArray(made, createIfNecessary: true),
       CFArrayGetCount(attachments) > 0 {
      let first = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
      if !isKeyframe { set(kCMSampleAttachmentKey_NotSync, in: first) }
      if hidden { set(kCMSampleAttachmentKey_DoNotDisplay, in: first) }
    }
    return made
  }

  private static func set(_ key: CFString, in dictionary: CFMutableDictionary) {
    CFDictionarySetValue(
      dictionary, Unmanaged.passUnretained(key).toOpaque(),
      Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
  }

  private static var failure: UmbelError {
    .videoRenderUnavailable(reason: "cannot wrap a DV packet as a sample")
  }
}
