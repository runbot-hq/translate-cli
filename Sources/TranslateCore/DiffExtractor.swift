// DiffExtractor.swift
// Pure logic — zero file I/O. Fully unit testable with in-memory data.

import Foundation

public enum DiffExtractor {
    /// Returns [key: englishSourceValue] for keys that need (re-)translation:
    ///   1. Not in manifest at all (new key)
    ///   2. manifest.entries[key].sourceValue != current English value (source changed)
    ///   3. A target locale is missing from manifest.entries[key].locales (new locale added)
    public static func changedKeys(
        xcstrings: XCStrings,
        manifest: TranslationManifest,
        targetLocales: [String]
    ) -> [String: String] {
        var result: [String: String] = [:]
        for (key, entry) in xcstrings.strings {
            guard let sourceValue = entry.localizations?[xcstrings.sourceLanguage]?.stringUnit?.value,
                  !sourceValue.isEmpty else {
                continue
            }
            guard let record = manifest.entries[key] else {
                // New key — not in manifest
                result[key] = sourceValue
                continue
            }
            let sourceChanged = record.sourceValue != sourceValue
            let hasNewLocale = targetLocales.contains { !record.locales.contains($0) }
            if sourceChanged || hasNewLocale {
                result[key] = sourceValue
            }
        }
        return result
    }

    /// Builds a minimal XCStrings slice containing only the specified keys.
    public static func slice(from xcstrings: XCStrings, keys: [String]) -> XCStrings {
        let filtered = xcstrings.strings.filter { keys.contains($0.key) }
        return XCStrings(
            version: xcstrings.version,
            sourceLanguage: xcstrings.sourceLanguage,
            strings: filtered
        )
    }
}
