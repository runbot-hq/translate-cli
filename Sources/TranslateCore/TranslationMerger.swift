// TranslationMerger.swift
// Pure logic — zero file I/O.
// merge() and updateManifest() are deliberately separate functions:
//   merge()          → updates the in-memory XCStrings (called once per locale)
//   updateManifest() → updates the manifest after ALL locales complete (called once per run)

import Foundation

/// Merges translated results back into XCStrings and updates the translation manifest.
public enum TranslationMerger {

    /// Merges a locale's translated `[key: value]` slice back into the base XCStrings.
    ///
    /// Returns a new XCStrings value — does not mutate the caller's copy.
    /// The returned value becomes the new `base` for the next locale in the sequential loop.
    ///
    /// - Note: State is set to `"translated"` (the standard Xcode-recognised state for
    ///   machine-translated strings). Xcode may mark these for human review depending on
    ///   the project's localization settings.
    public static func merge(
        base: XCStrings,
        slice: [String: String],
        locale: String
    ) -> XCStrings {
        var updated = base
        for (key, translatedValue) in slice {
            // Skip if the key was removed between diff and merge (unlikely but defensive)
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

    /// Updates the manifest after a successful run.
    ///
    /// Called exactly once per CLI run, after the per-locale translation loop finishes.
    /// main.swift deliberately skips this call when `completedLocales` is empty (all locales failed)
    /// so `translatedAt` is never bumped on a fully failed run. That guard lives at the call site —
    /// not here — because this function is pure manifest-update logic and should not need to infer
    /// whether the run was globally successful.
    ///
    /// - **Union merge on locales:** existing locale lists are extended, never replaced.
    ///   Partial runs (e.g. one locale failed) don't erase previously completed locales.
    /// - **Key pruning:** keys deleted from .xcstrings are removed from the manifest so
    ///   the manifest doesn't accumulate stale entries over time.
    ///
    /// - Parameters:
    ///   - manifest: Modified in-place (`inout`) to avoid copying the full entry dict.
    ///   - keys: The keys that were translated this run (from `DiffExtractor.changedKeys().keys`).
    ///   - sourceValues: `[key: englishSourceValue]` — the same dict returned by `DiffExtractor.changedKeys()`.
    ///     This extra parameter is intentional (not spec drift by accident): it avoids a second
    ///     pass over XCStrings just to re-extract source values for the manifest.
    ///   - xcstrings: Current state of the .xcstrings file — used for key pruning only.
    ///   - completedLocales: Locales that succeeded this run (failed locales are excluded).
    public static func updateManifest(
        _ manifest: inout TranslationManifest,
        keys: [String],
        sourceValues: [String: String],
        xcstrings: XCStrings,
        completedLocales: [String]
    ) {
        let now = ISO8601DateFormatter().string(from: Date())

        for key in keys {
            guard let sourceValue = sourceValues[key] else { continue }
            let existingLocales = manifest.entries[key]?.locales ?? []
            // Union: keep existing locales + add newly completed ones; sort for stable JSON diffs
            let mergedLocales = Array(Set(existingLocales + completedLocales)).sorted()
            manifest.entries[key] = ManifestEntry(
                sourceValue: sourceValue,
                translatedAt: now,
                locales: mergedLocales
            )
        }

        // Prune manifest entries for keys deleted from .xcstrings.
        // Without pruning, the manifest would silently retain stale entries forever,
        // making it an unreliable audit log and wasting space.
        let currentKeys = Set(xcstrings.strings.keys)
        for key in manifest.entries.keys where !currentKeys.contains(key) {
            manifest.entries.removeValue(forKey: key)
        }
    }
}
