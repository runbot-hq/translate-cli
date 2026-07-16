// XCStringsParser.swift
// Adapted from scriptingosx/translate-cli (Apache-2.0)
// https://github.com/scriptingosx/translate-cli
// Original author: Armin Briegel. Adapted for TranslateCore by runbot-hq.

import Foundation

// MARK: - Codable Models

public struct XCStrings: Codable, Sendable {
    public var version: String
    public var sourceLanguage: String
    public var strings: [String: XCStringEntry]

    public init(version: String = "1.0", sourceLanguage: String = "en", strings: [String: XCStringEntry] = [:]) {
        self.version = version
        self.sourceLanguage = sourceLanguage
        self.strings = strings
    }
}

public struct XCStringEntry: Codable, Sendable {
    public var comment: String?
    public var extractionState: String?
    public var localizations: [String: XCLocalization]?

    public init(comment: String? = nil, extractionState: String? = nil, localizations: [String: XCLocalization]? = nil) {
        self.comment = comment
        self.extractionState = extractionState
        self.localizations = localizations
    }
}

public struct XCLocalization: Codable, Sendable {
    public var stringUnit: XCStringUnit?

    public init(stringUnit: XCStringUnit? = nil) {
        self.stringUnit = stringUnit
    }
}

public struct XCStringUnit: Codable, Sendable {
    public var state: String
    public var value: String

    public init(state: String, value: String) {
        self.state = state
        self.value = value
    }
}

// MARK: - Parser

public enum XCStringsParser {
    public static func parse(from url: URL) throws -> XCStrings {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        return try decoder.decode(XCStrings.self, from: data)
    }

    public static func write(_ xcstrings: XCStrings, to url: URL) throws {
        let encoder = JSONEncoder()
        // sortedKeys for stable git diffs; prettyPrinted for human readability
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(xcstrings)
        try data.write(to: url, options: .atomic)
    }
}
