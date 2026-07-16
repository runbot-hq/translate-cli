import Testing
@testable import TranslateCore

@Suite("DiffExtractor")
struct DiffExtractorTests {
    func makeXCStrings(keys: [String: String], source: String = "en") -> XCStrings {
        let strings = keys.reduce(into: [String: XCStringEntry]()) { acc, kv in
            acc[kv.key] = XCStringEntry(localizations: [
                source: XCLocalization(stringUnit: XCStringUnit(state: "new", value: kv.value))
            ])
        }
        return XCStrings(version: "1.0", sourceLanguage: source, strings: strings)
    }

    @Test func newKey_notInManifest() {
        let xcstrings = makeXCStrings(keys: ["hello": "Hello"])
        let manifest = TranslationManifest()
        let result = DiffExtractor.changedKeys(xcstrings: xcstrings, manifest: manifest, targetLocales: ["de"])
        #expect(result["hello"] == "Hello")
    }

    @Test func changedSource_triggersRetranslation() {
        let xcstrings = makeXCStrings(keys: ["greeting": "Hello world"])
        var manifest = TranslationManifest()
        manifest.entries["greeting"] = ManifestEntry(sourceValue: "Hello", translatedAt: "2026-01-01T00:00:00Z", locales: ["de"])
        let result = DiffExtractor.changedKeys(xcstrings: xcstrings, manifest: manifest, targetLocales: ["de"])
        #expect(result["greeting"] == "Hello world")
    }

    @Test func unchangedSource_notReturned() {
        let xcstrings = makeXCStrings(keys: ["cancel": "Cancel"])
        var manifest = TranslationManifest()
        manifest.entries["cancel"] = ManifestEntry(sourceValue: "Cancel", translatedAt: "2026-01-01T00:00:00Z", locales: ["de"])
        let result = DiffExtractor.changedKeys(xcstrings: xcstrings, manifest: manifest, targetLocales: ["de"])
        #expect(result["cancel"] == nil)
    }

    @Test func newLocale_triggersRetranslation() {
        let xcstrings = makeXCStrings(keys: ["cancel": "Cancel"])
        var manifest = TranslationManifest()
        manifest.entries["cancel"] = ManifestEntry(sourceValue: "Cancel", translatedAt: "2026-01-01T00:00:00Z", locales: ["de"])
        let result = DiffExtractor.changedKeys(xcstrings: xcstrings, manifest: manifest, targetLocales: ["de", "fr"])
        #expect(result["cancel"] == "Cancel")
    }

    @Test func emptyManifest_firstRun() {
        let xcstrings = makeXCStrings(keys: ["a": "A", "b": "B"])
        let manifest = TranslationManifest()
        let result = DiffExtractor.changedKeys(xcstrings: xcstrings, manifest: manifest, targetLocales: ["de"])
        #expect(result.count == 2)
    }
}
