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

// MARK: - Translating protocol

/// Abstraction over batch key→value translation. Exists so `MarkdownTranslator`
/// (and tests) can accept a stub without subclassing the concrete `TranslationEngine` actor.
public protocol Translating: Actor {
    func translate(
        _ pairs: [String: String],
        from sourceLocale: Locale,
        to targetLocale: Locale
    ) async throws -> [String: String]
}

// MARK: - Engine

/// Wraps Apple's Translation framework for batch key→value translation.
///
/// Declared as `actor` to satisfy Swift 6 concurrency requirements on `TranslationSession`
/// usage — not because concurrent calls are safe. The per-locale loop in main.swift
/// must remain sequential regardless of this actor wrapper.
public actor TranslationEngine: Translating {
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
                // A new LanguageAvailability status was added by Apple that we don't recognise.
                // Warn to stderr so the runner log captures it, then treat as unsupported so
                // the caller skips this locale rather than attempting a translation that may panic.
                // If you see this warning, check for a newer Apple Translation framework release
                // and update the switch to handle the new case explicitly.
                fputs("Warning: unrecognised LanguageAvailability status for \(sourceLocale.identifier) → \(targetLocale.identifier); treating as unsupported. Update TranslationEngine if a new status case was added.\n", stderr)
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
            //
            // ⚠️ Language pack errors on macOS 26.0–26.3:
            // On these OS versions we cannot call LanguageAvailability (requires 26.4), so we
            // skip the pack-status preflight check. If the language pack is missing, Apple's
            // framework throws an opaque error whose message we do not control and which may
            // NOT contain the substring "language pack not installed".
            // Consequence: the TypeScript action's isFatalTranslateError() may NOT match the
            // error and will retry it (up to once) rather than surfacing it as fatal.
            // This is acceptable for v1 — the retry is harmless and the error will still
            // surface on attempt 2. If you ever run on 26.0–26.3 runners and see spurious
            // retries for missing packs, add the opaque error substring to isFatalTranslateError.
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
    // Apple does not explicitly guarantee that responses preserve request order or even that
    // response count must exactly equal request count. We therefore re-associate strictly by
    // clientIdentifier instead of zipping arrays or trusting positional correspondence.
    // That makes reordering safe and gives us a single defensive place to detect missing IDs.
    for response in responses {
        // clientIdentifier is optional in the Apple API but we always set it above.
        // A nil here means Apple's framework returned a response without echoing our key back —
        // that key's translation is silently lost: the merger won't write it and the manifest
        // won't record it, so subsequent runs will re-translate it forever.
        // We warn to stderr so the runner log captures it if it ever fires.
        guard let key = response.clientIdentifier else {
            fputs("Warning: TranslationSession returned a response with nil clientIdentifier — translation for one key was dropped. This is an Apple framework bug; the key will be retried on the next run.\n", stderr)
            continue
        }
        result[key] = response.targetText
    }
    // Post-loop completeness check: Apple does not guarantee that every request yields
    // a response. A response can be absent entirely (no entry at all, not just nil ID).
    // The per-response nil-ID guard above catches corrupt echoes; this catches silent drops.
    // If result.count < pairs.count, one or more keys were silently lost by the framework.
    // Those keys will be retried on the next run (manifest won't record them).
    if result.count < pairs.count {
        let dropped = pairs.count - result.count
        fputs("Warning: TranslationSession returned \(dropped) fewer response(s) than requests — \(dropped) key(s) silently dropped by Apple framework. They will be retried on the next run.\n", stderr)
    }
    return result
}
