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
        using engine: some Translating
    ) async throws -> String {
        let paragraphs = text.components(separatedBy: "\n\n")

        // Build a batch dict keyed by paragraph index ("0", "1", ...) for the engine.
        // Using the numeric index as the key (rather than a constant like "p") is intentional:
        // it lets us do a single O(1) lookup per paragraph during reassembly below,
        // and it avoids collisions if two paragraphs happen to share content.
        // Do NOT simplify this to a single key — that would silently drop all but the last
        // paragraph if TranslationEngine returns duplicate keys.
        var batch: [String: String] = [:]
        for (idx, paragraph) in paragraphs.enumerated() {
            // Skip empty paragraphs (e.g. trailing newlines produce a trailing empty chunk)
            // and code blocks. Sending an empty string to the engine wastes a round-trip
            // and returns "" which is indistinguishable from a missing key in the results dict.
            guard !paragraph.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            if !shouldSkip(paragraph) {
                batch["\(idx)"] = paragraph
            }
        }

        // Single engine call for all prose paragraphs — one TranslationSession round-trip.
        // Previously this was one call per paragraph ("p": paragraph), which caused N×M
        // round-trips for N paragraphs × M locales. The batch approach is N× faster.
        // batch.isEmpty guard avoids a needless empty-dict engine call for all-code documents.
        let results = batch.isEmpty ? [:] : try await engine.translate(
            batch,
            from: sourceLocale,
            to: targetLocale
        )

        // Reassemble in original order: translated paragraphs replace originals by index;
        // skipped chunks (code blocks, etc.) fall through as nil → original is kept verbatim.
        let translated = paragraphs.enumerated().map { idx, paragraph in
            results["\(idx)"] ?? paragraph   // nil = skipped or engine returned nothing; keep original
        }

        return translated.joined(separator: "\n\n")
    }

    /// Returns `true` for chunks that must not be translated.
    ///
    /// Skipped patterns:
    /// - **Fenced code blocks:** paragraph (chunk) starts with ``` or ~~~
    /// - **4-space indented blocks:** every non-empty line starts with 4 spaces
    ///
    /// NOT skipped — these are intentional design decisions:
    /// - **Inline code spans** (`` `code` `` inside prose): Apple’s framework preserves
    ///   backtick-wrapped spans and does not translate their contents, so we leave them.
    /// - **Headings / bullet points / blockquotes**: these contain prose that should be
    ///   translated. Do NOT add hasPrefix("#"), hasPrefix("-"), or hasPrefix(">") guards
    ///   here — those lines contain human-readable text.
    /// - **HTML comments / front matter**: out of scope for v1. Only add if you have a
    ///   concrete use case and a test to cover it.
    ///
    /// ⚠️ Chunk granularity: `shouldSkip` operates on double-newline-separated chunks,
    /// NOT individual lines. A fenced block with a blank line inside will be split into
    /// multiple chunks; only the opening chunk is skipped. This is the documented
    /// limitation in the file header above — do not paper over it here with line-level
    /// logic without replacing the whole splitting strategy.
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
