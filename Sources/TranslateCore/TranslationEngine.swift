// TranslationEngine.swift
// Adapted from hotchpotch/mac-translate-cli (MIT)
// https://github.com/hotchpotch/mac-translate-cli
// Original author: hotchpotch. Adapted for TranslateCore by runbot-hq.
//
// ⚠️ CONCURRENCY: TranslationSession is NOT safe to call concurrently.
// The per-locale loop in main.swift MUST be sequential (plain `for` loop).
// Do NOT use async let, TaskGroup, or withThrowingTaskGroup across locales.
// Parallel calls silently corrupt translations — no runtime error, wrong output.
//
// AVAILABILITY:
// TranslationSession(installedSource:target:preferredStrategy:) requires macOS 26.4+.
// On macOS 26.0–26.3, preferredStrategy: does not exist — we fall back to the
// unqualified init and emit a warning to stderr. The quality input is silently
// ignored on those OS versions; callers always get OS-default quality.
// This is intentional — see the else-if branch below.

import Foundation
import Translation

// MARK: - Quality

/// Mirrors the two TranslationSession strategy tiers exposed by the CLI `--quality` flag.
/// `.high` maps to `.highFidelity` (Apple Intelligence tier, macOS 26.4+).
/// `.fast` maps to `.lowLatency` (on-device NMT, all macOS 26+ versions).
public enum TranslationQuality: String, Sendable {
    case fast
    case high
}

// MARK: - Errors

public enum TranslationEngineError: Error, CustomStringConvertible {
    case unsupportedPair(source: String, target: String)
    case languagePackNotInstalled(source: String, target: String)
    case requiresmacOS26(String)

    public var description: String {
        switch self {
        case let .unsupportedPair(source, target):
            return "Unsupported language pair: \(source) → \(target)"
        case let .languagePackNotInstalled(source, target):
            return "Language pack not installed: \(source) → \(target). Download via System Settings → Language & Region → Translation Languages."
        case let .requiresmacOS26(feature):
            return "\(feature) requires macOS 26+"
        }
    }
}

// MARK: - Engine

/// Wraps Apple's Translation framework for batch key→value translation.
///
/// Declared as `actor` to satisfy Swift 6 concurrency requirements on `TranslationSession`
/// usage — not because concurrent calls are safe. The per-locale loop in main.swift
/// must remain sequential regardless of this actor wrapper.
public actor TranslationEngine {
    public let quality: TranslationQuality

    public init(quality: TranslationQuality = .high) {
        self.quality = quality
    }

    /// Translates a dictionary of key→sourceText pairs into the target locale.
    ///
    /// - Parameters:
    ///   - pairs: `[key: sourceText]` — `key` is used as `clientIdentifier` and echoed back
    ///     in the response so translations can be matched without relying on ordering.
    ///   - sourceLocale: Locale of the source strings (e.g. `Locale(identifier: "en")`).
    ///   - targetLocale: Locale to translate into.
    /// - Returns: `[key: translatedText]` — same keys as input.
    /// - Throws: `TranslationEngineError` for unsupported pairs or missing language packs.
    public func translate(
        _ pairs: [String: String],
        from sourceLocale: Locale,
        to targetLocale: Locale
    ) async throws -> [String: String] {
        guard !pairs.isEmpty else { return [:] }

        let sourceLanguage = sourceLocale.language
        let targetLanguage = targetLocale.language

        if #available(macOS 26.4, *) {
            // preferredStrategy: is available — check language pack status before creating session.
            // Without this availability check, TranslationSession throws an opaque error for
            // missing packs that is hard to surface as an actionable message to the caller.
            let strategy: TranslationSession.Strategy = quality == .high ? .highFidelity : .lowLatency
            let availability = LanguageAvailability(preferredStrategy: strategy)
            let status = await availability.status(from: sourceLanguage, to: targetLanguage)
            switch status {
            case .installed:
                break
            case .supported:
                // Pack is supported but not downloaded. Distinguish from .unsupported so callers
                // can surface a targeted "download pack" message rather than a generic error.
                throw TranslationEngineError.languagePackNotInstalled(
                    source: sourceLocale.identifier,
                    target: targetLocale.identifier
                )
            case .unsupported:
                throw TranslationEngineError.unsupportedPair(
                    source: sourceLocale.identifier,
                    target: targetLocale.identifier
                )
            @unknown default:
                // New availability status added by Apple — treat conservatively as unsupported
                // so the caller skips the locale rather than attempting a translation that may panic.
                throw TranslationEngineError.unsupportedPair(
                    source: sourceLocale.identifier,
                    target: targetLocale.identifier
                )
            }

            let session = TranslationSession(
                installedSource: sourceLanguage,
                target: targetLanguage,
                preferredStrategy: strategy
            )
            return try await runBatch(pairs: pairs, session: session)
        } else if #available(macOS 26.0, *) {
            // macOS 26.0–26.3: preferredStrategy: does not exist — unavailable API, not a bug.
            // We deliberately fall back to the unqualified init and warn via stderr.
            // Callers on these OS versions always get OS-default quality regardless of --quality flag.
            // This is a known, documented limitation — not a regression.
            fputs("Warning: macOS 26.4+ required for \(quality == .high ? ".highFidelity" : ".lowLatency") strategy; falling back to default quality (macOS \(ProcessInfo.processInfo.operatingSystemVersionString))\n", stderr)
            let session = TranslationSession(installedSource: sourceLanguage, target: targetLanguage)
            return try await runBatch(pairs: pairs, session: session)
        } else {
            throw TranslationEngineError.requiresmacOS26("Translation framework")
        }
    }

}

// MARK: - Batch execution

// runBatch is a free function (not a method on TranslationEngine) so that
// `TranslationSession` never crosses the actor boundary — the session is created
// by the caller inside the actor and passed in here directly.
// Keeping it free avoids a stored-property solution that would require
// additional lifecycle management.
private func runBatch(pairs: [String: String], session: TranslationSession) async throws -> [String: String] {
    // clientIdentifier echoes the key back in the response, so we can re-associate
    // translated values with their keys regardless of response ordering.
    let requests = pairs.map { key, value in
        TranslationSession.Request(sourceText: value, clientIdentifier: key)
    }
    var result: [String: String] = [:]
    let responses = try await session.translations(from: requests)
    for response in responses {
        // clientIdentifier is optional in the API but we always set it above.
        // The guard is defensive — a nil identifier would silently drop a translation.
        guard let key = response.clientIdentifier else { continue }
        result[key] = response.targetText
    }
    return result
}
