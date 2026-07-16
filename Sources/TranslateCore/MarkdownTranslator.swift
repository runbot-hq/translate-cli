// MarkdownTranslator.swift
// Translates plain text / markdown paragraph by paragraph.
// Skips code blocks (``` fenced and 4-space indented) — translating code corrupts it.

import Foundation

public enum MarkdownTranslator {
    public static func translate(
        _ text: String,
        from sourceLocale: Locale,
        to targetLocale: Locale,
        using engine: TranslationEngine
    ) async throws -> String {
        // Split on double-newline paragraph boundaries
        let paragraphs = text.components(separatedBy: "\n\n")
        var translated: [String] = []

        for paragraph in paragraphs {
            if shouldSkip(paragraph) {
                translated.append(paragraph)
            } else {
                let result = try await engine.translate(
                    ["p": paragraph],
                    from: sourceLocale,
                    to: targetLocale
                )
                translated.append(result["p"] ?? paragraph)
            }
        }

        return translated.joined(separator: "\n\n")
    }

    /// Returns true for chunks that must not be translated:
    ///   - Fenced code blocks (``` or ~~~)
    ///   - 4-space indented code blocks
    private static func shouldSkip(_ chunk: String) -> Bool {
        let trimmed = chunk.trimmingCharacters(in: .newlines)
        if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
            return true
        }
        // 4-space indented: every non-empty line starts with 4 spaces
        let lines = trimmed.components(separatedBy: "\n")
        let nonEmpty = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if !nonEmpty.isEmpty && nonEmpty.allSatisfy({ $0.hasPrefix("    ") }) {
            return true
        }
        return false
    }
}
