// MarkdownTranslator.swift
// Translates plain text / markdown paragraph by paragraph.
// Skips code blocks (``` fenced and 4-space indented) — translating code corrupts it.

import Foundation

/// Translates Markdown or plain text content while preserving code blocks.
///
/// Strategy: split on double-newline paragraph boundaries, classify each paragraph,
/// skip code blocks, translate prose paragraphs individually.
///
/// Paragraph-level translation (rather than full-document) keeps the request size
/// small and avoids token limits. Each paragraph is translated as a single
/// `["p": text]` pair — the key `"p"` is arbitrary; it just satisfies the
/// `TranslationEngine.translate(_:from:to:)` signature which takes `[String: String]`.
public enum MarkdownTranslator {

    /// Translates `text` from `sourceLocale` to `targetLocale` paragraph by paragraph.
    /// Code blocks are passed through untouched.
    public static func translate(
        _ text: String,
        from sourceLocale: Locale,
        to targetLocale: Locale,
        using engine: TranslationEngine
    ) async throws -> String {
        let paragraphs = text.components(separatedBy: "\n\n")
        var translated: [String] = []

        for paragraph in paragraphs {
            if shouldSkip(paragraph) {
                // Preserve code blocks, horizontal rules, and other non-prose chunks verbatim
                translated.append(paragraph)
            } else {
                let result = try await engine.translate(
                    ["p": paragraph],
                    from: sourceLocale,
                    to: targetLocale
                )
                // Fall back to the original paragraph if the engine returns nothing
                translated.append(result["p"] ?? paragraph)
            }
        }

        return translated.joined(separator: "\n\n")
    }

    /// Returns `true` for chunks that must not be translated.
    ///
    /// Skipped patterns:
    /// - **Fenced code blocks:** paragraph starts with ``` or ~~~
    /// - **4-space indented blocks:** every non-empty line starts with 4 spaces
    ///
    /// Note: inline code spans (backtick-wrapped text inside prose) are NOT skipped here.
    /// Apple's Translation framework treats inline code gracefully — it preserves
    /// backtick-wrapped spans and does not translate their contents.
    private static func shouldSkip(_ chunk: String) -> Bool {
        let trimmed = chunk.trimmingCharacters(in: .newlines)
        if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
            return true
        }
        // 4-space indented blocks: all non-empty lines must start with "    " (4 spaces)
        let lines = trimmed.components(separatedBy: "\n")
        let nonEmpty = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if !nonEmpty.isEmpty && nonEmpty.allSatisfy({ $0.hasPrefix("    ") }) {
            return true
        }
        return false
    }
}
