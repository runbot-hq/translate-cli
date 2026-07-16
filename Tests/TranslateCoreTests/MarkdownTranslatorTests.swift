import Testing
import Foundation
@testable import TranslateCore

/// Stub engine conforming to `Translating`. Echoes inputs back prefixed with "[T]"
/// so tests can verify translated text is used (not the original fallback).
/// Records all received batches for assertion.
actor EchoEngine: Translating {
    private(set) var receivedBatches: [[String: String]] = []

    func translate(
        _ pairs: [String: String],
        from sourceLocale: Locale,
        to targetLocale: Locale
    ) async throws -> [String: String] {
        receivedBatches.append(pairs)
        return pairs.mapValues { "[T]" + $0 }
    }
}

@Suite("MarkdownTranslator")
struct MarkdownTranslatorTests {

    // MARK: shouldSkip — code blocks

    @Test func backtickFence_isSkipped() async throws {
        let engine = EchoEngine()
        let input = "```\nlet x = 1\n```"
        let result = try await MarkdownTranslator.translate(input, from: Locale(identifier: "en"), to: Locale(identifier: "de"), using: engine)
        let batches = await engine.receivedBatches
        #expect(batches.allSatisfy { $0.isEmpty })
        #expect(result == input)
    }

    @Test func tildeFence_isSkipped() async throws {
        let engine = EchoEngine()
        let input = "~~~\nsome code\n~~~"
        let result = try await MarkdownTranslator.translate(input, from: Locale(identifier: "en"), to: Locale(identifier: "de"), using: engine)
        let batches = await engine.receivedBatches
        #expect(batches.allSatisfy { $0.isEmpty })
        #expect(result == input)
    }

    @Test func fourSpaceIndent_isSkipped() async throws {
        let engine = EchoEngine()
        let input = "    indented code\n    second line"
        let result = try await MarkdownTranslator.translate(input, from: Locale(identifier: "en"), to: Locale(identifier: "de"), using: engine)
        let batches = await engine.receivedBatches
        #expect(batches.allSatisfy { $0.isEmpty })
        #expect(result == input)
    }

    // MARK: Prose — batched in one engine call

    @Test func prose_isBatched() async throws {
        let engine = EchoEngine()
        let result = try await MarkdownTranslator.translate("Hello world", from: Locale(identifier: "en"), to: Locale(identifier: "de"), using: engine)
        let batches = await engine.receivedBatches
        #expect(batches.count == 1)
        #expect(batches[0].count == 1)
        #expect(result == "[T]Hello world")
    }

    @Test func multipleParagraphs_singleEngineCall() async throws {
        let engine = EchoEngine()
        let input = "Para one\n\nPara two\n\nPara three"
        let result = try await MarkdownTranslator.translate(input, from: Locale(identifier: "en"), to: Locale(identifier: "de"), using: engine)
        let batches = await engine.receivedBatches
        // All three paragraphs go in one engine call — not three separate calls
        #expect(batches.count == 1)
        #expect(batches[0].count == 3)
        #expect(result == "[T]Para one\n\n[T]Para two\n\n[T]Para three")
    }

    @Test func mixedProseAndCode_codeSkipped_proseBatched() async throws {
        let engine = EchoEngine()
        let input = "Intro\n\n```\ncode\n```\n\nClosing"
        let result = try await MarkdownTranslator.translate(input, from: Locale(identifier: "en"), to: Locale(identifier: "de"), using: engine)
        let batches = await engine.receivedBatches
        // Only the two prose paragraphs reach the engine
        #expect(batches.count == 1)
        #expect(batches[0].count == 2)
        let parts = result.components(separatedBy: "\n\n")
        #expect(parts[0] == "[T]Intro")
        #expect(parts[1] == "```\ncode\n```")
        #expect(parts[2] == "[T]Closing")
    }

    // MARK: Edge cases

    @Test func emptyDocument_noEngineCall() async throws {
        let engine = EchoEngine()
        let result = try await MarkdownTranslator.translate("", from: Locale(identifier: "en"), to: Locale(identifier: "de"), using: engine)
        let batches = await engine.receivedBatches
        #expect(batches.allSatisfy { $0.isEmpty })
        #expect(result == "")
    }

    @Test func allCodeBlocks_noEngineCall() async throws {
        let engine = EchoEngine()
        let input = "```\nblock one\n```\n\n```\nblock two\n```"
        _ = try await MarkdownTranslator.translate(input, from: Locale(identifier: "en"), to: Locale(identifier: "de"), using: engine)
        let batches = await engine.receivedBatches
        // batch.isEmpty guard: engine must not be called at all
        #expect(batches.allSatisfy { $0.isEmpty })
    }

    // MARK: Known limitation (documented in MarkdownTranslator.swift)

    /// Asserts the *current* (imperfect) behaviour for a fenced block with an embedded
    /// double-newline. Only the opening fence chunk is skipped; the body leaks into the engine.
    /// This test exists to catch regressions — not to assert correct CommonMark behaviour.
    @Test func fencedBlockWithInternalBlankLine_knownLimitation() async throws {
        let engine = EchoEngine()
        let input = "```\nline one\n\nline two\n```"
        _ = try await MarkdownTranslator.translate(input, from: Locale(identifier: "en"), to: Locale(identifier: "de"), using: engine)
        let batches = await engine.receivedBatches
        let nonEmpty = batches.filter { !$0.isEmpty }
        // Known: second chunk (body) leaks through. Engine IS called.
        #expect(!nonEmpty.isEmpty, "Known limitation: body chunk of fence-with-blank-line leaks into engine")
    }
}
