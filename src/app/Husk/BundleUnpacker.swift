// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// Takes the APKs out of an app bundle: an .xapk (APKPure), .apkm (APKMirror) or .apks (bundletool), which are zip files holding a base APK and its splits and asset packs.
///
/// Only what is needed is read: the zip's central directory, then each APK's bytes copied across in chunks. An APK inside a bundle is stored, not compressed (it is already a zip),
/// so nothing is inflated and a 200 MB asset pack costs a few megabytes of memory, not 200.
enum BundleUnpacker {
    static let extensions: Set<String> = ["xapk", "apkm", "apks"]

    enum Failure: LocalizedError {
        case notAZip, unsupported(String)
        var errorDescription: String? {
            switch self {
            case .notAZip: return "That file is not a bundle Husk can read."
            case .unsupported(let why): return why
            }
        }
    }

    /// Whether an APK is a split or an asset pack, as the bundle formats name them, rather than the app itself.
    static func isSplit(_ name: String) -> Bool {
        let n = name.lowercased()
        if n == "base.apk" || n == "base-master.apk" { return false }
        return n.hasPrefix("config.") || n.hasPrefix("split_") || n.hasPrefix("asset_pack") || n.hasPrefix("base-") || n.hasPrefix("install_time")
    }

    /// The order an app's APKs are given to the runtime in, which takes only four: the app itself, then what it cannot run without (its 64-bit libraries, its asset pack),
    /// then the language and screen-density splits, which it does not need.
    static func rank(_ name: String) -> Int {
        let n = name.lowercased()
        if !isSplit(n) { return 0 }
        if n.contains("arm64") { return 1 }
        if n.hasPrefix("asset_pack") || n.hasPrefix("install_time") { return 2 }
        return 3
    }

    /// Copies every APK in `bundle` into `dir`. Returns their names.
    @discardableResult
    static func unpack(_ bundle: URL, into dir: URL) throws -> [String] {
        let scoped = bundle.startAccessingSecurityScopedResource()
        defer { if scoped { bundle.stopAccessingSecurityScopedResource() } }
        let file = try FileHandle(forReadingFrom: bundle)
        defer { try? file.close() }

        let size = try file.seekToEnd()
        // The end-of-central-directory record is in the last 64 KB plus 22 bytes.
        let tail = min(size, 70_000)
        try file.seek(toOffset: size - tail)
        guard let end = try file.read(upToCount: Int(tail)), end.count >= 22 else { throw Failure.notAZip }
        let bytes = [UInt8](end)
        var e = bytes.count - 22
        while e >= 0, !(bytes[e] == 0x50 && bytes[e + 1] == 0x4b && bytes[e + 2] == 5 && bytes[e + 3] == 6) { e -= 1 }
        guard e >= 0 else { throw Failure.notAZip }
        let count = Int(le16(bytes, e + 10))
        let dirSize = UInt64(le32(bytes, e + 12)), dirOffset = UInt64(le32(bytes, e + 16))
        if dirOffset == 0xffff_ffff || count == 0xffff { throw Failure.unsupported("That bundle uses a zip format (Zip64) Husk does not read yet.") }
        guard le16(bytes, e + 4) == 0, le16(bytes, e + 6) == 0,
              Int(le16(bytes, e + 8)) == count,
              e + 22 + Int(le16(bytes, e + 20)) == bytes.count,
              dirSize <= 16 << 20, count <= 4096,
              dirOffset <= size - tail + UInt64(e),
              dirSize == size - tail + UInt64(e) - dirOffset else { throw Failure.notAZip }

        try file.seek(toOffset: dirOffset)
        guard let directory = try file.read(upToCount: Int(dirSize)), directory.count == Int(dirSize) else { throw Failure.notAZip }
        let cd = [UInt8](directory)

        var names: [String] = []
        var seen = Set<String>()
        var total: UInt64 = 0
        // Work in an isolated directory: a malformed bundle must never leave
        // partially imported APKs or overwrite an existing import.
        let staging = dir.appendingPathComponent(".import-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        var p = 0
        for _ in 0..<count {
            guard p + 46 <= cd.count, le32(cd, p) == 0x0201_4b50 else { throw Failure.notAZip }
            let flags = le16(cd, p + 8)
            let method = le16(cd, p + 10)
            let expectedCRC = le32(cd, p + 16)
            let compressed = UInt64(le32(cd, p + 20))
            let expanded = UInt64(le32(cd, p + 24))
            let nameLen = Int(le16(cd, p + 28)), extraLen = Int(le16(cd, p + 30)), commentLen = Int(le16(cd, p + 32))
            let localOffset = UInt64(le32(cd, p + 42))
            guard p + 46 + nameLen + extraLen + commentLen <= cd.count else { throw Failure.notAZip }
            let name = String(decoding: cd[(p + 46)..<(p + 46 + nameLen)], as: UTF8.self)
            p += 46 + nameLen + extraLen + commentLen

            let base = (name as NSString).lastPathComponent
            guard base.lowercased().hasSuffix(".apk"), !name.hasSuffix("/") else { continue }
            guard !name.contains("\\"), !name.contains("\0"), !name.hasPrefix("/"),
                  !name.split(separator: "/").contains(".."),
                  seen.insert(base.lowercased()).inserted,
                  !FileManager.default.fileExists(atPath: dir.appendingPathComponent(base).path),
                  flags & 1 == 0, compressed == expanded,
                  compressed <= 4_294_967_294 else { throw Failure.notAZip }
            total += expanded
            guard total <= 8_589_934_592 else { throw Failure.unsupported("That bundle exceeds the 8 GB import limit.") }
            guard method == 0 else { throw Failure.unsupported("\(base) is compressed inside its bundle, which Husk cannot unpack yet.") }

            // The local header has its own name and extra lengths; the data follows them.
            try file.seek(toOffset: localOffset)
            guard let local = try file.read(upToCount: 30), local.count == 30 else { throw Failure.notAZip }
            let lh = [UInt8](local)
            guard le32(lh, 0) == 0x0403_4b50, le16(lh, 6) == flags,
                  le16(lh, 8) == method else { throw Failure.notAZip }
            let dataStart = localOffset + 30 + UInt64(le16(lh, 26)) + UInt64(le16(lh, 28))
            guard dataStart <= dirOffset, compressed <= dirOffset - dataStart else { throw Failure.notAZip }
            guard let localName = try file.read(upToCount: Int(le16(lh, 26))),
                  String(data: localName, encoding: .utf8) == name else { throw Failure.notAZip }
            try file.seek(toOffset: dataStart)

            let dest = staging.appendingPathComponent(base)
            guard FileManager.default.createFile(atPath: dest.path, contents: nil) else { throw Failure.notAZip }
            let out = try FileHandle(forWritingTo: dest)
            defer { try? out.close() }
            var left = compressed
            var crc: UInt32 = 0xffff_ffff
            while left > 0 {
                let chunk = Int(min(left, 4 << 20))
                guard let data = try file.read(upToCount: chunk), !data.isEmpty else { throw Failure.notAZip }
                try out.write(contentsOf: data)
                for byte in data { crc = (crc >> 8) ^ crcTable[Int((crc ^ UInt32(byte)) & 255)] }
                left -= UInt64(data.count)
            }
            guard crc ^ 0xffff_ffff == expectedCRC else { throw Failure.unsupported("\(base) is damaged. Download the bundle again.") }
            try out.close()
            names.append(base)
        }
        guard p == cd.count else { throw Failure.notAZip }
        if names.isEmpty { throw Failure.unsupported("There are no APKs in that bundle.") }
        var committed: [URL] = []
        do {
            for name in names {
                let destination = dir.appendingPathComponent(name)
                try FileManager.default.moveItem(at: staging.appendingPathComponent(name), to: destination)
                committed.append(destination)
            }
        } catch {
            for destination in committed { try? FileManager.default.removeItem(at: destination) }
            throw error
        }
        return names
    }

    private static let crcTable: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xedb8_8320 : 0) }
        return crc
    }

    private static func le16(_ b: [UInt8], _ o: Int) -> UInt16 { UInt16(b[o]) | UInt16(b[o + 1]) << 8 }
    private static func le32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
    }
}
