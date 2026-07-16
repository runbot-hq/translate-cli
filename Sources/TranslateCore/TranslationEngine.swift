// TranslationEngine.swift
// Adapted from hotchpotch/mac-translate-cli (MIT)
// https://github.com/hotchpotch/mac-translate-cli
// Original author: hotchpotch. Adapted for TranslateCore by runbot-hq.
//
// ⚠️ CONCURRENCY CONSTRAINT:
// TranslationSession is NOT safe to call concurrently.
// The per-locale loop in main.swift MUST be sequential.
// Never use async let or TaskGroup across locales.
//
// AVAILABILITY:
// preferredStrategy APIs require macOS 26.4+.
// On macOS 26.0–26.3, we fall back to the unqualified
// TranslationSession(installedSource:target:) init which has no strategy param.

import Foundation
import Translation

// MARK: - Quality

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

public actor TranslationEngine {
    public let quality: TranslationQuality

    public init(quality: TranslationQuality = .high) {
        self.quality = quality
    }

    /// Translates a dictionary of key→sourceText pairs into the target locale.
    public func translate(
        _ pairs: [String: String],
        from sourceLocale: Locale,
        to targetLocale: Locale
    ) async throws -> [String: String] {
        guard !pairs.isEmpty else { return [:] }

        let sourceLanguage = sourceLocale.language
        let targetLanguage = targetLocale.language

        // Strategy APIs (preferredStrategy:) require macOS 26.4.
        // On 26.0–26.3, skip availability check and use base init — will throw at runtime
        // if language pack is not installed (same behaviour as before strategy APIs existed).
        if #available(macOS 26.4, *) {
            let strategy: TranslationSession.Strategy = quality == .high ? .highFidelity : .lowLatency
            let availability = LanguageAvailability(preferredStrategy: strategy)
            let status = await availability.status(from: sourceLanguage, to: targetLanguage)
            switch status {
            case .installed:
                break
            case .supported:
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
            // macOS 26.0–26.3: preferredStrategy: is unavailable (requires 26.4).
            // Falling back to unqualified init — quality setting is silently ignored.
            // Callers on 26.0–26.3 always get the OS default translation quality.
            fputs("Warning: macOS 26.4+ required for \(quality == .high ? ".highFidelity" : ".lowLatency") strategy; falling back to default quality (macOS \(ProcessInfo.processInfo.operatingSystemVersionString))\n", stderr)
            let session = TranslationSession(installedSource: sourceLanguage, target: targetLanguage)
            return try await runBatch(pairs: pairs, session: session)
        } else {
            throw TranslationEngineError.requiresmacOS26("Translation framework")
        }
    }

}

// Free function so TranslationSession never crosses the actor boundary
private func runBatch(pairs: [String: String], session: TranslationSession) async throws -> [String: String] {
    let requests = pairs.map { key, value in
        TranslationSession.Request(sourceText: value, clientIdentifier: key)
    }
    var result: [String: String] = [:]
    let responses = try await session.translations(from: requests)
    for response in responses {
        guard let key = response.clientIdentifier else { continue }
        result[key] = response.targetText
    }
    return result
}
