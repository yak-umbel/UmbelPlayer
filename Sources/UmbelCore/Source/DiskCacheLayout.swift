import CryptoKit
import Foundation

/// How the disk cache lays its files out, and how it reads them back.
///
///     <folder>/
///       <sha256 of the key, 64 hex digits>/
///         key        the key itself, to find it again and spot a clash
///         length     the content's total length, once known
///         0, 1, 2 …  block n: bytes n × blockSize up to the next block
///         *.partial  a block still being written
///
/// A block file is complete or absent: it is written under a temporary name
/// and renamed into place. Recency lives in each block's modification date,
/// so a restart rebuilds the eviction order from the files themselves and
/// there is no index to fall out of step with them.
///
/// Only what matches these names is ever deleted; anything else a host keeps
/// in the folder is left alone.
internal enum DiskCacheLayout {
  static let keyFile = "key"
  static let lengthFile = "length"
  static let partialSuffix = ".partial"

  /// Where a key's files live, relative to the cache folder.
  static func folderName(for key: String) -> String {
    SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  static func isFolderName(_ name: String) -> Bool {
    name.count == 64 && name.allSatisfy { $0.isHexDigit && !$0.isUppercase }
  }

  static func blockIndex(fromFileName name: String) -> Int64? {
    guard !name.isEmpty, name.allSatisfy(\.isASCII), name.allSatisfy(\.isNumber) else { return nil }
    return Int64(name)
  }

  /// The size block `index` must have: a whole block, or what is left for
  /// the last. Nil when the block lies past the end. Without a known length
  /// only whole blocks can be told from damaged ones.
  static func expectedSize(ofBlock index: Int64, blockSize: Int, length: Int64?) -> Int64? {
    let start = index * Int64(blockSize)
    guard let length else { return Int64(blockSize) }
    guard start < length else { return nil }
    return min(Int64(blockSize), length - start)
  }

  // ── Opening ──────────────────────────────────────────

  struct Block {
    let folder: String
    let index: Int64
    let size: Int64
    let modified: Date
  }

  struct Scan {
    var blocks: [Block] = []
    var lengths: [String: Int64] = [:]
  }

  /// Reads what a previous run left: the blocks that are whole and the
  /// right size, and each key's length. Half-written and damaged blocks are
  /// deleted on the way, and folders left without blocks go too.
  static func scan(_ root: URL, blockSize: Int) -> Scan {
    let files = FileManager.default
    var result = Scan()
    let folders = (try? files.contentsOfDirectory(atPath: root.path)) ?? []
    for folder in folders where isFolderName(folder) {
      let url = root.appendingPathComponent(folder)
      let length = readLength(in: url)
      if let length { result.lengths[folder] = length }
      var kept = 0
      for name in (try? files.contentsOfDirectory(atPath: url.path)) ?? [] {
        let file = url.appendingPathComponent(name)
        if name.hasSuffix(partialSuffix) {
          try? files.removeItem(at: file)
          continue
        }
        guard let index = blockIndex(fromFileName: name) else { continue }
        let attributes = try? files.attributesOfItem(atPath: file.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value
        guard let size,
              size == expectedSize(ofBlock: index, blockSize: blockSize, length: length) else {
          try? files.removeItem(at: file)
          continue
        }
        let modified = attributes?[.modificationDate] as? Date ?? .distantPast
        result.blocks.append(Block(folder: folder, index: index, size: size, modified: modified))
        kept += 1
      }
      if kept == 0 {
        clear(url)
        result.lengths[folder] = nil
      }
    }
    return result
  }

  // ── Writing ──────────────────────────────────────────

  /// Writes under a temporary name, then renames over the final one. A
  /// rename within a folder is atomic: a reader sees the old file or the
  /// whole new one, and a crash leaves only the temporary behind.
  static func writeAtomically(_ data: Data, to url: URL) throws {
    let temporary = url.deletingLastPathComponent()
      .appendingPathComponent(url.lastPathComponent + partialSuffix)
    try data.write(to: temporary)
    guard rename(temporary.path, url.path) == 0 else {
      try? FileManager.default.removeItem(at: temporary)
      throw CocoaError(.fileWriteUnknown)
    }
  }

  static func readLength(in folder: URL) -> Int64? {
    guard let data = try? Data(contentsOf: folder.appendingPathComponent(lengthFile)),
          let text = String(data: data, encoding: .utf8) else { return nil }
    return Int64(text.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  static func readKey(in folder: URL) -> String? {
    guard let data = try? Data(contentsOf: folder.appendingPathComponent(keyFile)) else { return nil }
    return String(data: data, encoding: .utf8)
  }

  /// Deletes the cache's own files in a key's folder, then the folder if
  /// nothing else is in it.
  static func clear(_ folder: URL) {
    let files = FileManager.default
    for name in (try? files.contentsOfDirectory(atPath: folder.path)) ?? []
    where name == keyFile || name == lengthFile || name.hasSuffix(partialSuffix)
      || blockIndex(fromFileName: name) != nil {
      try? files.removeItem(at: folder.appendingPathComponent(name))
    }
    if (try? files.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
      try? files.removeItem(at: folder)
    }
  }
}

/// Folders a cache in this process is using. Two caches on one folder would
/// each keep their own count and evict each other's blocks, so a second one
/// on a folder is refused.
internal final class DiskCacheFolders: @unchecked Sendable {
  static let shared = DiskCacheFolders()
  private let lock = NSLock()
  private var inUse: Set<String> = []

  /// False when another cache holds it.
  func claim(_ path: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return inUse.insert(path).inserted
  }

  func release(_ path: String) {
    lock.lock()
    defer { lock.unlock() }
    inUse.remove(path)
  }
}
