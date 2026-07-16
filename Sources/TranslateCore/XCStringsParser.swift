// XCStringsParser.swift
// Adapted from scriptingosx/translate-cli (Apache-2.0)
// https://github.com/scriptingosx/translate-cli
// Original author: Armin Briegel. Adapted for TranslateCore by runbot-hq.

import Foundation

// MARK: - Codable Models

/// Root structure of an `.xcstrings` file.
/// `.xcstrings` is JSON under the hood — `JSONDecoder` handles it directly.
/// Only the fields we need are modelled here; Xcode-generated fields we don't
/// use (e.g. `localizedStringsVariants`) are silently ignored by the decoder.
public struct XCStrings: Codable, Sendable {
    public var version: String
    public var sourceLanguage: String
    public var strings: [String: XCStringEntry]

    /// - Parameter sourceLanguage: Default is `"en"` for convenience in tests and
    ///   `DiffExtractor.slice(from:keys:)`, which always passes `xcstrings.sourceLanguage`
    ///   explicitly from the parsed file value.
    ///   **All production call sites pass `sourceLanguage` explicitly** — the `"en"` default
    ///   is never reached in live code paths. Do NOT add a new call site that omits this
    ///   parameter; always pass the value read from the parsed `.xcstrings` file or the
    ///   caller-supplied `--source-language` flag. Hardcoding `"en"` at construction time
    ///   is the exact bug documented in issue #2103 post-ship amendments.
    public init(version: String = "1.0", sourceLanguage: String = "en", strings: [String: XCStringEntry] = [:]) {
        self.version = version
        self.sourceLanguage = sourceLanguage
        self.strings = strings
    }
}

/// One entry in the `strings` dict — one localizable key.
/// `comment` and `extractionState` are round-tripped unchanged so we don't corrupt
/// any Xcode metadata already in the file.
public struct XCStringEntry: Codable, Sendable {
    public var comment: String?
    public var extractionState: String?
    public var localizations: [String: XCLocalization]?

    public init(comment: String? = nil, extractionState: String? = nil,
                localizations: [String: XCLocalization]? = nil) {
        self.comment = comment
        self.extractionState = extractionState
        self.localizations = localizations
    }
}

/// Localization entry for one locale within an `XCStringEntry`.
public struct XCLocalization: Codable, Sendable {
    public var stringUnit: XCStringUnit?

    public init(stringUnit: XCStringUnit? = nil) {
        self.stringUnit = stringUnit
    }
}

/// The actual translated string and its review state.
/// `state` values recognised by Xcode: `"new"`, `"translated"`, `"needs_review"`.
/// We write `"translated"` for all machine-translated strings.
public struct XCStringUnit: Codable, Sendable {
    public var state: String
    public var value: String

    public init(state: String, value: String) {
        self.state = state
        self.value = value
    }
}

// MARK: - Parser

/// Reads and writes `.xcstrings` files via `JSONDecoder` / `JSONEncoder`.
public enum XCStringsParser {

    public static func parse(from url: URL) throws -> XCStrings {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(XCStrings.self, from: data)
    }

    public static func write(_ xcstrings: XCStrings, to url: URL) throws {
        let encoder = JSONEncoder()
        // sortedKeys: stable git diffs — prevents key-order churn between runs
        // prettyPrinted: .xcstrings files are human-reviewed; compact JSON would be hostile
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Append a trailing newline to match Xcode's output format.
        // JSONEncoder does not emit one, so the first write of an Xcode-authored file
        // would otherwise produce a 1-char diff (missing \n) — stable on all subsequent writes.
        var data = try encoder.encode(xcstrings)
        data.append(0x0A) // UTF-8 newline
        // Ensure parent directory exists before writing.
        // Call sites today always write to an existing directory (xcstrings: same dir as input;
        // strings: lproj dir created by writeOutput). This guard is defensive for future callers
        // that may supply a novel output path — without it data.write throws ENOENT with no
        // indication which directory was missing.
        let dir = url.deletingLastPathComponent().path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // .atomic: write to a temp file then rename — avoids a corrupt .xcstrings if interrupted
        try data.write(to: url, options: .atomic)
    }
}
