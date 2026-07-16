// ManifestHandlerTests.swift
// Tests for ManifestHandler load/save round-trip and absent-file behaviour.
// ManifestHandler is pure I/O — tests write to a temp directory and clean up.

import Testing
import Foundation
@testable import TranslateCore

@Suite("ManifestHandler")
struct ManifestHandlerTests {

    // MARK: - Absent file

    /// Correctness invariant: loading from a path that doesn't exist must return an empty
    /// manifest, not throw. This is how DiffExtractor detects "first run" (all keys new).
    /// If this ever throws, every first-run would fail with a file-not-found error.
    @Test func absentPath_returnsEmptyManifest() throws {
        let path = NSTemporaryDirectory() + "nonexistent-\(UUID().uuidString).json"
        let manifest = try ManifestHandler.load(from: path)
        #expect(manifest.entries.isEmpty)
        #expect(manifest.version == 1)
    }

    // MARK: - Round-trip

    /// Save then load must yield identical data. Covers encoder settings (prettyPrinted,
    /// sortedKeys) and atomic write — if either is broken the decode will fail or
    /// the data will differ.
    @Test func roundTrip_saveAndLoad() throws {
        let dir = NSTemporaryDirectory()
        let path = dir + "manifest-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: path) }

        var manifest = TranslationManifest()
        manifest.entries["greeting"] = ManifestEntry(
            sourceValue: "Hello",
            translatedAt: "2026-07-16T00:00:00Z",
            locales: ["de", "fr"]
        )
        manifest.entries["farewell"] = ManifestEntry(
            sourceValue: "Goodbye",
            translatedAt: "2026-07-16T00:00:00Z",
            locales: ["de"]
        )

        try ManifestHandler.save(manifest, to: path)
        let loaded = try ManifestHandler.load(from: path)

        #expect(loaded.version == 1)
        #expect(loaded.entries.count == 2)
        #expect(loaded.entries["greeting"]?.sourceValue == "Hello")
        #expect(loaded.entries["greeting"]?.locales == ["de", "fr"])
        #expect(loaded.entries["farewell"]?.sourceValue == "Goodbye")
        #expect(loaded.entries["farewell"]?.locales == ["de"])
    }

    // MARK: - Overwrite

    /// Saving twice to the same path must overwrite cleanly (atomic write).
    /// If .atomic fails silently, the second load could return stale data.
    @Test func overwrite_replacesExisting() throws {
        let path = NSTemporaryDirectory() + "manifest-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: path) }

        var first = TranslationManifest()
        first.entries["key"] = ManifestEntry(sourceValue: "old", translatedAt: "2026-01-01T00:00:00Z", locales: ["de"])
        try ManifestHandler.save(first, to: path)

        var second = TranslationManifest()
        second.entries["key"] = ManifestEntry(
            sourceValue: "new", translatedAt: "2026-07-16T00:00:00Z", locales: ["de", "fr"])
        try ManifestHandler.save(second, to: path)

        let loaded = try ManifestHandler.load(from: path)
        #expect(loaded.entries["key"]?.sourceValue == "new")
        #expect(loaded.entries["key"]?.locales == ["de", "fr"])
    }

    // MARK: - Empty manifest

    /// An explicitly empty manifest (no entries) round-trips cleanly.
    /// Guards against a future encoder change that omits empty-dict fields.
    @Test func emptyManifest_roundTrips() throws {
        let path = NSTemporaryDirectory() + "manifest-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: path) }

        let empty = TranslationManifest()
        try ManifestHandler.save(empty, to: path)
        let loaded = try ManifestHandler.load(from: path)
        #expect(loaded.entries.isEmpty)
        #expect(loaded.version == 1)
    }
}
