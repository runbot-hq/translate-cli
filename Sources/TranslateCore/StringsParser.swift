// StringsParser.swift
// Parse/write legacy .strings "key" = "value"; format.

import Foundation

public enum StringsParser {
    // Matches: "key" = "value";
    // Handles escaped quotes and backslashes inside values.
    // nonisolated(unsafe): Regex is not Sendable in Swift 6 but is constructed once
    // at module load and never mutated — safe to share across isolation contexts.
    nonisolated(unsafe) private static let linePattern = #/^\s*"((?:[^"\\]|\\.)+)"\s*=\s*"((?:[^"\\]|\\.)+)"\s*;/#

    public static func parse(from url: URL) throws -> [String: String] {
        let raw = try String(contentsOf: url, encoding: .utf8)
        var result: [String: String] = [:]
        // Strip block comments /* ... */ before line matching
        let stripped = raw.replacing(#/\/\*[\s\S]*?\*\//#, with: "")
        for line in stripped.components(separatedBy: "\n") {
            // Skip line comments
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") { continue }
            if let match = try? linePattern.firstMatch(in: line) {
                let key = String(match.output.1).replacingOccurrences(of: "\\\"", with: "\"")
                let value = String(match.output.2).replacingOccurrences(of: "\\\"", with: "\"")
                result[key] = value
            }
        }
        return result
    }

    public static func write(_ strings: [String: String], to url: URL) throws {
        let lines = strings.keys.sorted().map { key -> String in
            let escapedKey = key.replacingOccurrences(of: "\"", with: "\\\"")
            let escapedValue = strings[key]!.replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escapedKey)\" = \"\(escapedValue)\";"
        }
        let content = lines.joined(separator: "\n") + "\n"
        try content.write(to: url, atomically: true, encoding: .utf8)
    }
}
