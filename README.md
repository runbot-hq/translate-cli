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

Requires Swift 6 toolchain (Xcode 16+).

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
| `--source-language` | From `.xcstrings` `sourceLanguage`, or `en` | Source language override |
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
