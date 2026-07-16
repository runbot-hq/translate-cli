import Testing
import Foundation
@testable import TranslateCore

@Suite("XCStringsParser")
struct XCStringsParserTests {
    @Test func roundTrip() throws {
        let original = XCStrings(
            version: "1.0",
            sourceLanguage: "en",
            strings: [
                "ok": XCStringEntry(localizations: [
                    "en": XCLocalization(stringUnit: XCStringUnit(state: "new", value: "OK")),
                    "de": XCLocalization(stringUnit: XCStringUnit(state: "translated", value: "OK"))
                ])
            ]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(original)
        let decoded = try JSONDecoder().decode(XCStrings.self, from: data)
        #expect(decoded.sourceLanguage == "en")
        #expect(decoded.strings["ok"]?.localizations?["de"]?.stringUnit?.value == "OK")
    }
}
