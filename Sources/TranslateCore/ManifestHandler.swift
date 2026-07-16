// ManifestHandler.swift
// File I/O only. No diff logic here — see DiffExtractor.swift.

import Foundation

// MARK: - Models

public struct ManifestEntry: Codable, Sendable {
    public var sourceValue: String
    public var translatedAt: String   // ISO8601
    public var locales: [String]

    public init(sourceValue: String, translatedAt: String, locales: [String]) {
        self.sourceValue = sourceValue
        self.translatedAt = translatedAt
        self.locales = locales
    }
}

public struct TranslationManifest: Codable, Sendable {
    public var version: Int           // always 1
    public var entries: [String: ManifestEntry]

    public init() {
        self.version = 1
        self.entries = [:]
    }
}

// MARK: - Handler

public enum ManifestHandler {
    /// Loads manifest from path. Returns empty manifest if file is absent (first run).
    public static func load(from path: String) throws -> TranslationManifest {
        let url = URL(filePath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            return TranslationManifest()
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(TranslationManifest.self, from: data)
    }

    public static func save(_ manifest: TranslationManifest, to path: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        let url = URL(filePath: path)
        // Ensure parent directory exists
        let dir = url.deletingLastPathComponent().path
        if !FileManager.default.fileExists(atPath: dir) {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        try data.write(to: url, options: .atomic)
    }
}
