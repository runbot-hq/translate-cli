// main.swift — TranslateCLI entry point
// ⚠️ Per-locale loop is SEQUENTIAL. Never use async let or TaskGroup across locales.
// TranslationSession is not safe to call concurrently.

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

    @Option(help: "Write path (defaults to --input path).")
    var output: String?

    @Option(help: "Path to .translation-manifest.json (defaults to dirname(input)/.translation-manifest.json).")
    var manifest: String?

    @Option(help: "Path to localization.config.json — CLI reads this directly.")
    var config: String?

    @Option(help: "Comma-separated target locale codes, e.g. de,fr,ja. Overrides --config if provided.")
    var languages: String?

    @Option(help: "Translation quality: high (Apple Intelligence) or fast (NMT).")
    var quality: String = "high"

    @Option(help: "Input format: xcstrings | strings | markdown.")
    var format: String = "xcstrings"

    @Option(name: .customLong("source-language"), help: "Source language code override (default: read from .xcstrings sourceLanguage field, or 'en').")
    var sourceLanguage: String?

    mutating func run() async throws {
        // 1. Resolve target locales
        let targetLocales: [String]
        if let langs = languages, !langs.isEmpty {
            targetLocales = langs.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        } else if let configPath = config {
            let cfg = try LocalizationConfigLoader.load(from: configPath)
            targetLocales = cfg.targetLanguages
        } else {
            fputs("Error: provide --languages or --config\n", stderr)
            throw ExitCode.failure
        }

        guard !targetLocales.isEmpty else {
            fputs("Error: no target locales resolved\n", stderr)
            throw ExitCode.failure
        }

        let outputPath = output ?? input
        let q: TranslationQuality = quality == "fast" ? .fast : .high
        let engine = TranslationEngine(quality: q)

        // 2. Markdown / input_text mode — stateless, no manifest
        if format == "markdown" {
            let text = try String(contentsOfFile: input, encoding: .utf8)
            var allTranslated: [String] = []
            var completedLocales: [String] = []
            var failedLocales: [String] = []

            for localeCode in targetLocales {
                let targetLocale = Locale(identifier: localeCode)
                do {
                    let result = try await MarkdownTranslator.translate(
                        text,
                        from: Locale(identifier: sourceLanguage ?? "en"),
                        to: targetLocale,
                        using: engine
                    )
                    allTranslated.append("## \(localeCode)\n\n\(result)")
                    completedLocales.append(localeCode)
                } catch {
                    fputs("Warning: failed to translate to \(localeCode): \(error)\n", stderr)
                    failedLocales.append(localeCode)
                }
            }

            let combined = allTranslated.joined(separator: "\n\n---\n\n")
            try combined.write(toFile: outputPath, atomically: true, encoding: .utf8)

            print("keys_translated=\(allTranslated.count)")
            print("languages_completed=\(completedLocales.joined(separator: ","))")
            print("languages_failed=\(failedLocales.joined(separator: ","))")
            return
        }

        // 3. Resolve manifest path: dirname(input)/.translation-manifest.json
        let manifestPath: String
        if let m = manifest {
            manifestPath = m
        } else {
            let inputURL = URL(filePath: input)
            manifestPath = inputURL.deletingLastPathComponent()
                .appending(path: ".translation-manifest.json").path
        }

        // 4. Load xcstrings or strings
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

        // 5. Diff
        var translationManifest = try ManifestHandler.load(from: manifestPath)
        let changedKeys = DiffExtractor.changedKeys(
            xcstrings: xcstrings,
            manifest: translationManifest,
            targetLocales: targetLocales
        )

        if changedKeys.isEmpty {
            print("keys_translated=0")
            print("languages_completed=")
            print("languages_failed=")
            return
        }

        // 6. Translate sequentially per locale — NEVER parallelize
        var completedLocales: [String] = []
        var failedLocales: [String] = []

        for localeCode in targetLocales {
            let targetLocale = Locale(identifier: localeCode)
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
            } catch {
                fputs("Warning: failed to translate to \(localeCode): \(error)\n", stderr)
                failedLocales.append(localeCode)
            }
        }

        // 7. Write output
        if format == "xcstrings" {
            try XCStringsParser.write(xcstrings, to: URL(filePath: outputPath))
        } else if format == "strings" {
            // Write one .strings file per locale into outputDir / {locale}.lproj/Localizable.strings
            // outputPath is treated as a directory; each locale gets its own lproj subdirectory.
            // This avoids the single-path overwrite bug where multiple locales clobber each other.
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

        // 8. Update manifest
        TranslationMerger.updateManifest(
            &translationManifest,
            keys: Array(changedKeys.keys),
            sourceValues: changedKeys,
            xcstrings: xcstrings,
            completedLocales: completedLocales
        )
        try ManifestHandler.save(translationManifest, to: manifestPath)

        // 9. Stdout key=value output
        print("keys_translated=\(changedKeys.count)")
        print("languages_completed=\(completedLocales.joined(separator: ","))")
        print("languages_failed=\(failedLocales.joined(separator: ","))")
    }
}
