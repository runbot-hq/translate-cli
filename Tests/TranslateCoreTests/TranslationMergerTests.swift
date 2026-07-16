import Testing
@testable import TranslateCore

@Suite("TranslationMerger")
struct TranslationMergerTests {
    func baseXCStrings() -> XCStrings {
        XCStrings(
            version: "1.0",
            sourceLanguage: "en",
            strings: [
                "save": XCStringEntry(localizations: [
                    "en": XCLocalization(stringUnit: XCStringUnit(state: "new", value: "Save"))
                ])
            ]
        )
    }

    @Test func merge_insertsTranslation() {
        let base = baseXCStrings()
        let result = TranslationMerger.merge(base: base, slice: ["save": "Speichern"], locale: "de")
        #expect(result.strings["save"]?.localizations?["de"]?.stringUnit?.value == "Speichern")
        #expect(result.strings["save"]?.localizations?["de"]?.stringUnit?.state == "translated")
    }

    @Test func merge_preservesExistingLocale() {
        let base = baseXCStrings()
        let result = TranslationMerger.merge(base: base, slice: ["save": "Enregistrer"], locale: "fr")
        // English should still be present
        #expect(result.strings["save"]?.localizations?["en"]?.stringUnit?.value == "Save")
        #expect(result.strings["save"]?.localizations?["fr"]?.stringUnit?.value == "Enregistrer")
    }

    @Test func updateManifest_addsEntry() {
        var base = baseXCStrings()
        var manifest = TranslationManifest()
        TranslationMerger.updateManifest(
            &manifest,
            keys: ["save"],
            sourceValues: ["save": "Save"],
            xcstrings: base,
            completedLocales: ["de"]
        )
        #expect(manifest.entries["save"]?.sourceValue == "Save")
        #expect(manifest.entries["save"]?.locales.contains("de") == true)
    }

    @Test func updateManifest_prunesDeletedKey() {
        var xcstrings = baseXCStrings()
        var manifest = TranslationManifest()
        manifest.entries["old_key"] = ManifestEntry(
            sourceValue: "Old", translatedAt: "2026-01-01T00:00:00Z", locales: ["de"])
        TranslationMerger.updateManifest(
            &manifest,
            keys: [],
            sourceValues: [:],
            xcstrings: xcstrings,
            completedLocales: []
        )
        #expect(manifest.entries["old_key"] == nil)
    }
}
