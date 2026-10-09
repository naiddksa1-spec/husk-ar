// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// Thin localization helper. SwiftUI `Text("Key")` already resolves
/// `Localizable.strings` for the active language; use `L(_:)` when you need a
/// `String` (alerts, logs shown to the user, interpolated messages).
///
/// App display name stays **Husk** in every language (see InfoPlist.strings).
enum HuskL10n {
    /// Preferred language is Arabic (any regional variant).
    static var isArabic: Bool {
        Locale.preferredLanguages.first.map {
            $0.hasPrefix("ar")
        } ?? false
    }

    /// Look up a string in the main bundle's Localizable table.
    /// Falls back to the key itself when missing (English source text).
    static func string(_ key: String, table: String? = nil) -> String {
        NSLocalizedString(key, tableName: table, bundle: .main, value: key, comment: "")
    }
}

/// Shorthand used across the app: `L("Library")` → "المكتبة" when Arabic is on.
@inline(__always)
func L(_ key: String) -> String {
    HuskL10n.string(key)
}

extension String {
    /// Localize this string as a key into Localizable.strings.
    var huskLocalized: String { HuskL10n.string(self) }
}
