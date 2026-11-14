import Foundation

/// Media kept on disk between plays, for `UmbelDiskCacheSource` to read
/// through.
///
/// One folder, one capacity. Content is stored in fixed blocks of a
/// mebibyte, and the least recently used blocks go first once the capacity
/// is passed. What is kept survives the process; a crash can lose a block
/// being written, never corrupt one.
///
/// Use one instance per folder: a second in the same process throws. Share
/// it between every source that should cache into the folder.
///
/// A disk that misbehaves while playing — full, removed, read-only — never
/// fails playback: a block that cannot be written is simply not kept, and
/// one that cannot be read is fetched again. Only construction throws.
public actor UmbelDiskCache {
  /// The block size for real use. Tests pass their own.
  internal static let defaultBlockSize = 1024 * 1024

  internal nonisolated let blockSize: Int
  private let root: URL
  private let capacity: Int64
  private var isClosed = false

  private struct BlockID: Hashable {
    let folder: String
    let index: Int64
  }

  private struct Record {
    var size: Int64
    /// Larger is more recent. A counter rather than a date: two uses in the
    /// same instant still come in order.
    var lastUse: UInt64
  }

  private var blocks: [BlockID: Record] = [:]
  private var lengths: [String: Int64] = [:]
  private var useCounter: UInt64 = 0

  /// Bytes of media held, not counting the few bytes of each key's metadata.
  public private(set) var usedBytes: Int64 = 0

  /// Creates the folder if needed and takes over what an earlier run left
  /// in it. `capacity` is in bytes.
  public init(directory: URL, capacity: Int64) throws {
    try self.init(directory: directory, capacity: capacity, blockSize: Self.defaultBlockSize)
  }

  internal init(directory: URL, capacity: Int64, blockSize: Int) throws {
    let root = directory.standardizedFileURL.resolvingSymlinksInPath()
    guard DiskCacheFolders.shared.claim(root.path) else {
      throw UmbelError.cacheUnavailable(reason: "another cache instance is using \(root.path)")
    }
    do {
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    } catch {
      DiskCacheFolders.shared.release(root.path)
      throw UmbelError.cacheUnavailable(reason: "cannot create \(root.path): \(error.localizedDescription)")
    }
    self.root = root
    self.capacity = max(0, capacity)
    self.blockSize = max(1, blockSize)

    // Oldest first, so the order of use carries over from the last run.
    let scan = DiskCacheLayout.scan(root, blockSize: self.blockSize)
    var found = scan.blocks.sorted(by: { $0.modified < $1.modified })
    var total = found.reduce(Int64(0)) { $0 + $1.size }
    // A smaller capacity than last time: the oldest go first, as ever.
    while total > self.capacity, !found.isEmpty {
      let oldest = found.removeFirst()
      total -= oldest.size
      try? FileManager.default.removeItem(
        at: root.appendingPathComponent(oldest.folder).appendingPathComponent(String(oldest.index)))
    }
    var counter: UInt64 = 0
    var records: [BlockID: Record] = [:]
    for block in found {
      counter += 1
      records[BlockID(folder: block.folder, index: block.index)] =
        Record(size: block.size, lastUse: counter)
    }
    blocks = records
    lengths = scan.lengths
    useCounter = counter
    usedBytes = total
  }

  deinit {
    if !isClosed { DiskCacheFolders.shared.release(root.path) }
  }

  /// Bytes held for one key: how much of that content is on disk.
  public func cachedBytes(forKey key: String) -> Int64 {
    let folder = DiskCacheLayout.folderName(for: key)
    return blocks.reduce(0) { $0 + ($1.key.folder == folder ? $1.value.size : 0) }
  }

  public func remove(key: String) {
    drop(folder: DiskCacheLayout.folderName(for: key))
  }

  /// Everything this cache keeps. Files it did not write stay.
  public func removeAll() {
    for folder in Set(blocks.keys.map(\.folder)).union(lengths.keys) { drop(folder: folder) }
  }

  /// Lets go of the folder; another cache may then open it. Afterwards
  /// nothing is kept or found.
  public func close() {
    guard !isClosed else { return }
    isClosed = true
    DiskCacheFolders.shared.release(root.path)
  }

  // ── For the source ───────────────────────────────────

  /// Block `index` of `key`, if held. Reading it makes it the most recent.
  internal func block(forKey key: String, at index: Int64) -> Data? {
    guard !isClosed else { return nil }
    let id = BlockID(folder: DiskCacheLayout.folderName(for: key), index: index)
    guard let record = blocks[id] else { return nil }
    let url = blockURL(id)
    guard let data = try? Data(contentsOf: url), Int64(data.count) == record.size else {
      // Gone or changed behind our back: forget it and fetch again.
      forget(id)
      try? FileManager.default.removeItem(at: url)
      return nil
    }
    touch(id)
    return data
  }

  /// Keeps a block. One of the wrong size is refused rather than stored:
  /// only the last block may be short, and only once the length is known.
  /// Failing to write is not an error — the block is just not kept.
  internal func store(_ data: Data, forKey key: String, at index: Int64) {
    guard !isClosed else { return }
    let folder = DiskCacheLayout.folderName(for: key)
    let expected = DiskCacheLayout.expectedSize(
      ofBlock: index, blockSize: blockSize, length: lengths[folder])
    guard Int64(data.count) == expected, prepare(folder: folder, key: key) else { return }
    let id = BlockID(folder: folder, index: index)
    do {
      try DiskCacheLayout.writeAtomically(data, to: blockURL(id))
    } catch {
      return
    }
    forget(id)
    blocks[id] = Record(size: Int64(data.count), lastUse: 0)
    usedBytes += Int64(data.count)
    touch(id)
    evictToCapacity()
  }

  internal func contentLength(forKey key: String) -> Int64? {
    lengths[DiskCacheLayout.folderName(for: key)]
  }

  /// Records the content's length. A different one from before means the
  /// content under this key changed, and what is held for it is dropped:
  /// old blocks and new would piece together into nonsense.
  internal func setContentLength(_ length: Int64, forKey key: String) {
    guard !isClosed else { return }
    let folder = DiskCacheLayout.folderName(for: key)
    if let known = lengths[folder] {
      guard known != length else { return }
      drop(folder: folder)
    }
    guard prepare(folder: folder, key: key) else { return }
    let url = root.appendingPathComponent(folder).appendingPathComponent(DiskCacheLayout.lengthFile)
    guard (try? DiskCacheLayout.writeAtomically(Data(String(length).utf8), to: url)) != nil else {
      return
    }
    lengths[folder] = length
  }

  // ── Bookkeeping ──────────────────────────────────────

  private func blockURL(_ id: BlockID) -> URL {
    root.appendingPathComponent(id.folder).appendingPathComponent(String(id.index))
  }

  /// Makes sure the key's folder exists and belongs to this key. Two keys
  /// hashing alike is not going to happen, but if a folder names another key
  /// its contents are not ours to serve.
  private func prepare(folder: String, key: String) -> Bool {
    let url = root.appendingPathComponent(folder)
    if let owner = DiskCacheLayout.readKey(in: url) {
      if owner == key { return true }
      drop(folder: folder)
    }
    do {
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      try DiskCacheLayout.writeAtomically(
        Data(key.utf8), to: url.appendingPathComponent(DiskCacheLayout.keyFile))
      return true
    } catch {
      return false
    }
  }

  /// The block becomes the most recently used, here and on disk.
  private func touch(_ id: BlockID) {
    useCounter += 1
    blocks[id]?.lastUse = useCounter
    try? FileManager.default.setAttributes(
      [.modificationDate: Date()], ofItemAtPath: blockURL(id).path)
  }

  private func forget(_ id: BlockID) {
    guard let record = blocks.removeValue(forKey: id) else { return }
    usedBytes -= record.size
  }

  private func drop(folder: String) {
    for id in blocks.keys where id.folder == folder { forget(id) }
    lengths[folder] = nil
    DiskCacheLayout.clear(root.appendingPathComponent(folder))
  }

  private func evictToCapacity() {
    while usedBytes > capacity,
          let oldest = blocks.min(by: { $0.value.lastUse < $1.value.lastUse })?.key {
      forget(oldest)
      try? FileManager.default.removeItem(at: blockURL(oldest))
    }
  }
}
