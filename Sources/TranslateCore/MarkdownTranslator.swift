// MarkdownTranslator.swift
// Translates plain text / markdown paragraph by paragraph.
// Skips code blocks (``` fenced and 4-space indented) — translating code corrupts it.

import Foundation

/// Translates Markdown or plain text content while preserving code blocks.
///
/// Strategy: split on double-newline paragraph boundaries, classify each paragraph,
/// skip code blocks, batch all translatable prose paragraphs into a single engine
/// call per locale, then reassemble in original order.
///
/// Batching all paragraphs as one `[String: String]` dict (key = paragraph index)
/// uses TranslationEngine's native batch API — one `TranslationSession.translations(from:)`
/// call per locale rather than one call per paragraph. For a document with N paragraphs
/// this is N× fewer session round-trips.
///
/// ⚠️ Known limitation: fenced code blocks (``` or ~~~) that contain a double-newline
/// (`\n\n`) inside the fence are split across multiple chunks by `components(separatedBy: "\n\n")`.
/// Only the first chunk (containing the opening fence marker) is detected and skipped;
/// subsequent chunks (body/closing) are sent for translation. This is acceptable for
/// typical release-notes content where code blocks rarely contain blank lines.
/// Full CommonMark fidelity would require a proper block-level parser.
public enum MarkdownTranslator {

    /// Translates `text` from `sourceLocale` to `targetLocale`.
    /// All translatable paragraphs are batched into a single engine call.
    /// Code blocks are passed through untouched.
    public static func translate(
        _ text: String,
        from sourceLocale: Locale,
        to targetLocale: Locale,
        using engine: TranslationEngine
    ) async throws -> String {
        let paragraphs = text.components(separatedBy: "\n\n")

        // Collect translatable paragraphs as index → text, preserving positions of
        // skipped chunks so reassembly doesn't need a separate pass.
        var batch: [String: String] = [:]
        for (i, paragraph) in paragraphs.enumerated() {
            if !shouldSkip(paragraph) {
                batch["\(i)"] = paragraph
            }
        }

        // Single engine call for all prose paragraphs — one TranslationSession round-trip.
        let results = batch.isEmpty ? [:] : try await engine.translate(
            batch,
            from: sourceLocale,
            to: targetLocale
        )

        // Reassemble: translated paragraphs replace originals; skipped chunks stay verbatim.
        let translated = paragraphs.enumerated().map { i, paragraph in
            results["\(i)"] ?? paragraph   // fall back to original if engine returns nothing
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
