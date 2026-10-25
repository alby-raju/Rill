import XCTest
@testable import RillCore

@MainActor final class ClientSnippetTests: XCTestCase {
    func testFrozenBodiesMaskingAndEscapingAcrossTargets() throws {
        var draft = RequestDraft(); draft.url = "https://example.test/path?x=%2F"; draft.method = .POST
        draft.bodyMode = .text; draft.body = "Unicode 🐟\u{2028}\" $HOME\n"; draft.auth = .bearer; draft.credential = "private-token"
        let frozen = try FrozenClientRequest.capture(draft, environment: nil)
        XCTAssertEqual(frozen.body, Data(draft.body.utf8))
        XCTAssertEqual(frozen.headers.first { $0.key.lowercased() == "authorization" }?.value, "[REDACTED]")
        for target in ClientTarget.allCases {
            let output = try ClientSnippetGenerator.generate(frozen, target: target)
            XCTAssertTrue(output.contains(frozen.body!.base64EncodedString()))
            XCTAssertFalse(output.contains("private-token")); XCTAssertTrue(output.contains("16777216"))
        }
        let explicit = try FrozenClientRequest.capture(draft, environment: nil, includeCredentials: true)
        XCTAssertEqual(explicit.headers.first { $0.key.lowercased() == "authorization" }?.value, "Bearer private-token")
        XCTAssertEqual(try ClientSnippetGenerator.literal("\"\\\n\u{2028}"), "\"\\\"\\\\\\n\\u2028\"")
    }
    func testMultipartBoundaryAndBytesAreCapturedTogether() throws {
        var draft = RequestDraft(); draft.url = "https://example.test"; draft.method = .POST; draft.bodyMode = .multipart
        var part = MultipartPart(); part.name = "field"; part.value = "value 🐟"
        draft.multipartParts = [part]
        let frozen = try FrozenClientRequest.capture(draft, environment: nil)
        let type = try XCTUnwrap(frozen.headers.first { $0.key.lowercased() == "content-type" }?.value)
        let boundary = try XCTUnwrap(type.components(separatedBy: "boundary=").last)
        XCTAssertTrue(String(decoding: try XCTUnwrap(frozen.body), as: UTF8.self).contains("--" + boundary))
        XCTAssertTrue(String(decoding: frozen.body!, as: UTF8.self).contains("value 🐟"))
        XCTAssertFalse(frozen.headers.keys.contains { $0.lowercased() == "content-length" })
    }
    func testRejectsUnrepresentableAndOversizedRequests() throws {
        var draft = RequestDraft(); draft.url = "https://example.test"; draft.method = .POST; draft.bodyMode = .text
        draft.body = String(repeating: "a", count: FrozenClientRequest.bodyLimit + 1)
        XCTAssertThrowsError(try FrozenClientRequest.capture(draft, environment: nil))
        draft.body = ""; draft.headers = [Field(name: "Host", value: "different.test")]
        XCTAssertThrowsError(try FrozenClientRequest.capture(draft, environment: nil))
        draft.headers = [Field(name: "X", value: "one"), Field(name: "x", value: "two")]
        XCTAssertThrowsError(try FrozenClientRequest.capture(draft, environment: nil))
        draft.headers = []; draft.method = .GET; draft.body = "body"
        XCTAssertThrowsError(try FrozenClientRequest.capture(draft, environment: nil))
    }
    func testCustomAPIKeyMaskingAndTargetRepresentability() throws {
        var draft = RequestDraft(); draft.url = "https://example.test"; draft.auth = .apiKey
        draft.apiKeyLocation = .header; draft.apiKeyName = "  X-Custom-Credential  "; draft.credential = "never-export"
        let frozen = try FrozenClientRequest.capture(draft, environment: nil)
        XCTAssertEqual(frozen.headers.first { $0.key.lowercased() == "x-custom-credential" }?.value, "[REDACTED]")
        for target in CommandTarget.allCases {
            let command = try CommandGenerator.generate(draft, environment: nil, target: target)
            XCTAssertFalse(command.contains("never-export"))
            XCTAssertTrue(command.contains("[REDACTED]"))
        }
        draft.auth = .none; draft.headers = [Field(name: "__proto__", value: "literal")]
        let reserved = try FrozenClientRequest.capture(draft, environment: nil)
        XCTAssertThrowsError(try ClientSnippetGenerator.generate(reserved, target: .axios))
        XCTAssertThrowsError(try ClientSnippetGenerator.generate(reserved, target: .fetch))
        XCTAssertNoThrow(try ClientSnippetGenerator.generate(reserved, target: .requests))
        for value in [" leading", "trailing ", "embedded\tvalue", "Unicode 🐟"] {
            draft.headers = [Field(name: "X-Test", value: value)]
            XCTAssertThrowsError(try FrozenClientRequest.capture(draft, environment: nil))
        }
    }
    func testEmitSyntheticExecutableFixturesWhenRequested() throws {
        guard let path = ProcessInfo.processInfo.environment["RILL_SNIPPET_FIXTURES"] else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("synthetic.bin")
        try Data([0, 255, 13, 10, 42]).write(to: file)
        for kind in ["raw", "binary", "multipart", "empty", "head", "large", "redirect", "overflow"] {
            var draft = RequestDraft(); draft.url = "http://127.0.0.1:18750/echo?q=%2F&x=a+b"; draft.method = .POST
            draft.headers = [Field(name: "X-Literal", value: "quotes \" and ' and $HOME"), Field(name: "X-Empty", value: "")]
            if kind == "redirect" || kind == "overflow" { draft.url = "http://127.0.0.1:18750/" + kind }
            if kind == "large" { draft.bodyMode = .text; draft.body = String(repeating: "🦦", count: 24_000); draft.contentType = "text/plain" }
            else if kind == "raw" { draft.bodyMode = .text; draft.body = #"{"message":"Unicode 🐟\n$HOME \"quoted\""}"#; draft.contentType = "application/json" }
            else if kind == "binary" { draft.bodyMode = .binary; draft.binaryFile = try UploadFileReference.capture(file) }
            else if kind == "multipart" {
                draft.bodyMode = .multipart
                var text = MultipartPart(); text.name = "field"; text.value = "Unicode 🐟"
                var part = MultipartPart(); part.name = "upload"; part.kind = .file; part.file = try UploadFileReference.capture(file); part.filename = "fixture.bin"
                draft.multipartParts = [text, part]
            } else { draft.bodyMode = RequestBodyMode.none; if kind == "head" { draft.method = .HEAD } }
            let frozen = try FrozenClientRequest.capture(draft, environment: nil)
            let expected: [String: Any] = ["method": frozen.method, "url": frozen.url, "headers": frozen.headers, "body": frozen.body?.base64EncodedString() ?? "", "overflow": kind == "overflow"]
            let folder = directory.appendingPathComponent(kind, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: expected, options: [.sortedKeys]).write(to: folder.appendingPathComponent("expected.json"))
            for target in ClientTarget.allCases {
                try ClientSnippetGenerator.generate(frozen, target: target).write(to: folder.appendingPathComponent(String(describing: target) + ".txt"), atomically: true, encoding: .utf8)
            }
        }
    }

}
