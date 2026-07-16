# translate-cli

A Swift 6 command-line tool (and `TranslateCore` library) that translates `.xcstrings`, `.strings`, and Markdown files using the Apple Translation framework — entirely on-device, no network, no API keys.

> **Requires:** macOS 26.0+ (arm64). Apple Translation language packs must be installed via **System Settings → Language & Region → Translation Languages**.

## Build

```sh
git clone https://github.com/runbot-hq/translate-cli.git
cd translate-cli
swift build -c release
# Binary at: .build/release/translate-cli
```

Requires Xcode 26+ (macOS 26 SDK). The binary targets macOS 26 and uses `TranslationSession` / `LanguageAvailability` APIs that ship with macOS 26 — earlier Xcode versions will not have the required SDK.

## Usage

```
translate-cli --input <path> [--output <path>] [--languages <codes>] [--config <path>]
              [--manifest <path>] [--source-language <code>]
              [--quality high|fast] [--format xcstrings|strings|markdown]
```

### Flags

| Flag | Default | Description |
|------|---------|-------------|
| `--input` | *(required)* | Source `.xcstrings`, `.strings`, or `.md` file |
| `--output` | Same as `--input` | Write path. For `strings` format this is a **directory** — lproj subdirs are created automatically. |
| `--languages` | — | Comma-separated target locale codes, e.g. `de,fr,ja,zh-Hans`. Overrides `--config`. |
| `--config` | — | Path to `localization.config.json` with `targetLanguages` array |
| `--manifest` | `dirname(input)/.translation-manifest.json` | Path to incremental manifest (created on first run) |
| `--source-language` | `xcstrings`/`markdown`: reads from `.xcstrings` file (no `en` fallback); `strings`: `en` | Source language override. Set only when the `.xcstrings` `sourceLanguage` field is wrong or for non-English `.strings` sources. |
| `--quality` | `high` | `high` = highFidelity (Apple Intelligence); `fast` = lowLatency (NMT) |
| `--format` | `xcstrings` | `xcstrings`, `strings`, or `markdown` |

### Stdout output

All output is `key=value` pairs on stdout:

```
keys_translated=42
languages_completed=de,fr,ja
languages_failed=
```

Warnings and errors go to stderr.

> **Important — commit gate:** `keys_translated` is a *pre-flight diff count* (the number of
> source strings that changed). It can be `> 0` even when every locale failed. **Always gate
> commit or PR steps on `languages_completed` being non-empty**, not on `keys_translated > 0`.
> `languages_completed` is empty when every locale failed, regardless of how many keys were diffed.

> **Markdown format limitation (v1):** Fenced code blocks that contain blank lines (`\n\n`
> inside the fence) will be split into multiple chunks by the paragraph splitter. Only the
> opening chunk (starting with ` ``` `) is skipped; interior chunks are sent to the translation
> engine. This is a known v1 limitation. Avoid blank lines inside fenced code blocks in
> documents translated with `--format markdown`.

## Examples

### Translate an `.xcstrings` file in-place

```sh
translate-cli --input Sources/App/Localizable.xcstrings --languages de,fr,ja,zh-Hans
```

### Translate to a subset of languages, fast quality

```sh
translate-cli --input Sources/App/Localizable.xcstrings --languages de,fr --quality fast
```

### Translate `.strings` file, write per-locale lproj dirs

```sh
translate-cli --input Sources/App/en.lproj/Localizable.strings \
              --format strings \
              --output Sources/App/ \
              --languages de,fr,ja
# Writes: Sources/App/de.lproj/Localizable.strings
#         Sources/App/fr.lproj/Localizable.strings
#         Sources/App/ja.lproj/Localizable.strings
```

### Translate Markdown release notes to multiple locales

```sh
translate-cli --input RELEASE_NOTES.md \
              --format markdown \
              --output RELEASE_NOTES_TRANSLATED.md \
              --languages de,fr,ja,zh-Hans
```

The output file contains all locales separated by `---` dividers.

### Use a config file

```sh
translate-cli --input Sources/App/Localizable.xcstrings \
              --config localization.config.json
```

`localization.config.json`:
```json
{ "targetLanguages": ["de", "fr", "ja", "zh-Hans"] }
```

## Incremental translation

On first run, a `.translation-manifest.json` is created alongside the input file. On subsequent runs, only changed or new keys are translated — existing translations are preserved. Commit the manifest file alongside your `.xcstrings` to make incremental translation work in CI.

## Attribution

This project was informed by two earlier open-source implementations of Apple Translation CLI wrappers:

- [**scriptingosx/translate-cli**](https://github.com/scriptingosx/translate-cli) — Apache License 2.0
- [**hotchpotch/mac-translate-cli**](https://github.com/hotchpotch/mac-translate-cli) — MIT License

Thank you to both authors. No source code was copied; the architecture and API design are independent.

## License

MIT
