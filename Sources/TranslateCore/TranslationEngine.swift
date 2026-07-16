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
            return "Language pack not installed: \(source) → \(target). "
                + "Download via System Settings → Language & Region → Translation Languages."
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
/// usage — NOT because concurrent calls are safe.
///
/// Why `actor` if it doesn't make concurrent calls safe?
/// `TranslationSession` requires a specific actor-isolation pattern to compile under Swift 6
/// strict concurrency. Without the `actor` keyword here, constructing and using a
/// `TranslationSession` inside an `async` method triggers:
///   "sending 'self'-isolated value to nonisolated context risks causing data races"
/// The `actor` + `nonisolated runBatch` pattern resolves that diagnostic structurally
/// (session is never actor-isolated — see runBatch comments). It does NOT add any
/// thread-safety guarantee on top of what Apple's framework provides.
///
/// The per-locale loop in main.swift MUST remain a plain sequential `for` loop.
/// Do NOT add concurrency (async let / TaskGroup) to that loop — TranslationSession
/// is not safe to call from multiple concurrent tasks.
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
    ///
    /// ⚠️ NOT concurrency-safe across locales. Call this method sequentially (plain `for` loop).
    /// The actor wrapper satisfies Swift 6 type-checking but does NOT make simultaneous calls
    /// from different tasks safe — `TranslationSession` is not concurrency-safe and parallel
    /// calls silently corrupt output with no runtime error or crash.
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
                // A new LanguageAvailability status was added by Apple that we don't recognise yet.
                //
                // Why `.unsupported` (throw + skip) rather than `.installed` (proceed)?
                // Proceeding with an unrecognised status risks creating a TranslationSession
                // in an undefined state — which could corrupt output silently. Skipping is the
                // conservative, safe choice: the locale is retried on the next run, and the
                // warning below tells the developer exactly what to fix.
                //
                // This is NOT a lazy catch-all. Each known status is handled explicitly above.
                // @unknown default exists only for future Apple API additions we haven't seen yet.
                // If Apple adds .downloading or .pending in a future OS, add explicit cases here
                // rather than expanding this default.
                //
                // To fix: check for a newer Translation framework release, identify the new
                // LanguageAvailability case, and add it above with appropriate handling.
                let msg = "Warning: unrecognised LanguageAvailability status for "
                    + "\(sourceLocale.identifier) → \(targetLocale.identifier); "
                    + "treating as unsupported (safe fallback — locale will retry next run). "
                    + "Update TranslationEngine if a new LanguageAvailability case was added by Apple.\n"
                fputs(msg, stderr)
                throw TranslationEngineError.unsupportedPair(
                    source: sourceLocale.identifier,
                    target: targetLocale.identifier
                )
            }

            return try await runBatch(
                pairs: pairs,
                source: sourceLanguage,
                target: targetLanguage,
                strategy: strategy
            )
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
            let strategyName = quality == .high ? ".highFidelity" : ".lowLatency"
            let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
            fputs("Warning: macOS 26.4+ required for \(strategyName) strategy; "
                + "falling back to default quality (macOS \(osVersion))\n", stderr)
            return try await runBatch(pairs: pairs, source: sourceLanguage, target: targetLanguage)
        } else {
            throw TranslationEngineError.requiresmacOS26("Translation framework")
        }
    }

    // MARK: - Batch execution

    /// Executes a batch translation request by creating and immediately consuming a
    /// `TranslationSession` within a `nonisolated` context.
    ///
    /// `nonisolated` is the key constraint here: by making this method nonisolated,
    /// `session` is created and used entirely outside actor isolation. This means
    /// `session` is never an actor-isolated value, so calling Apple's `nonisolated`
    /// `translations(from:)` on it never triggers Swift 6's "sending actor-isolated
    /// value to nonisolated context" diagnostic.
    ///
    /// Previous form passed a pre-constructed `TranslationSession` into an actor method,
    /// which made the session actor-isolated; calling `translations(from:)` (nonisolated
    /// Apple API) on it then crossed the isolation boundary and produced the Swift 6 error:
    ///   "sending 'self'-isolated 'session' to nonisolated instance method risks data races"
    ///
    /// The session is always created immediately before use and discarded immediately after
    /// — it is never stored anywhere and never shared across calls.
    @available(macOS 26.4, *)
    private nonisolated func runBatch(
        pairs: [String: String],
        source: Locale.Language,
        target: Locale.Language,
        strategy: TranslationSession.Strategy
    ) async throws -> [String: String] {
        let session = TranslationSession(installedSource: source, target: target, preferredStrategy: strategy)
        return try await _runBatch(pairs: pairs, session: session)
    }

    @available(macOS 26.0, *)
    private nonisolated func runBatch(
        pairs: [String: String],
        source: Locale.Language,
        target: Locale.Language
    ) async throws -> [String: String] {
        let session = TranslationSession(installedSource: source, target: target)
        return try await _runBatch(pairs: pairs, session: session)
    }

    /// Core batch execution — shared by both `runBatch` overloads.
    /// Called from `nonisolated` context so `session` is never actor-isolated.
    private nonisolated func _runBatch(
        pairs: [String: String],
        session: TranslationSession
    ) async throws -> [String: String] {
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
                fputs("Warning: TranslationSession returned a response with nil clientIdentifier — "
                    + "translation for one key was dropped. "
                    + "This is an Apple framework bug; the key will be retried on the next run.\n", stderr)
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
            fputs("Warning: TranslationSession returned \(dropped) fewer response(s) than requests — "
                + "\(dropped) key(s) silently dropped by Apple framework. "
                + "They will be retried on the next run.\n", stderr)
        }
        return result
    }

}
