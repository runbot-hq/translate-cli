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
}
