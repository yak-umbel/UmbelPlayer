import Foundation

/// Recognises a playlist by its first bytes, whatever its address says —
/// sites serve them from scripts and proxies — fetches it whole, and says
/// which demuxer plays it.
internal enum HLSPlaylistLoader {
  /// Far more than any playlist; a guard against being fed a film.
  static let largestPlaylist = 16 << 20

  typealias Opener = @Sendable (URL) async -> any UmbelRandomAccessSource

  enum Route {
    /// Played a run at a time here — a fixed list, or a live one that is
    /// fetched again as it grows; `address` is where the playlist is, for
    /// the fallback should this demuxer fail to open it.
    case playlist(any HLSSegmentSource, address: URL, Opener)
    /// Written in a way this demuxer does not take: FFmpeg's own reads the
    /// playlist at this address, opening everything through `Opener`.
    case ffmpeg(URL, Opener)
  }

  /// How to play what `source` holds, `head` its first bytes; nil when it
  /// is not a playlist.
  static func load(from source: UmbelSource, head: Data) async throws -> Route? {
    guard let randomAccess = source as? any UmbelRandomAccessSource else { return nil }
    guard HLSMediaPlaylist.looksLikePlaylist(head) else { return nil }
    guard let located = await source.locatedSource else {
      throw UmbelError.unsupportedContainer("a playlist, from a source that cannot open its segments")
    }
    // Read on from where recognising it stopped, on the same connection:
    // asked for again, a slow site's playlist costs seconds more.
    let text = try await readAll(randomAccess, startingWith: head)
    let address = await located.location
    let open = webOnly(address) { url in await located.source(for: url) }

    guard HLSMasterPlaylist.isMaster(text) else {
      return try await mediaRoute(text, base: address, open: open, mayBeStale: true)
    }
    let master = try HLSMasterPlaylist.parse(text, base: address)
    guard let variant = master.best() else {
      throw UmbelError.unsupportedContainer("a master playlist with no variants")
    }
    if master.needsSeparateAudio(variant) {
      // FFmpeg's reading gets a master of that variant alone, asking for
      // the master by its address.
      let trimmed = Data(master.playing(variant).utf8)
      return .ffmpeg(address) { url in url == address ? MemorySource(data: trimmed) : await open(url) }
    }
    let fetched = await open(variant.url)
    let variantText = try await readAll(fetched, startingWith: Data())
    let base = await (fetched as? any UmbelLocatedSource)?.location ?? variant.url
    return try await mediaRoute(variantText, base: base, open: open, mayBeStale: false)
  }

  /// `mayBeStale`: the text came through the host's source, which may keep
  /// what it reads by address — a disk cache — rather than straight from
  /// the server.
  private static func mediaRoute(
    _ text: String, base: URL, open: @escaping Opener, mayBeStale: Bool
  ) async throws -> Route {
    let playlist: HLSMediaPlaylist
    do {
      playlist = try HLSMediaPlaylist.parse(text, base: base)
    } catch HLSMediaPlaylist.ParseError.unsupported {
      // Written in a way this demuxer does not take — another encryption
      // scheme, say: FFmpeg's own reading may.
      return .ffmpeg(base, open)
    } catch let error as HLSMediaPlaylist.ParseError {
      throw UmbelError.unsupportedContainer("playlist: \(error)")
    }
    guard playlist.isEnded else {
      let reload = reloader(base, open: open)
      // A live list kept from before is hours old: fetched again, it says
      // where the stream is now.
      let current = mayBeStale ? try await reload() : playlist
      return .playlist(HLSLivePlaylist(first: current, reload: reload), address: base, open)
    }
    return .playlist(playlist, address: base, open)
  }

  /// Fetches a live playlist again, from where it was last found.
  private static func reloader(
    _ address: URL, open: @escaping Opener
  ) -> @Sendable () async throws -> HLSMediaPlaylist {
    {
      let source = await open(address)
      let text: String
      do {
        text = try await readAll(source, startingWith: Data())
      } catch {
        await source.invalidate()
        throw error
      }
      await source.invalidate()
      let base = await (source as? any UmbelLocatedSource)?.location ?? address
      do {
        return try HLSMediaPlaylist.parse(text, base: base)
      } catch {
        throw UmbelError.sourceUnavailable(detail: "the live playlist, fetched again: \(error)")
      }
    }
  }

  /// A playlist from the web opens web addresses only. What it names is
  /// whatever its author wrote: a local file among its segments would be
  /// read off this machine. From a local file, local files are fine.
  private static func webOnly(_ playlist: URL, _ open: @escaping Opener) -> Opener {
    let web: Set<String> = ["http", "https"]
    guard web.contains(playlist.scheme?.lowercased() ?? "") else { return open }
    return { url in
      guard web.contains(url.scheme?.lowercased() ?? "") else { return RefusedSource(url: url) }
      return await open(url)
    }
  }

  private static func readAll(
    _ source: any UmbelRandomAccessSource, startingWith head: Data
  ) async throws -> String {
    var bytes = head
    while bytes.count < largestPlaylist {
      let next = try await source.read(offset: Int64(bytes.count), maxLength: 256 << 10)
      if next.isEmpty { break }
      bytes += next
    }
    return String(decoding: bytes, as: UTF8.self)
  }
}

/// An address a playlist may not make the player open; every read says so.
private actor RefusedSource: UmbelRandomAccessSource {
  let url: URL

  init(url: URL) { self.url = url }

  var contentLength: Int64? { nil }

  func read(offset: Int64, maxLength: Int) async throws -> Data {
    throw UmbelError.unsupportedScheme(url.scheme?.lowercased() ?? "")
  }

  func invalidate() async {}
}
