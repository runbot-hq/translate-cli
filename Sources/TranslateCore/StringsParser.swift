// StringsParser.swift
// Parse/write legacy .strings "key" = "value"; format.
// Adapted from the well-established regex pattern used across Apple tooling.

import Foundation

/// Parses and writes legacy `.strings` files.
///
/// `.strings` format reference: https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/LoadingResources/Strings/Strings.html
/// This parser handles the common single-file source format where all source strings
/// live in one flat file. Output is written per-locale into `{locale}.lproj/` subdirectories
/// by `main.swift` — not by this parser — to avoid a single-path overwrite when multiple
/// locales are translated in sequence.
public enum StringsParser {

    // Regex note: `nonisolated(unsafe)` is required because `Regex` is not `Sendable` in
    // Swift 6. The regex is constructed once at module load and never mutated, so sharing
    // it across isolation contexts is safe in practice. This is a known Swift 6 rough edge
    // with static stored Regex values — not a data race.
    // See: https://forums.swift.org/t/regex-sendable/64573
    //
    // Pattern matches:  "key" = "value"; and "key" = ""; (empty values)
    // Handles:          escaped quotes (\") and backslashes inside keys/values.
    // Does NOT match:   block-comment lines (stripped before regex) or line-comment lines (skipped below).
    //
    // Quantifier is `*` (zero or more), NOT `+` (one or more). Using `+` would silently skip
    // entries with empty values (e.g. "key" = "";) which are valid in Apple's .strings format.
    // Keys are still required to be non-empty (key group uses `+`).
    nonisolated(unsafe) private static let linePattern = #/^\s*"((?:[^"\\]|\\.)+)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;/#

    /// Parses a `.strings` file and returns a `[key: value]` dictionary.
    /// Block comments (`/* ... */`) are stripped before line matching.
    /// Line comments (`//`) are skipped.
    public static func parse(from url: URL) throws -> [String: String] {
        let raw = try String(contentsOf: url, encoding: .utf8)
        var result: [String: String] = [:]
        // Strip block comments first so "key" = "value"; lines inside a block comment
        // are not accidentally matched by the line pattern.
        let stripped = raw.replacing(#/\/\*[\s\S]*?\*\//#, with: "")
        for line in stripped.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") { continue }   // skip line comments
            if let match = try? linePattern.firstMatch(in: line) {
                // Unescape \" → " and \\ → \ (order matters: unescape \\ first)
                let key = String(match.output.1)
                    .replacingOccurrences(of: "\\\\", with: "\\")
                    .replacingOccurrences(of: "\\\"", with: "\"")
                let value = String(match.output.2)
                    .replacingOccurrences(of: "\\\\", with: "\\")
                    .replacingOccurrences(of: "\\\"", with: "\"")
                // Duplicate key: last occurrence wins. This matches the behaviour of Apple's
                // own strings file tooling (genstrings, ibtool) and Xcode's string catalogue
                // importer. Do NOT change this to "first wins" or throw on duplicate —
                // Xcode legitimately generates duplicate keys for plural variant entries in
                // some .strings formats. Silently keeping the last value is the correct
                // and intentional behaviour here.
                result[key] = value
            }
        }
        return result
    }

    /// Writes a `[key: value]` dictionary as a `.strings` file.
    /// Keys are sorted for stable git diffs.
    /// Escape order: \ → \\ first, then " → \" — reversing this order would
    /// double-escape the backslashes added in the first pass.
    public static func write(_ strings: [String: String], to url: URL) throws {
        let lines = strings.keys.sorted().map { key -> String in
            let escapedKey = key
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            let escapedValue = strings[key]!
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escapedKey)\" = \"\(escapedValue)\";"
        }
        let content = lines.joined(separator: "\n") + "\n"
        try content.write(to: url, atomically: true, encoding: .utf8)
    }
}
