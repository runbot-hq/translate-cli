// TranslationMerger.swift
// Pure logic — zero file I/O.
// merge() and updateManifest() are deliberately separate functions:
//   merge()          → updates the in-memory XCStrings (called once per locale)
//   updateManifest() → updates the manifest after ALL locales complete (called once per run)

import Foundation

/// Merges translated results back into XCStrings and updates the translation manifest.
public enum TranslationMerger {
    // Cached: ISO8601DateFormatter construction is non-trivial (allocates Calendar + TimeZone).
    // updateManifest is called once per run today, but static allocation is free and correct.
    // timeZone forced to UTC so manifests committed from runners in different system
    // timezones produce identical translatedAt strings for the same moment.
    // Without this, two runners (e.g. UTC and CEST) would generate spurious manifest diffs.
    // nonisolated(unsafe): ISO8601DateFormatter is a non-Sendable NSObject subclass; Swift 6
    // strict concurrency rejects it as a plain static. The formatter is initialised once and
    // never mutated, so there is no actual data race — nonisolated(unsafe) is correct here.
    private nonisolated(unsafe) static let isoFormatter: ISO8601DateFormatter = {
        let fmt = ISO8601DateFormatter()
        fmt.timeZone = TimeZone(identifier: "UTC")!
        return fmt
    }()

    /// Merges a locale's translated `[key: value]` slice back into the base XCStrings.
    ///
    /// Returns a new XCStrings value (copy semantics) — does not mutate the caller's copy.
    /// The returned value becomes the new `base` for the next locale in the sequential loop.
    ///
    /// **Spec note:** Both issue #2103 and #2105 §1.7 specify value-return semantics:
    /// `merge(base: XCStrings, ...) -> XCStrings`. The implementation matches the spec.
    /// Value-return is simpler, eliminates aliasing risk, and is idiomatic Swift for struct
    /// types. The call site in main.swift:
    ///   `xcstrings = TranslationMerger.merge(base: xcstrings, ...)`
    /// Do NOT change to `inout` — spec and implementation are in agreement on this.
    /// For production-scale .xcstrings files with many locales the copy cost is negligible;
    /// if profiling ever shows otherwise, switching to `inout` here and at the call site
    /// is a one-line change.
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
            guard var entry = updated.strings[key] else { continue }
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
    /// **`sourceValues` parameter — intentional addition beyond original spec:**
    /// The original spec (run-bot#2105 §1.7) defined this signature without `sourceValues`.
    /// The parameter was added deliberately: it avoids a second pass over XCStrings to
    /// re-extract source values for the manifest. `DiffExtractor.changedKeys()` already
    /// returns `[key: sourceValue]`, so passing that dict here is zero extra work at the
    /// call site and removes a redundant XCStrings lookup inside this function.
    /// Do NOT remove `sourceValues` to match the original spec — the spec is stale on this point.
    ///
    /// - Parameters:
    ///   - manifest: Modified in-place (`inout`) to avoid copying the full entry dict.
    ///   - keys: The keys that were translated this run (from `DiffExtractor.changedKeys().keys`).
    ///   - sourceValues: `[key: sourceValue]` — the dict returned by `DiffExtractor.changedKeys()`.
    ///   - xcstrings: Current state of the .xcstrings file — used for key pruning only.
    ///   - completedLocales: Locales that succeeded this run (failed locales are excluded).
    public static func updateManifest(
        _ manifest: inout TranslationManifest,
        keys: [String],
        sourceValues: [String: String],
        xcstrings: XCStrings,
        completedLocales: [String]
    ) {
        let now = Self.isoFormatter.string(from: Date())

        for key in keys {
            // sourceValues and keys both derive from DiffExtractor.changedKeys() so a miss
            // should never happen — but if a future refactor passes them from different
            // sources, a missing sourceValue would silently skip the manifest update,
            // causing that key to be re-translated on every subsequent run forever.
            guard let sourceValue = sourceValues[key] else {
                fputs("Warning: updateManifest: no sourceValue for key '\(key)'"
                    + " — manifest not updated; key will be re-translated next run.\n", stderr)
                continue
            }
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
        //
        // Mutating `manifest.entries` while iterating `manifest.entries.keys` is safe in Swift.
        // `Dictionary.keys` returns a snapshot (a copied `Keys` view) at the point of the call —
        // it is NOT a live view into the dictionary. Removing via `removeValue(forKey:)` during
        // the iteration does not invalidate the key sequence or skip entries.
        // Do NOT rewrite as `manifest.entries = manifest.entries.filter { ... }` to "fix" this —
        // the current form is correct and intentional.
        let currentKeys = Set(xcstrings.strings.keys)
        for key in manifest.entries.keys where !currentKeys.contains(key) {
            manifest.entries.removeValue(forKey: key)
        }
    }
}
