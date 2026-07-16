// DiffExtractor.swift
// Pure logic — zero file I/O. Fully unit testable with in-memory data.
// All file reads/writes live in ManifestHandler.swift and XCStringsParser.swift.

import Foundation

/// Stateless diff logic: compares current .xcstrings state against the translation manifest
/// to determine which keys need (re-)translation.
///
/// Deliberately a caseless enum rather than a struct or class:
/// - No stored state — all methods are static, inputs are explicit parameters.
/// - Impossible to accidentally instantiate or hold a stale reference.
/// - Communicates intent: this is a namespace for pure functions, not an object.
public enum DiffExtractor {

    /// Returns `[key: englishSourceValue]` for keys that need (re-)translation.
    ///
    /// A key is included when ANY of the following is true:
    ///   1. **New key** — not present in the manifest at all.
    ///   2. **Source changed** — `manifest.entries[key].sourceValue` differs from the current English value
    ///      in the .xcstrings file. This is the core incremental mechanism: we track *what we translated*
    ///      not *when* — so renames, rewrites, and typo fixes all trigger a re-translation correctly.
    ///   3. **New locale** — a target locale in `targetLocales` is missing from `manifest.entries[key].locales`.
    ///      Adding a new language to localization.config.json automatically back-fills all existing keys.
    ///
    /// Keys present in the manifest but deleted from .xcstrings are pruned by `TranslationMerger.updateManifest`
    /// (not here) — DiffExtractor only reads, never writes, the manifest.
    ///
    /// - Returns: `[String: String]` (key → source value), not `[String]`.
    ///   Returning the value avoids a second pass in main.swift to re-extract source values from xcstrings.
    public static func changedKeys(
        xcstrings: XCStrings,
        manifest: TranslationManifest,
        targetLocales: [String]
    ) -> [String: String] {
        var result: [String: String] = [:]
        for (key, entry) in xcstrings.strings {
            // Only keys with a non-empty source-language value are translatable.
            // Keys with no source value (e.g. plural variants added by Xcode but not yet filled in)
            // are silently skipped rather than translated as empty strings.
            guard let sourceValue = entry.localizations?[xcstrings.sourceLanguage]?.stringUnit?.value,
                  !sourceValue.isEmpty else {
                continue
            }
            guard let record = manifest.entries[key] else {
                // Key not in manifest at all — always translate
                result[key] = sourceValue
                continue
            }
            let sourceChanged = record.sourceValue != sourceValue
            // hasNewLocale: true if any requested locale has never been translated for this key.
            // This is how adding "zh-Hans" to localization.config.json triggers a back-fill run.
            let hasNewLocale = targetLocales.contains { !record.locales.contains($0) }
            if sourceChanged || hasNewLocale {
                result[key] = sourceValue
            }
        }
        return result
    }

    /// Builds a minimal XCStrings slice containing only the specified keys.
    /// Used in tests and anywhere a subset of xcstrings needs to be inspected
    /// without mutating the full file.
    public static func slice(from xcstrings: XCStrings, keys: [String]) -> XCStrings {
        let filtered = xcstrings.strings.filter { keys.contains($0.key) }
        return XCStrings(
            version: xcstrings.version,
            sourceLanguage: xcstrings.sourceLanguage,
            strings: filtered
        )
    }
}
