// LocalizationConfig.swift
// Codable model for localization.config.json — consumed by the Swift CLI directly
// via the --config flag. The TypeScript action passes --config to the CLI and
// never reads this file itself, keeping the CLI self-contained and testable outside CI.

import Foundation

/// Represents `localization.config.json` in the consuming repo.
///
/// This file is the primary way non-developers configure translation:
/// they can edit it directly on GitHub.com to add/remove languages without
/// touching workflow YAML.
///
/// `quality` and `inputFile` are optional — they duplicate CLI flags and
/// are provided for convenience. CLI flags always take precedence if both are set.
public struct LocalizationConfig: Codable, Sendable {
    /// Source language code (e.g. `"en"`). Overridden by `--source-language` CLI flag if provided.
    public var sourceLanguage: String
    /// Target language codes (e.g. `["de", "fr", "ja"]`). Overridden by `--languages` CLI flag if provided.
    public var targetLanguages: [String]
    /// Optional quality hint (`"high"` or `"fast"`). Overridden by `--quality` CLI flag.
    public var quality: String?
    /// Optional default input file path. Not used by the CLI — for documentation/tooling only.
    public var inputFile: String?
}

/// Loads and decodes `localization.config.json`.
public enum LocalizationConfigLoader {
    public static func load(from path: String) throws -> LocalizationConfig {
        let url = URL(filePath: path)
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(LocalizationConfig.self, from: data)
    }
}
