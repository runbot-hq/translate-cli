// ManifestHandler.swift
// File I/O only. No diff logic here — see DiffExtractor.swift.
//
// Separation rationale: keeping I/O and logic in separate types lets DiffExtractor
// be unit tested with in-memory data (no temp files, no FileManager mocking required).

import Foundation

// MARK: - Models

/// A single entry in the translation manifest: the source-language value at the time
/// of last translation, the timestamp, and which locales were translated.
/// `sourceValue` is the key used by DiffExtractor to detect changed source strings.
public struct ManifestEntry: Codable, Sendable {
    public var sourceValue: String
    public var translatedAt: String   // ISO8601, informational only — not used for diff logic
    public var locales: [String]      // sorted, union-merged on each run

    public init(sourceValue: String, translatedAt: String, locales: [String]) {
        self.sourceValue = sourceValue
        self.translatedAt = translatedAt
        self.locales = locales
    }
}

/// Root manifest structure. `version` is always 1 — reserved for future schema migrations.
public struct TranslationManifest: Codable, Sendable {
    public var version: Int           // always 1; increment if schema changes
    public var entries: [String: ManifestEntry]

    /// Creates an empty manifest (used on first run when no manifest file exists yet).
    public init() {
        self.version = 1
        self.entries = [:]
    }
}

// MARK: - Handler

/// Loads and saves `.translation-manifest.json`. Pure I/O — no business logic.
public enum ManifestHandler {

    /// Loads manifest from path. Returns an empty manifest if the file is absent.
    /// An absent file is not an error — it means this is the first run and all keys
    /// will be treated as new by DiffExtractor.
    public static func load(from path: String) throws -> TranslationManifest {
        let url = URL(filePath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            return TranslationManifest()
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(TranslationManifest.self, from: data)
    }

    /// Saves manifest to path. Creates intermediate directories if needed.
    /// Uses `.atomic` write to avoid a partial file if the process is interrupted.
    public static func save(_ manifest: TranslationManifest, to path: String) throws {
        let encoder = JSONEncoder()
        // sortedKeys: stable JSON diffs in git (no spurious key-order changes between runs)
        // prettyPrinted: human-readable — callers commit this file and may review it
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        let url = URL(filePath: path)
        // Create parent directory if it doesn't exist (e.g. first run in a new repo structure)
        let dir = url.deletingLastPathComponent().path
        if !FileManager.default.fileExists(atPath: dir) {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        try data.write(to: url, options: .atomic)
    }
}
