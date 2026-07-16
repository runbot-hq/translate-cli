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

    /// Verifies that values containing both backslashes and double-quotes round-trip
    /// correctly through write() → parse(). This catches any escape-order bug:
    /// write() must escape \ before " (otherwise the second pass double-escapes the
    /// backslashes added in the first), and parse() must unescape in reverse order.
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
            #expect(result[key] == expected, "Round-trip failed for key '\(key)': got \(String(describing: result[key]))")
        }
        try? FileManager.default.removeItem(at: url)
    }
}
