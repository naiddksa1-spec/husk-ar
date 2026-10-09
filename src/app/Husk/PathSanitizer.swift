// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// Lightweight path sanitization for HuskBridgeFS and IncomingFiles.
///
/// Prevents classic injection vectors when a path is later interpolated into
/// a shell command (`exec`, `find -exec`, `stat`, etc.) inside the guest or
/// host bridge.
///
/// Usage (example):
///   let safe = PathSanitizer.shellQuoted(userPath)
///   // then pass `safe` into the command string
enum PathSanitizer {

    /// Characters that must never appear unescaped in a shell single-quoted string.
    private static let dangerous: CharacterSet = {
        var set = CharacterSet()
        set.insert(charactersIn: "\0\n\r;|&$`\\\"'<>(){}[]!*?")
        return set
    }()

    /// Returns true if the path contains only safe path characters
    /// (letters, digits, `/`, `.`, `-`, `_`, space).
    static func isSafePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.contains("\0") else { return false }
        // Reject absolute paths that try to escape the sandbox via ".."
        // when the consumer later joins them under a fixed root.
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        if components.contains("..") { return false }
        return path.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar)
                || scalar == "/" || scalar == "." || scalar == "-"
                || scalar == "_" || scalar == " " || scalar == "+"
                || scalar == "=" || scalar == "@"
        }
    }

    /// Single-quote a string for safe inclusion in a POSIX shell command.
    /// Empty string becomes `''`.
    static func shellQuoted(_ s: String) -> String {
        if s.isEmpty { return "''" }
        // Classic: close quote, escaped single-quote, reopen quote.
        let escaped = s.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }

    /// Reject or sanitize a path that will be used as a destination under
    /// Documents / Application Support. Returns nil if the path is unsafe.
    static func sanitizeRelativePath(_ path: String, maxLength: Int = 512) -> String? {
        guard path.count <= maxLength else { return nil }
        guard isSafePath(path) else { return nil }
        // Collapse multiple slashes and strip leading/trailing whitespace.
        let cleaned = path
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "//+", with: "/", options: .regularExpression)
        guard !cleaned.isEmpty, cleaned != "/" else { return nil }
        return cleaned
    }

    /// Maximum accepted APK / asset size (2 GiB). Larger files are refused
    /// before copy to avoid memory pressure and DoS.
    static let maxImportBytes: Int64 = 2 * 1024 * 1024 * 1024

    static func acceptImportSize(_ bytes: Int64) -> Bool {
        bytes > 0 && bytes <= maxImportBytes
    }
}
