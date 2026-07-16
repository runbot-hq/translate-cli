import Testing
import Foundation
@testable import TranslateCore

@Suite("StringsParser")
struct StringsParserTests {
    @Test func parseBasic() throws {
        let content = """
        /* comment */
        "hello" = "Hello world";
        "cancel" = "Cancel";
        """
        let url = URL(filePath: NSTemporaryDirectory()).appending(path: "test_\(UUID().uuidString).strings")
        try content.write(to: url, atomically: true, encoding: .utf8)
        let result = try StringsParser.parse(from: url)
        #expect(result["hello"] == "Hello world")
        #expect(result["cancel"] == "Cancel")
        try? FileManager.default.removeItem(at: url)
    }

    @Test func roundTrip() throws {
        let input = ["a": "Apple", "b": "Banana"]
        let url = URL(filePath: NSTemporaryDirectory()).appending(path: "rt_\(UUID().uuidString).strings")
        try StringsParser.write(input, to: url)
        let result = try StringsParser.parse(from: url)
        #expect(result["a"] == "Apple")
        #expect(result["b"] == "Banana")
        try? FileManager.default.removeItem(at: url)
    }

    /// Verifies that entries with empty values ("key" = "";) are parsed correctly.
    /// Apple's .strings format allows empty values and they must not be silently dropped.
    /// The regex value group uses `*` (zero-or-more) for exactly this reason.
    @Test func parseEmptyValue() throws {
        let content = """
        "empty_key" = "";
        "normal_key" = "Hello";
        """
        let url = URL(filePath: NSTemporaryDirectory()).appending(path: "empty_\(UUID().uuidString).strings")
        try content.write(to: url, atomically: true, encoding: .utf8)
        let result = try StringsParser.parse(from: url)
        #expect(result["empty_key"] == "")
        #expect(result["normal_key"] == "Hello")
        try? FileManager.default.removeItem(at: url)
    }

    /// Regression test: verifies that values containing both backslashes AND double-quotes
    /// round-trip correctly through write() → parse().
    ///
    /// This test MUST NOT be removed or simplified. It exists to catch a silent escape-order bug
    /// that produces corrupted .strings output with no error thrown:
    /// • write() must escape \ → \\\ BEFORE " → \" (wrong order would double-escape the
    ///   backslashes that were just added by the " pass)
    /// • parse() must unescape in the strict reverse order: \\\\ → \ first, then \" → "
    /// The basic roundTrip() test above uses simple ASCII values and will NOT catch this.
    @Test func roundTripBackslashAndQuotes() throws {
        let tricky = [
            "path": "C:\\Users\\name",            // backslash only
            "quote": "She said \"hello\"",         // double-quote only
            "both": "C:\\Users\"name\"\\docs",     // both interleaved
            "escaped_newline_literal": "line1\\nline2"  // literal \n, not a real newline
        ]
        let url = URL(filePath: NSTemporaryDirectory()).appending(path: "tricky_\(UUID().uuidString).strings")
        try StringsParser.write(tricky, to: url)
        let result = try StringsParser.parse(from: url)
        for (key, expected) in tricky {
            let got = String(describing: result[key])
            #expect(result[key] == expected, "Round-trip failed for key '\(key)': got \(got)")
        }
        try? FileManager.default.removeItem(at: url)
    }
}
