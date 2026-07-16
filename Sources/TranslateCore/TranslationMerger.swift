// TranslationMerger.swift
// Pure logic — zero file I/O.

import Foundation

public enum TranslationMerger {
    /// Merges translated [key: value] back into base XCStrings for one locale.
    /// Returns a new XCStrings with the translations applied.
    public static func merge(
        base: XCStrings,
        slice: [String: String],
        locale: String
    ) -> XCStrings {
        var updated = base
        for (key, translatedValue) in slice {
            guard updated.strings[key] != nil else { continue }
            var entry = updated.strings[key]!
            var localizations = entry.localizations ?? [:]
            localizations[locale] = XCLocalization(
                stringUnit: XCStringUnit(state: "translated", value: translatedValue)
            )
            entry.localizations = localizations
            updated.strings[key] = entry
        }
        return updated
    }

    /// Updates manifest after a successful run.
    /// - Merges locale arrays (union, never replaces partial progress)
    /// - Prunes keys deleted from xcstrings
    public static func updateManifest(
        _ manifest: inout TranslationManifest,
        keys: [String],
        sourceValues: [String: String],   // key → English source value
        xcstrings: XCStrings,
        completedLocales: [String]
    ) {
        let now = ISO8601DateFormatter().string(from: Date())

        // Update/insert entries for translated keys
        for key in keys {
            guard let sourceValue = sourceValues[key] else { continue }
            let existingLocales = manifest.entries[key]?.locales ?? []
            let mergedLocales = Array(Set(existingLocales + completedLocales)).sorted()
            manifest.entries[key] = ManifestEntry(
                sourceValue: sourceValue,
                translatedAt: now,
                locales: mergedLocales
            )
        }

        // Prune keys deleted from xcstrings
        let currentKeys = Set(xcstrings.strings.keys)
        for key in manifest.entries.keys where !currentKeys.contains(key) {
            manifest.entries.removeValue(forKey: key)
        }
    }
}
