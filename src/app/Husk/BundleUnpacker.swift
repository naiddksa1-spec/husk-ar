// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// Safely extracts stored APK entries from XAPK/APKM/APKS containers.
///
/// Bundles are untrusted ZIP files. This reader never extracts arbitrary paths:
/// it accepts only regular `.apk` members, writes only their validated basename,
/// bounds every offset/length before seeking, rejects duplicates and unsupported
/// encryption/compression, and streams in small chunks rather than loading an
/// APK into memory. APK bytes are checked against the ZIP CRC before acceptance.
enum BundleUnpacker {
    static let extensions: Set<String> = ["xapk", "apkm", "apks"]

    // ZIP32 is the only format supported. Keep archive metadata bounded even if
    // the selected document is very large; the supported runtime is ARM64 iOS.
    private static let maxArchiveBytes: UInt64 = 4 * 1024 * 1024 * 1024
    private static let maxDirectoryBytes = 16 * 1024 * 1024
    private static let maxEntries = 8192
    private static let maxAPKBytes: UInt64 = 2 * 1024 * 1024 * 1024
    private static let maxTotalAPKBytes: UInt64 = 3 * 1024 * 1024 * 1024
    private static let copyChunkBytes = 4 * 1024 * 1024

    enum Failure: LocalizedError {
        case notAZip
        case unsupported(String)
        case invalidArchive(String)

        var errorDescription: String? {
            switch self {
            case .notAZip:
                return "This file is not a valid APK bundle."
            case .unsupported(let reason):
                return reason
            case .invalidArchive(let reason):
                return "The APK bundle is damaged or unsafe: \(reason)"
            }
        }
    }

    private struct Entry {
        let name: String
        let flags: UInt16
        let method: UInt16
        let crc32: UInt32
        let compressedSize: UInt64
        let uncompressedSize: UInt64
        let localOffset: UInt64
    }

    /// Whether an APK is a split or an asset pack, as the bundle formats name them.
    static func isSplit(_ name: String) -> Bool {
        let n = name.lowercased()
        if n == "base.apk" || n == "base-master.apk" { return false }
        return n.hasPrefix("config.") || n.hasPrefix("split_") || n.hasPrefix("asset_pack") || n.hasPrefix("base-") || n.hasPrefix("install_time")
    }

    /// Rank split APKs so the base app, ARM64 code, and install-time assets come first.
    static func rank(_ name: String) -> Int {
        let n = name.lowercased()
        if !isSplit(n) { return 0 }
        if n.contains("arm64") { return 1 }
        if n.hasPrefix("asset_pack") || n.hasPrefix("install_time") { return 2 }
        return 3
    }

    /// APK files are ZIP containers. A short signature check avoids copying an
    /// HTML error page or arbitrary data into the guest's installation queue.
    static func hasZIPSignature(at url: URL) -> Bool {
        guard let file = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? file.close() }
        guard let signature = try? file.read(upToCount: 4) else { return false }
        return signature == Data([0x50, 0x4b, 0x03, 0x04])
    }

    /// Copies validated APK entries from `bundle` into an app-owned staging directory.
    @discardableResult
    static func unpack(_ bundle: URL, into dir: URL) throws -> [String] {
        let scoped = bundle.startAccessingSecurityScopedResource()
        defer { if scoped { bundle.stopAccessingSecurityScopedResource() } }

        let file = try FileHandle(forReadingFrom: bundle)
        defer { try? file.close() }

        let size = try file.seekToEnd()
        guard size >= 22 else { throw Failure.notAZip }
        guard size <= maxArchiveBytes else {
            throw Failure.unsupported("This bundle is larger than Husk's safe 4 GiB ZIP32 limit.")
        }

        let tailLength = min(size, 70_000)
        try file.seek(toOffset: size - tailLength)
        guard let tailData = try file.read(upToCount: Int(tailLength)), tailData.count >= 22 else {
            throw Failure.notAZip
        }
        let tail = [UInt8](tailData)
        guard let eocd = findEndRecord(tail) else { throw Failure.notAZip }

        let disk = le16(tail, eocd + 4)
        let directoryDisk = le16(tail, eocd + 6)
        let diskEntries = Int(le16(tail, eocd + 8))
        let entryCount = Int(le16(tail, eocd + 10))
        let directoryBytes = UInt64(le32(tail, eocd + 12))
        let directoryOffset = UInt64(le32(tail, eocd + 16))
        let commentLength = Int(le16(tail, eocd + 20))
        guard eocd + 22 + commentLength == tail.count else {
            throw Failure.invalidArchive("the end record or comment length is inconsistent")
        }
        guard disk == 0, directoryDisk == 0, diskEntries == entryCount else {
            throw Failure.unsupported("Multi-disk ZIP bundles are not supported.")
        }
        guard entryCount != 0xffff, directoryBytes != UInt64(UInt32.max),
              directoryOffset != UInt64(UInt32.max) else {
            throw Failure.unsupported("ZIP64 bundles are not supported yet.")
        }
        guard entryCount > 0, entryCount <= maxEntries,
              directoryBytes <= UInt64(maxDirectoryBytes) else {
            throw Failure.unsupported("The bundle contains too many files or too much ZIP metadata.")
        }

        let absoluteEOCD = size - tailLength + UInt64(eocd)
        guard directoryOffset <= absoluteEOCD,
              directoryBytes <= absoluteEOCD - directoryOffset else {
            throw Failure.invalidArchive("the central directory lies outside the file")
        }

        try file.seek(toOffset: directoryOffset)
        guard let directoryData = try file.read(upToCount: Int(directoryBytes)),
              directoryData.count == Int(directoryBytes) else {
            throw Failure.invalidArchive("the central directory is truncated")
        }
        let directory = [UInt8](directoryData)
        let entries = try parseDirectory(directory, expectedCount: entryCount)

        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var writtenNames = Set<String>()
        var totalAPKBytes: UInt64 = 0
        var outputNames: [String] = []
        for entry in entries {
            guard let name = validatedAPKName(entry.name) else { continue }
            guard entry.method == 0 else {
                throw Failure.unsupported("\(name) is compressed inside its bundle. Only stored APK entries are supported.")
            }
            guard (entry.flags & 0x0041) == 0 else {
                throw Failure.unsupported("Encrypted APK entries cannot be installed.")
            }
            guard entry.compressedSize == entry.uncompressedSize,
                  entry.uncompressedSize <= maxAPKBytes,
                  totalAPKBytes <= maxTotalAPKBytes - min(entry.uncompressedSize, maxTotalAPKBytes) else {
                throw Failure.unsupported("The bundle exceeds Husk's safe APK size limits.")
            }
            let normalizedName = name.lowercased()
            guard writtenNames.insert(normalizedName).inserted else {
                throw Failure.invalidArchive("two entries use the same APK filename")
            }

            try copyAndVerify(entry, from: file, fileSize: size,
                              directoryOffset: directoryOffset, into: dir)
            totalAPKBytes += entry.uncompressedSize
            outputNames.append(name)
        }
        guard !outputNames.isEmpty else {
            throw Failure.unsupported("There are no safe, stored APK files in this bundle.")
        }
        return outputNames
    }

    private static func findEndRecord(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 22 else { return nil }
        for offset in stride(from: bytes.count - 22, through: 0, by: -1) {
            guard le32(bytes, offset) == 0x0605_4b50 else { continue }
            let comment = Int(le16(bytes, offset + 20))
            if offset + 22 + comment == bytes.count { return offset }
        }
        return nil
    }

    private static func parseDirectory(_ bytes: [UInt8], expectedCount: Int) throws -> [Entry] {
        var result: [Entry] = []
        result.reserveCapacity(expectedCount)
        var cursor = 0
        for _ in 0..<expectedCount {
            guard cursor <= bytes.count, bytes.count - cursor >= 46,
                  le32(bytes, cursor) == 0x0201_4b50 else {
                throw Failure.invalidArchive("a central directory entry is truncated")
            }
            let flags = le16(bytes, cursor + 8)
            let method = le16(bytes, cursor + 10)
            let crc = le32(bytes, cursor + 16)
            let compressed = UInt64(le32(bytes, cursor + 20))
            let uncompressed = UInt64(le32(bytes, cursor + 24))
            let nameLength = Int(le16(bytes, cursor + 28))
            let extraLength = Int(le16(bytes, cursor + 30))
            let commentLength = Int(le16(bytes, cursor + 32))
            let startDisk = le16(bytes, cursor + 34)
            let localOffset = UInt64(le32(bytes, cursor + 42))
            let recordLength = 46 + nameLength + extraLength + commentLength
            guard recordLength >= 46, recordLength <= bytes.count - cursor else {
                throw Failure.invalidArchive("a central directory entry has invalid lengths")
            }
            guard startDisk == 0 else { throw Failure.unsupported("Split-volume ZIP files are not supported.") }
            guard compressed != UInt64(UInt32.max), uncompressed != UInt64(UInt32.max),
                  localOffset != UInt64(UInt32.max) else {
                throw Failure.unsupported("ZIP64 APK entries are not supported yet.")
            }
            let nameStart = cursor + 46
            let nameBytes = bytes[nameStart..<(nameStart + nameLength)]
            guard let name = String(bytes: nameBytes, encoding: .utf8), !name.isEmpty else {
                throw Failure.invalidArchive("an entry name is not valid UTF-8")
            }
            result.append(Entry(name: name, flags: flags, method: method, crc32: crc,
                                compressedSize: compressed, uncompressedSize: uncompressed,
                                localOffset: localOffset))
            cursor += recordLength
        }
        return result
    }

    /// Returns only plain, relative APK member names. No entry path is ever used as an output path.
    private static func validatedAPKName(_ path: String) -> String? {
        guard path.lowercased().hasSuffix(".apk"),
              !path.hasPrefix("/"), !path.contains("\\"),
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              let base = components.last, base.count <= 180,
              base != ".", base != ".." else { return nil }
        return String(base)
    }

    private static func copyAndVerify(_ entry: Entry, from file: FileHandle,
                                      fileSize: UInt64, directoryOffset: UInt64,
                                      into directory: URL) throws {
        let headerEnd = entry.localOffset.addingReportingOverflow(30)
        guard !headerEnd.overflow, headerEnd.partialValue <= directoryOffset,
              headerEnd.partialValue <= fileSize else {
            throw Failure.invalidArchive("an APK local header points outside the file")
        }
        try file.seek(toOffset: entry.localOffset)
        guard let headerData = try file.read(upToCount: 30), headerData.count == 30 else {
            throw Failure.invalidArchive("an APK local header is truncated")
        }
        let header = [UInt8](headerData)
        guard le32(header, 0) == 0x0403_4b50 else {
            throw Failure.invalidArchive("an APK local header has the wrong signature")
        }
        let localFlags = le16(header, 6)
        let localMethod = le16(header, 8)
        let localCRC = le32(header, 14)
        let localCompressed = UInt64(le32(header, 18))
        let localUncompressed = UInt64(le32(header, 22))
        let localNameLength = Int(le16(header, 26))
        let localExtraLength = Int(le16(header, 28))
        guard localFlags == entry.flags, localMethod == entry.method else {
            throw Failure.invalidArchive("an APK local header disagrees with the central directory")
        }
        let dataOffset = entry.localOffset.addingReportingOverflow(30 + UInt64(localNameLength) + UInt64(localExtraLength))
        guard !dataOffset.overflow, dataOffset.partialValue <= directoryOffset,
              entry.compressedSize <= directoryOffset - dataOffset.partialValue,
              entry.compressedSize <= fileSize - min(fileSize, dataOffset.partialValue) else {
            throw Failure.invalidArchive("an APK entry's byte range is outside the archive")
        }
        try file.seek(toOffset: entry.localOffset + 30)
        guard let localName = try file.read(upToCount: localNameLength),
              localName.count == localNameLength,
              let decodedLocalName = String(data: localName, encoding: .utf8),
              decodedLocalName == entry.name else {
            throw Failure.invalidArchive("an APK local filename disagrees with the central directory")
        }
        if (entry.flags & 0x0008) == 0,
           (localCRC != entry.crc32 || localCompressed != entry.compressedSize
            || localUncompressed != entry.uncompressedSize) {
            throw Failure.invalidArchive("APK sizes or checksum disagree with the local header")
        }

        let output = directory.appendingPathComponent(validatedAPKName(entry.name)!, isDirectory: false)
        guard !FileManager.default.fileExists(atPath: output.path) else {
            throw Failure.invalidArchive("an APK filename would overwrite an existing file")
        }
        let temporary = directory.appendingPathComponent(".husk-\(UUID().uuidString).partial")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else {
            throw Failure.invalidArchive("could not create a private staging file")
        }
        var keepTemporary = false
        defer { if !keepTemporary { try? FileManager.default.removeItem(at: temporary) } }

        let destination = try FileHandle(forWritingTo: temporary)
        defer { try? destination.close() }
        try file.seek(toOffset: dataOffset.partialValue)
        var bytesRemaining = entry.compressedSize
        var checksum: uLong = 0
        while bytesRemaining > 0 {
            let chunkSize = Int(min(bytesRemaining, UInt64(copyChunkBytes)))
            guard let chunk = try file.read(upToCount: chunkSize),
                  chunk.count == chunkSize else {
                throw Failure.invalidArchive("an APK entry is truncated")
            }
            let previousChecksum = checksum
            checksum = chunk.withUnsafeBytes { raw in
                guard let start = raw.bindMemory(to: UInt8.self).baseAddress else { return previousChecksum }
                return crc32(previousChecksum, start, UInt32(chunk.count))
            }
            try destination.write(contentsOf: chunk)
            bytesRemaining -= UInt64(chunk.count)
        }
        guard UInt32(truncatingIfNeeded: checksum) == entry.crc32 else {
            throw Failure.invalidArchive("an APK checksum does not match")
        }
        try destination.close()
        try FileManager.default.moveItem(at: temporary, to: output)
        keepTemporary = true
    }

    private static func le16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private static func le32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }
}
