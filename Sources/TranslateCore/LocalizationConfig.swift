// LocalizationConfig.swift
// Codable model for localization.config.json.
// Read by the CLI directly via --config flag.
// The TypeScript action layer never reads this file directly —
// it passes --config path/to/localization.config.json to the CLI.

import Foundation

public struct LocalizationConfig: Codable, Sendable {
    public var sourceLanguage: String       // default "en"
    public var targetLanguages: [String]
    public var quality: String?             // "high" | "fast"
    public var inputFile: String?

    public init(
        sourceLanguage: String = "en",
        targetLanguages: [String],
        quality: String? = nil,
        inputFile: String? = nil
    ) {
        self.sourceLanguage = sourceLanguage
        self.targetLanguages = targetLanguages
        self.quality = quality
        self.inputFile = inputFile
    }
}

public enum LocalizationConfigLoader {
    public static func load(from path: String) throws -> LocalizationConfig {
        let url = URL(filePath: path)
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(LocalizationConfig.self, from: data)
    }
}
