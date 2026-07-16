// main.swift — TranslateCLI entry point
//
// ⚠️ CONCURRENCY: The per-locale loop (step 6) is SEQUENTIAL — plain `for` loop.
// TranslationSession is a singleton and is NOT safe to call concurrently.
// Do NOT convert to async let, withTaskGroup, or withThrowingTaskGroup.
// Parallel locale calls silently corrupt translations; there is no runtime error.

import Foundation
import ArgumentParser
import TranslateCore

@main
struct TranslateCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "translate-cli",
        abstract: "On-device .xcstrings / .strings / markdown translation via Apple Translation framework."
    )

    @Option(help: "Path to source .xcstrings, .strings, or markdown file.")
    var input: String

    @Option(help: "Write path (defaults to --input path for xcstrings/markdown; dirname(input) for strings).")
    var output: String?

    @Option(help: "Path to .translation-manifest.json (defaults to dirname(input)/.translation-manifest.json).")
    var manifest: String?

    @Option(help: "Path to localization.config.json — CLI reads targetLanguages directly from this file.")
    var config: String?

    @Option(help: "Comma-separated target locale codes, e.g. de,fr,ja. Takes precedence over --config if both are provided.")
    var languages: String?

    @Option(help: "Translation quality: high (Apple Intelligence / highFidelity, requires macOS 26.4+) or fast (lowLatency NMT).")
    var quality: String = "high"

    @Option(help: "Input format: xcstrings | strings | markdown.")
    var format: String = "xcstrings"

    // --source-language overrides the sourceLanguage field read from the .xcstrings file.
    // Required when translating .strings files (which have no embedded source language)
    // and when the .xcstrings sourceLanguage field does not match the actual source.
    @Option(name: .customLong("source-language"), help: "Source language code override (default: read from .xcstrings sourceLanguage field, or 'en').")
    var sourceLanguage: String?

    // --debug enables verbose stderr logging throughout the translation pipeline.
    // This is intentionally a CLI flag (not an env var) so the action can control
    // CLI verbosity independently of the runner's RUNNER_DEBUG infrastructure.
    // Setting ACTIONS_STEP_DEBUG at runtime in the same process has no effect on
    // core.isDebug() / core.debug() because the runner reads RUNNER_DEBUG at startup.
    @Flag(name: .customLong("debug"), help: "Enable verbose debug logging to stderr.")
    var debug: Bool = false

    mutating func run() async throws {
        if debug {
            fputs("[translate-cli] debug mode enabled\n", stderr)
        }

        // 1. Resolve target locales
        // --languages takes precedence; fall back to --config; error if neither.
        let targetLocales: [String]
        if let langs = languages, !langs.isEmpty {
            targetLocales = langs.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        } else if let configPath = config {
            let cfg = try LocalizationConfigLoader.load(from: configPath)
            targetLocales = cfg.targetLanguages
            if debug { fputs("[translate-cli] loaded \(targetLocales.count) locales from config: \(targetLocales.joined(separator: ", "))\n", stderr) }
        } else {
            fputs("Error: provide --languages or --config\n", stderr)
            throw ExitCode.failure
        }

        guard !targetLocales.isEmpty else {
            fputs("Error: no target locales resolved\n", stderr)
            throw ExitCode.failure
        }

        // outputPath default: for xcstrings and markdown, in-place (== input path) is correct.
        // For strings format, the correct default is dirname(input) — lproj subdirs are written
        // under that directory. If the caller omits --output with --format strings, we resolve
        // dirname here so the CLI behaves correctly even when called directly (not via the action,
        // which always passes --output explicitly).
        let outputPath: String
        if output == nil && format == "strings" {
            outputPath = URL(filePath: input).deletingLastPathComponent().path
        } else {
            outputPath = output ?? input
        }
        if debug { fputs("[translate-cli] input=\(input) output=\(outputPath) format=\(format) quality=\(quality)\n", stderr) }

        let q: TranslationQuality = quality == "fast" ? .fast : .high
        let engine = TranslationEngine(quality: q)

        // 2. Markdown mode — stateless, no manifest read/write.
        if format == "markdown" {
            let text = try String(contentsOfFile: input, encoding: .utf8)
            var allTranslated: [String] = []
            var completedLocales: [String] = []
            var failedLocales: [String] = []

            for localeCode in targetLocales {
                let targetLocale = Locale(identifier: localeCode)
                if debug { fputs("[translate-cli] translating markdown to \(localeCode)\n", stderr) }
                do {
                    let result = try await MarkdownTranslator.translate(
                        text,
                        from: Locale(identifier: sourceLanguage ?? "en"),
                        to: targetLocale,
                        using: engine
                    )
                    allTranslated.append("## \(localeCode)\n\n\(result)")
                    completedLocales.append(localeCode)
                    if debug { fputs("[translate-cli] ✓ \(localeCode)\n", stderr) }
                } catch {
                    fputs("Warning: failed to translate to \(localeCode): \(error)\n", stderr)
                    failedLocales.append(localeCode)
                }
            }

            let combined = allTranslated.joined(separator: "\n\n---\n\n")
            try combined.write(toFile: outputPath, atomically: true, encoding: .utf8)

            print("keys_translated=\(completedLocales.isEmpty ? 0 : 1)")
            print("languages_completed=\(completedLocales.joined(separator: ","))")
            print("languages_failed=\(failedLocales.joined(separator: ","))")
            return
        }

        // 3. Resolve manifest path.
        let manifestPath: String
        if let m = manifest {
            manifestPath = m
        } else {
            let inputURL = URL(filePath: input)
            manifestPath = inputURL.deletingLastPathComponent()
                .appending(path: ".translation-manifest.json").path
        }
        if debug { fputs("[translate-cli] manifest=\(manifestPath)\n", stderr) }

        // 4. Load source file.
        var xcstrings: XCStrings
        var stringsDict: [String: String] = [:]
        let sourceLocale: Locale

        if format == "xcstrings" {
            xcstrings = try XCStringsParser.parse(from: URL(filePath: input))
            sourceLocale = Locale(identifier: sourceLanguage ?? xcstrings.sourceLanguage)
        } else if format == "strings" {
            stringsDict = try StringsParser.parse(from: URL(filePath: input))
            let srcLang = sourceLanguage ?? "en"
            xcstrings = XCStrings(sourceLanguage: srcLang, strings: stringsDict.reduce(into: [:]) { acc, kv in
                acc[kv.key] = XCStringEntry(localizations: [
                    srcLang: XCLocalization(stringUnit: XCStringUnit(state: "new", value: kv.value))
                ])
            })
            sourceLocale = Locale(identifier: srcLang)
        } else {
            fputs("Error: unknown format \(format). Use xcstrings, strings, or markdown.\n", stderr)
            throw ExitCode.failure
        }
        if debug { fputs("[translate-cli] sourceLocale=\(sourceLocale.identifier)\n", stderr) }

        // 5. Diff: find keys that need translation.
        var translationManifest = try ManifestHandler.load(from: manifestPath)
        let changedKeys = DiffExtractor.changedKeys(
            xcstrings: xcstrings,
            manifest: translationManifest,
            targetLocales: targetLocales
        )
        if debug { fputs("[translate-cli] changedKeys=\(changedKeys.count)\n", stderr) }

        if changedKeys.isEmpty {
            print("keys_translated=0")
            print("languages_completed=")
            print("languages_failed=")
            return
        }

        // 6. Translate — SEQUENTIAL, one locale at a time. See concurrency warning above.
        var completedLocales: [String] = []
        var failedLocales: [String] = []

        for localeCode in targetLocales {
            let targetLocale = Locale(identifier: localeCode)
            if debug { fputs("[translate-cli] translating \(changedKeys.count) keys to \(localeCode)\n", stderr) }
            do {
                let translated = try await engine.translate(
                    changedKeys,
                    from: sourceLocale,
                    to: targetLocale
                )
                xcstrings = TranslationMerger.merge(
                    base: xcstrings,
                    slice: translated,
                    locale: localeCode
                )
                completedLocales.append(localeCode)
                if debug { fputs("[translate-cli] ✓ \(localeCode) (\(translated.count) keys)\n", stderr) }
            } catch {
                fputs("Warning: failed to translate to \(localeCode): \(error)\n", stderr)
                failedLocales.append(localeCode)
            }
        }

        // 7. Write output.
        if format == "xcstrings" {
            try XCStringsParser.write(xcstrings, to: URL(filePath: outputPath))
        } else if format == "strings" {
            let outputDir = URL(filePath: outputPath)
            let inputFilename = URL(filePath: input).deletingPathExtension().lastPathComponent
            for localeCode in completedLocales {
                var out: [String: String] = [:]
                for (key, entry) in xcstrings.strings {
                    if let loc = entry.localizations?[localeCode],
                       let value = loc.stringUnit?.value {
                        out[key] = value
                    }
                }
                if out.isEmpty { continue }
                let lprojDir = outputDir.appending(path: "\(localeCode).lproj")
                try FileManager.default.createDirectory(at: lprojDir, withIntermediateDirectories: true)
                let stringsFile = lprojDir.appending(path: "\(inputFilename).strings")
                try StringsParser.write(out, to: stringsFile)
            }
        }
        if debug { fputs("[translate-cli] wrote output to \(outputPath)\n", stderr) }

        // 8. Update manifest.
        if !completedLocales.isEmpty {
            TranslationMerger.updateManifest(
                &translationManifest,
                keys: Array(changedKeys.keys),
                sourceValues: changedKeys,
                xcstrings: xcstrings,
                completedLocales: completedLocales
            )
            try ManifestHandler.save(translationManifest, to: manifestPath)
            if debug { fputs("[translate-cli] manifest saved to \(manifestPath)\n", stderr) }
        }

        // 9. Stdout output — parsed by TypeScript action's parseOutput().
        print("keys_translated=\(changedKeys.count)")
        print("languages_completed=\(completedLocales.joined(separator: ","))")
        print("languages_failed=\(failedLocales.joined(separator: ","))")
    }
}
