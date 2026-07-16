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

    @Option(help: "Comma-separated target locale codes, e.g. de,fr,ja. Takes precedence over --config.")
    var languages: String?

    @Option(help: "Translation quality: high (highFidelity, requires macOS 26.4+) or fast (lowLatency NMT).")
    var quality: String = "high"

    @Option(help: "Input format: xcstrings | strings | markdown.")
    var format: String = "xcstrings"

    // --source-language overrides the sourceLanguage field read from the .xcstrings file.
    // Required when translating .strings files (which have no embedded source language)
    // and when the .xcstrings sourceLanguage field does not match the actual source.
    // Default behaviour by format:
    //   xcstrings / markdown — reads sourceLanguage from the .xcstrings file; NO 'en' fallback.
    //   strings             — defaults to 'en' (no embedded source language in .strings files).
    @Option(name: .customLong("source-language"),
        help: """
        Source language override. xcstrings/markdown: reads from .xcstrings file \
        (no 'en' fallback). strings: defaults to 'en'. Set explicitly only when \
        the .xcstrings sourceLanguage is wrong or for non-English .strings sources.
        """)
    var sourceLanguage: String?

    // --debug: enables verbose stderr logging (TranslationEngine session steps, key counts, etc.).
    // Passed by the TypeScript action when the `debug` input is 'true'.
    // Uses .customLong to produce exactly `--debug` (not `--is-debug` from the property name).
    @Flag(name: .customLong("debug"), help: "Enable verbose debug output to stderr.")
    var isDebug: Bool = false

    mutating func run() async throws {
        // 1. Resolve target locales.
        // --languages takes precedence; fall back to --config; error if neither.
        //
        // Note: this step runs BEFORE the --format check (step 2 below). This means that
        // passing `--format markdown` without `--languages` or `--config` will produce
        // "Error: provide --languages or --config" before the markdown path is reached.
        // This is intentional — all formats need a target locale list, and resolving it
        // first gives a clear, actionable error regardless of format.
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

        // outputPath default: for xcstrings and markdown, in-place (== input path) is correct.
        // For strings format, the correct default is dirname(input) — lproj subdirs are written
        // under that directory. If the caller omits --output with --format strings, we resolve
        // dirname here so the CLI behaves correctly even when called directly (not via the action,
        // which always passes --output explicitly).
        //
        // `URL(filePath:)` is used throughout this file (not `URL(fileURLWithPath:)`).
        // `URL(filePath:)` requires macOS 13+ — this is intentional and fine: the package
        // minimum deployment target is macOS 26. Do NOT downgrade to `URL(fileURLWithPath:)`
        // to "support older OS versions" — the entire binary requires macOS 26 for
        // TranslationSession and LanguageAvailability anyway.
        let outputPath: String
        if output == nil && format == "strings" {
            outputPath = URL(filePath: input).deletingLastPathComponent().path
        } else {
            outputPath = output ?? input
        }
        let resolvedQuality: TranslationQuality = quality == "fast" ? .fast : .high
        let engine = TranslationEngine(quality: resolvedQuality)

        if isDebug {
            fputs("[debug] translate-cli starting\n", stderr)
            let localeList = targetLocales.joined(separator: ",")
            fputs("[debug] format=\(format) quality=\(quality) locales=\(localeList)\n", stderr)
            fputs("[debug] input=\(input) output=\(output ?? "(default)")\n", stderr)
        }

        // 2. Dispatch to format-specific handler.
        // Markdown is fully self-contained (stateless, no manifest). xcstrings and strings
        // share the diff/merge/manifest pipeline and are handled together in runStructured.
        if format == "markdown" {
            try await runMarkdown(targetLocales: targetLocales, outputPath: outputPath, engine: engine)
        } else {
            try await runStructured(targetLocales: targetLocales, outputPath: outputPath, engine: engine)
        }
    }

    // MARK: - Format handlers

    /// Handles `--format markdown` translation.
    /// Stateless — no manifest is read or written.
    private func runMarkdown(
        targetLocales: [String],
        outputPath: String,
        engine: TranslationEngine
    ) async throws {
        // input_text integration (used by the release-notes pipeline) passes content
        // as a file path with --format markdown; the action writes a temp file and
        // passes its path here.
        let text = try String(contentsOfFile: input, encoding: .utf8)
        var allTranslated: [String] = []
        var completedLocales: [String] = []
        var failedLocales: [String] = []

        for localeCode in targetLocales {
            let targetLocale = Locale(identifier: localeCode)
            do {
                let result = try await MarkdownTranslator.translate(
                    text,
                    // "en" default is correct for the current release-notes use case (always
                    // English source). Markdown has no embedded source-language field, so we
                    // cannot auto-detect it the way xcstrings mode does via xcstrings.sourceLanguage.
                    // If markdown ever needs non-English source support, change this to an explicit
                    // error when --source-language is omitted rather than silently defaulting to "en".
                    // xcstrings and strings modes are NOT affected — they handle source language
                    // independently and do not reach this code path.
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

        // Guard: do NOT write on total failure — empty string would silently clobber the
        // source file when --output is in-place (default). Mirrors runStructured early-exit.
        guard !allTranslated.isEmpty else {
            fputs("Warning: all locales failed in markdown mode — output file not written.\n", stderr)
            return
        }
        let combined = allTranslated.joined(separator: "\n\n---\n\n")
        try combined.write(toFile: outputPath, atomically: true, encoding: .utf8)

        // stdout: key=value lines parsed by TypeScript parseOutput(). Format is stable contract.
        //
        // keys_translated in markdown mode: the document is ONE unit, not a key count.
        // NOT a bug — intentional. Do NOT emit allTranslated.count (that conflates locales
        // with keys). Emits 1 if ≥1 locale completed, 0 if ALL locales failed.
        // Do NOT gate a commit on keys_translated > 0 in markdown mode — gate on
        // languages_completed != '' instead (the only reliable success signal here).
        // xcstrings/strings mode uses keys_translated differently (source-key diff count).
        // See issue #2103 §output-contract.
        print("keys_translated=\(completedLocales.isEmpty ? 0 : 1)")
        print("languages_completed=\(completedLocales.joined(separator: ","))")
        print("languages_failed=\(failedLocales.joined(separator: ","))")
    }

    /// Handles `--format xcstrings` and `--format strings` translation.
    /// Both formats share the diff/merge/manifest pipeline.
    private func runStructured(
        targetLocales: [String],
        outputPath: String,
        engine: TranslationEngine
    ) async throws {
        // 3–4. Resolve manifest path and load source file.
        let manifestPath = resolveManifestPath()

        // 4. Load source file (format-specific parsing extracted to loadSource).
        // FUTURE: Both loadSource and writeOutput must be updated together when adding formats.
        let (xcstringsLoaded, sourceLocale) = try loadSource()
        var xcstrings = xcstringsLoaded

        // 5. Diff: find keys that need translation.
        // Returns [key: sourceValue] — value is stored in the manifest so future
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

        // 6. Translate — SEQUENTIAL. See translateAllLocales for concurrency warning.
        let (completedLocales, failedLocales) = await translateAllLocales(
            changedKeys: changedKeys,
            sourceLocale: sourceLocale,
            targetLocales: targetLocales,
            engine: engine,
            xcstrings: &xcstrings
        )

        // 7. Write output (format-specific write extracted to writeOutput).
        // ⚠️ Atomicity gap: step 7 (write output) and step 8 (save manifest) are NOT atomic.
        // If killed between them the next run will re-translate — safe by design.
        // Guard: skip entirely when every locale failed — no point writing unmodified xcstrings
        // back to disk and bumping the file's mtime on a fully-failed run.
        //
        // writeOutput returns only the locales that were actually written to disk.
        // For xcstrings format this equals completedLocales (one file, all locales merged).
        // For strings format a locale can be dropped if all its translated values were empty
        // (degenerate Apple framework response). Those locales are moved to failedLocales so
        // the manifest does NOT record them as done — they will be retried on the next run.
        var writtenLocales: [String] = []
        // effectiveFailed starts as a copy of failedLocales (locales that threw during translation)
        // and may grow to include locales that translated successfully but produced all-empty output
        // (degenerate Apple framework response caught by writeOutput). Using a separate var rather
        // than mutating failedLocales avoids confusion: failedLocales is the "threw" set,
        // effectiveFailed is the union of threw + empty-output. Both are distinct failure modes.
        var effectiveFailed = failedLocales
        if !completedLocales.isEmpty {
            writtenLocales = try writeOutput(
                xcstrings: xcstrings,
                completedLocales: completedLocales,
                outputPath: outputPath
            )
            // Any locale engine.translate() succeeded for but writeOutput dropped (all-empty
            // translations) must be treated as failed so the manifest doesn't permanently
            // record it as complete with nothing written to disk.
            let emptySkipped = Set(completedLocales).subtracting(writtenLocales)
            if !emptySkipped.isEmpty {
                effectiveFailed += Array(emptySkipped).sorted()
            }
        }

        // 8. Update manifest — only after all locales are processed so partial-success
        // runs record the correct completed-locales union rather than a premature snapshot.
        // Use writtenLocales (not completedLocales) so only locales with real on-disk output
        // are recorded. Guard: skip manifest write entirely when nothing was written.
        if !writtenLocales.isEmpty {
            TranslationMerger.updateManifest(
                &translationManifest,
                keys: Array(changedKeys.keys),
                sourceValues: changedKeys,
                xcstrings: xcstrings,
                completedLocales: writtenLocales
            )
            try ManifestHandler.save(translationManifest, to: manifestPath)
        }

        // 9. Stdout output — parsed by the TypeScript action's parseOutput().
        // keys_translated = changedKeys.count (pre-flight diff; NOT keys×locales, NOT
        // "keys that succeeded"). Partial/total locale failure does NOT reduce this count.
        // ⚠️ Do NOT gate commit steps on keys_translated > 0 — it is non-zero even when every
        // locale failed and nothing was written. Correct gate: `languages_completed != ''`.
        // Full contract: issue #2103 §output-contract.
        print("keys_translated=\(changedKeys.count)")
        print("languages_completed=\(writtenLocales.joined(separator: ","))")
        print("languages_failed=\(effectiveFailed.joined(separator: ","))")
    }

    // MARK: - Translation loop

    /// Translates `changedKeys` into each target locale SEQUENTIALLY and merges results into `xcstrings`.
    ///
    /// ⚠️ DO NOT parallelise. TranslationSession is not concurrency-safe — parallel calls
    /// silently corrupt translations with no runtime error. The actor on TranslationEngine
    /// satisfies Swift 6 checks but does NOT make concurrent locale calls safe.
    ///
    /// **`inout XCStrings` across `async` — intentional and safe here:**
    /// `xcstrings` is passed `inout` so each locale's merge result accumulates into one value
    /// without extra copies. This is safe because:
    ///   1. The loop is strictly sequential — each `await engine.translate(...)` completes
    ///      before the next iteration begins.
    ///   2. `xcstrings` is not read or written anywhere else during this call.
    ///   3. Swift 6 enforces exclusive access for the duration of each `await` suspension;
    ///      attempting to alias `xcstrings` in a concurrent task would be a compile error.
    /// Do NOT refactor to `async let`/`TaskGroup` (breaks sequential guarantee, corrupts output).
    /// Do NOT remove `inout` — value-return is equivalent but copies the struct on every locale.
    ///
    /// Returns `(completedLocales, failedLocales)`.
    private func translateAllLocales(
        changedKeys: [String: String],
        sourceLocale: Locale,
        targetLocales: [String],
        engine: TranslationEngine,
        xcstrings: inout XCStrings
    ) async -> ([String], [String]) {
        var completed: [String] = []
        var failed: [String] = []
        for localeCode in targetLocales {
            do {
                let translated = try await engine.translate(
                    changedKeys, from: sourceLocale, to: Locale(identifier: localeCode))
                xcstrings = TranslationMerger.merge(base: xcstrings, slice: translated, locale: localeCode)
                completed.append(localeCode)
            } catch {
                fputs("Warning: failed to translate to \(localeCode): \(error)\n", stderr)
                failed.append(localeCode)
            }
        }
        return (completed, failed)
    }

    // MARK: - Source loading

    /// Resolves the manifest path: `--manifest` override when set, otherwise
    /// `.translation-manifest.json` co-located with the input file.
    private func resolveManifestPath() -> String {
        if let manifestOverride = manifest { return manifestOverride }
        return URL(filePath: input)
            .deletingLastPathComponent()
            .appending(path: ".translation-manifest.json")
            .path
    }

    /// Parses the input file into an XCStrings value and resolves the source locale.
    /// Supports `xcstrings` and `strings` formats.
    ///
    /// `.strings` files have no embedded source-language field. Defaulting to "en" here
    /// is intentional for that format only. Do NOT apply the same logic to `xcstrings`,
    /// which reads sourceLanguage from file metadata.
    private func loadSource() throws -> (XCStrings, Locale) {
        if format == "xcstrings" {
            let xcstrings = try XCStringsParser.parse(from: URL(filePath: input))
            return (xcstrings, Locale(identifier: sourceLanguage ?? xcstrings.sourceLanguage))
        } else if format == "strings" {
            let stringsDict = try StringsParser.parse(from: URL(filePath: input))
            let srcLang = sourceLanguage ?? "en"
            // Wrap flat [key: value] dict in XCStrings so the diff/merge pipeline is format-agnostic.
            let xcstrings = XCStrings(
                sourceLanguage: srcLang,
                strings: stringsDict.reduce(into: [:]) { acc, entry in
                    acc[entry.key] = XCStringEntry(localizations: [
                        srcLang: XCLocalization(stringUnit: XCStringUnit(state: "new", value: entry.value))
                    ])
                }
            )
            return (xcstrings, Locale(identifier: srcLang))
        } else {
            fputs("Error: unknown format \(format). Use xcstrings, strings, or markdown.\n", stderr)
            throw ExitCode.failure
        }
    }

    // MARK: - Output writing

    /// Writes translated XCStrings to disk in the appropriate format.
    ///
    /// For `strings` format one file is written per completed locale under
    /// `{outputPath}/{locale}.lproj/{inputFilename}.strings` to avoid the overwrite
    /// bug where successive locales would clobber a single output path.
    ///
    /// - Returns: The locales actually written to disk. For `xcstrings` this equals
    ///   `completedLocales` (all locales in one file). For `strings` a locale may be
    ///   omitted when all its translated values were empty (degenerate Apple framework
    ///   response) — caller must treat omitted locales as failed so the manifest does
    ///   not permanently record them as complete with nothing written to disk.
    ///   Return value is load-bearing: always capture it at every call site.
    private func writeOutput(
        xcstrings: XCStrings,
        completedLocales: [String],
        outputPath: String
    ) throws -> [String] {
        if format == "xcstrings" {
            try XCStringsParser.write(xcstrings, to: URL(filePath: outputPath))
            // xcstrings is one merged file — all completedLocales are written together.
            return completedLocales
        } else if format == "strings" {
            let outputDir = URL(filePath: outputPath)
            let inputFilename = URL(filePath: input).deletingPathExtension().lastPathComponent
            var written: [String] = []
            for localeCode in completedLocales {
                var out: [String: String] = [:]
                for (key, entry) in xcstrings.strings {
                    if let loc = entry.localizations?[localeCode],
                       let value = loc.stringUnit?.value {
                        out[key] = value
                    }
                }
                if out.isEmpty {
                    // Engine returned all-empty translated values for this locale — degenerate
                    // Apple framework response. Skip writing and do NOT add to `written`.
                    // The caller (runStructured) detects the omission and moves this locale
                    // to effectiveFailed, so the manifest will NOT record it as complete.
                    // On the next run DiffExtractor will re-queue these keys for this locale.
                    fputs("Warning: all translated values were empty for locale '\(localeCode)' "
                        + "— skipping .strings write; locale will be retried on next run.\n", stderr)
                    continue
                }
                let lprojDir = outputDir.appending(path: "\(localeCode).lproj")
                try FileManager.default.createDirectory(at: lprojDir, withIntermediateDirectories: true)
                let stringsFile = lprojDir.appending(path: "\(inputFilename).strings")
                try StringsParser.write(out, to: stringsFile)
                written.append(localeCode)
            }
            return written
        }
        // If a new structured format is added, writeOutput and loadSource must both be updated.
        // Reaching here means the format routing above is incomplete — fail loudly rather than
        // silently returning [] (which would suppress manifest writes and look like success).
        fatalError("writeOutput: unhandled format '\(format)' — add a branch above and update loadSource accordingly")
    }
}
