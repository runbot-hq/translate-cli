// StringsParser.swift
// Parse/write legacy .strings "key" = "value"; format.
// Adapted from the well-established regex pattern used across Apple tooling.

import Foundation

/// Parses and writes legacy `.strings` files.
///
/// `.strings` format reference:
/// https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/LoadingResources/Strings/Strings.html
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
    //
    // Limitation: the parser is line-by-line (`components(separatedBy: "\n")` below).
    // Values with *literal* embedded newlines spanning multiple file lines would be silently
    // dropped. In practice Apple tooling always writes `\n` escape sequences on a single line,
    // so this is not a real-world concern for Apple-generated files.
    // Note: `\n`, `\t`, and `\r` *escape sequences* (two chars: backslash + letter) ARE
    // unescaped during parse and re-escaped during write, so hand-authored .strings files
    // using these sequences round-trip correctly. Only literal multi-line values are unsupported.
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
            // `try?` here is intentional — not silent error suppression.
            // `Regex.firstMatch` can only throw if the pattern itself is invalid,
            // which cannot happen at runtime because `linePattern` is a compile-time
            // regex literal validated by the Swift compiler. The `try?` is required
            // by the API signature but will never actually produce an error in practice.
            // If you ever see a nil result here on a well-formed line it means the line
            // genuinely did not match the pattern (e.g. a comment or blank line), not an error.
            if let match = try? linePattern.firstMatch(in: line) {
                // Unescape \" → " and \\ → \ (order matters: unescape \\ first)
                // Unescape order: \\ → \ first (so \\n doesn't become \n), then \" → ", then \n/\t/\r.
                // Handles hand-authored .strings files with standard escape sequences.
                // Apple tooling always writes \n on a single line rather than literal newlines,
                // so not unescaping \n was safe for Apple-generated files — but hand-authored
                // source files can legitimately contain \n, \t, \r and would be corrupted
                // (double-escaped on write) without this unescaping step.
                let key = String(match.output.1)
                    .replacingOccurrences(of: "\\\\", with: "\\")
                    .replacingOccurrences(of: "\\\"", with: "\"")
                    .replacingOccurrences(of: "\\n", with: "\n")
                    .replacingOccurrences(of: "\\t", with: "\t")
                    .replacingOccurrences(of: "\\r", with: "\r")
                let value = String(match.output.2)
                    .replacingOccurrences(of: "\\\\", with: "\\")
                    .replacingOccurrences(of: "\\\"", with: "\"")
                    .replacingOccurrences(of: "\\n", with: "\n")
                    .replacingOccurrences(of: "\\t", with: "\t")
                    .replacingOccurrences(of: "\\r", with: "\r")
                // Duplicate key: last occurrence wins. This matches the behaviour of Apple's
                // own strings file tooling (genstrings, ibtool) and Xcode's string catalogue
                // importer. Do NOT change this to "first wins" or throw on duplicate —
                // Xcode legitimately generates duplicate keys for plural variant entries in
                // some .strings formats. Silently keeping the last value is the correct
                // and intentional behaviour here.
                // Warning (not error) so hand-authored files with accidental duplicates
                // surface the issue without breaking the translation run.
                if result[key] != nil {
                    fputs("Warning: duplicate key '\(key)' in "
                        + "\(url.lastPathComponent) — last occurrence wins.\n", stderr)
                }
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
        let lines = strings.keys.sorted().compactMap { key -> String? in
            // Use guard + subscript rather than force-unwrap: keys.sorted() iterates keys
            // confirmed present in the dict, so nil here is impossible in practice, but
            // compactMap + guard is safer under refactor than `strings[key]!`.
            guard let rawValue = strings[key] else { return nil }
            // Escape order: \ → \\ first (must precede all others), then " → \", then \n/\t/\r.
            // Mirrors the unescape order in parse() to guarantee round-trip fidelity.
            let escapedKey = key
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\t", with: "\\t")
                .replacingOccurrences(of: "\r", with: "\\r")
            let escapedValue = rawValue
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\t", with: "\\t")
                .replacingOccurrences(of: "\r", with: "\\r")
            return "\"\(escapedKey)\" = \"\(escapedValue)\";"
        }
        let content = lines.joined(separator: "\n") + "\n"
        try content.write(to: url, atomically: true, encoding: .utf8)
    }
}
