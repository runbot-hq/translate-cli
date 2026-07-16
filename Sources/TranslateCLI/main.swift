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

    mutating func run() async throws {
        // 1. Resolve target locales
        // --languages takes precedence; fall back to --config; error if neither.
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

        // 2. Markdown mode — stateless, no manifest read/write.
        // input_text integration (used by the release-notes pipeline) passes content
        // as a file path with --format markdown; the action writes a temp file and
        // passes its path here.
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

            // Output lines are parsed by the TypeScript action's parseOutput() function.
            // Format must remain key=value, one per line, no extra whitespace.
            //
            // keys_translated=1 in markdown mode: the document is one translatable unit.
            // We do NOT emit allTranslated.count (number of locales) here — that would
            // conflate "locales" with "keys" and confuse callers using this output to
            // gate a commit step. The per-locale results are fully represented by
            // languages_completed and languages_failed.
            print("keys_translated=\(completedLocales.isEmpty ? 0 : 1)")
            print("languages_completed=\(completedLocales.joined(separator: ","))")
            print("languages_failed=\(failedLocales.joined(separator: ","))")
            return
        }

        // 3. Resolve manifest path.
        // Default: dirname(input)/.translation-manifest.json — always co-located with the
        // .xcstrings file so it's committed to the repo in the natural place.
        // --manifest overrides this for non-standard repo layouts.
        let manifestPath: String
        if let m = manifest {
            manifestPath = m
        } else {
            let inputURL = URL(filePath: input)
            manifestPath = inputURL.deletingLastPathComponent()
                .appending(path: ".translation-manifest.json").path
        }

        // 4. Load source file.
        // .strings files are converted to an internal XCStrings representation so
        // DiffExtractor and TranslationMerger can operate uniformly on both formats.
        var xcstrings: XCStrings
        var stringsDict: [String: String] = [:]
        let sourceLocale: Locale

        if format == "xcstrings" {
            xcstrings = try XCStringsParser.parse(from: URL(filePath: input))
            sourceLocale = Locale(identifier: sourceLanguage ?? xcstrings.sourceLanguage)
        } else if format == "strings" {
            stringsDict = try StringsParser.parse(from: URL(filePath: input))
            let srcLang = sourceLanguage ?? "en"
            // Wrap flat [key: value] dict in XCStrings so the diff/merge pipeline is format-agnostic
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

        // 5. Diff: find keys that need translation.
        // Returns [key: englishSourceValue] — value is stored in the manifest so future
        // runs can detect source-string changes without re-reading the xcstrings file.
        var translationManifest = try ManifestHandler.load(from: manifestPath)
        let changedKeys = DiffExtractor.changedKeys(
            xcstrings: xcstrings,
            manifest: translationManifest,
            targetLocales: targetLocales
        )

        if changedKeys.isEmpty {
            // No keys changed — exit cleanly with zero counts. The action treats this as
            // a no-op (no commit, no PR) rather than a failure.
            print("keys_translated=0")
            print("languages_completed=")
            print("languages_failed=")
            return
        }

        // 6. Translate — SEQUENTIAL, one locale at a time. See concurrency warning above.
        // Failed locales are collected and surfaced via languages_failed output;
        // they do not abort the remaining locales.
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

        // 7. Write output.
        // .strings: one file per locale in {outputDir}/{locale}.lproj/{inputFilename}.strings
        // Writing per-locale into lproj subdirs avoids the overwrite bug where a single
        // output path would be clobbered by each successive locale in the loop.
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

        // 8. Update manifest — only after all locales are processed so partial-success
        // runs record the correct completed-locales union rather than a premature snapshot.
        // Guard: skip manifest write entirely when every locale failed. Writing with an
        // empty completedLocales array would bump translatedAt timestamps without any
        // translation having occurred, making the audit log misleading. On the next run,
        // DiffExtractor will still flag the same keys (no target locale in manifest) and
        // retranslation will proceed correctly — so skipping here is safe.
        if !completedLocales.isEmpty {
            TranslationMerger.updateManifest(
                &translationManifest,
                keys: Array(changedKeys.keys),
                sourceValues: changedKeys,
                xcstrings: xcstrings,
                completedLocales: completedLocales
            )
            try ManifestHandler.save(translationManifest, to: manifestPath)
        }

        // 9. Stdout output — parsed by TypeScript action's parseOutput() function.
        //
        // keys_translated = changedKeys.count (keys that needed translation, pre-flight diff).
        // This is intentionally NOT "keys that succeeded per locale" — partial locale failures
        // do not reduce the count. The authoritative per-locale success/failure signal is
        // languages_completed / languages_failed. Callers should gate commits on
        // languages_completed being non-empty, not on keys_translated alone.
        // This design is documented in issue #2103 §output-contract.
        print("keys_translated=\(changedKeys.count)")
        print("languages_completed=\(completedLocales.joined(separator: ","))")
        print("languages_failed=\(failedLocales.joined(separator: ","))")
    }
}
