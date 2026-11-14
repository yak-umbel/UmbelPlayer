import Foundation

/// A master playlist: the variants of one presentation, and the renditions
/// they share.
///
/// Only as much as choosing a variant takes: which one, and whether its
/// sound lives in a playlist of its own — which the demuxer here does not
/// join up, and hands on to the fallback, with a master of that variant
/// alone.
internal struct HLSMasterPlaylist: Equatable, Sendable {
  struct Variant: Equatable, Sendable {
    let url: URL
    let bandwidth: Int
    let audioGroup: String?
    /// The tag it was listed with, as written.
    var tag = ""
  }

  struct Rendition: Equatable, Sendable {
    let type: String
    let group: String
    let url: URL?
    var isDefault = false
    var tag = ""
  }

  enum ParseError: Error, Equatable {
    case notAMasterPlaylist
  }

  let variants: [Variant]
  let renditions: [Rendition]

  /// The variant with the most bandwidth: switching with the link is not
  /// done here, so the best picture is played.
  func best() -> Variant? {
    variants.max { $0.bandwidth < $1.bandwidth }
  }

  func needsSeparateAudio(_ variant: Variant) -> Bool {
    guard let group = variant.audioGroup else { return false }
    return renditions.contains { $0.type == "AUDIO" && $0.group == group && $0.url != nil }
  }

  /// A master of `variant` alone, with one sound rendition of its group —
  /// the default, else the first. Handed the whole, FFmpeg's reading opens
  /// every variant and rendition at once, a connection each: a master of a
  /// dozen was never done opening.
  func playing(_ variant: Variant) -> String {
    let sounds = renditions.filter { $0.type == "AUDIO" && $0.group == variant.audioGroup }
    let sound = sounds.first(where: \.isDefault) ?? sounds.first
    // Subtitle and caption groups are not played: the tag names none.
    let tag = variant.tag.replacingOccurrences(
      of: #",(SUBTITLES|CLOSED-CAPTIONS)=("[^"]*"|[^,]*)"#, with: "", options: .regularExpression)
    return (["#EXTM3U"] + [sound?.tag].compactMap { $0 } + [tag, variant.url.absoluteString])
      .joined(separator: "\n") + "\n"
  }

  static func isMaster(_ text: String) -> Bool {
    text.contains("#EXT-X-STREAM-INF")
  }

  static func parse(_ text: String, base: URL) throws -> HLSMasterPlaylist {
    var variants: [Variant] = []
    var renditions: [Rendition] = []
    var pending: [String: String]?
    var pendingTag = ""
    for line in HLSAttributes.lines(of: text) {
      if line.hasPrefix("#") {
        let (tag, value) = HLSAttributes.split(line)
        switch tag {
        case "#EXT-X-STREAM-INF":
          pending = HLSAttributes.parse(value)
          pendingTag = line
        case "#EXT-X-MEDIA":
          let attributes = HLSAttributes.parse(value)
          renditions.append(Rendition(
            type: attributes["TYPE"] ?? "", group: attributes["GROUP-ID"] ?? "",
            url: attributes["URI"].flatMap { HLSAttributes.resolve($0, against: base) },
            isDefault: attributes["DEFAULT"] == "YES", tag: line))
        default:
          break
        }
        continue
      }
      guard let attributes = pending,
            let url = HLSAttributes.resolve(line, against: base) else { continue }
      variants.append(Variant(
        url: url, bandwidth: Int(attributes["BANDWIDTH"] ?? "") ?? 0,
        audioGroup: attributes["AUDIO"], tag: pendingTag))
      pending = nil
    }
    guard !variants.isEmpty else { throw ParseError.notAMasterPlaylist }
    return HLSMasterPlaylist(variants: variants, renditions: renditions)
  }
}
