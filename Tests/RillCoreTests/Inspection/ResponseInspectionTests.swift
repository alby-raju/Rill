import XCTest

@testable import RillCore

@MainActor final class ResponseInspectionTests: XCTestCase {
    private func exchange(_ body: String = "{}") -> Exchange {
        Exchange(
            requestID: UUID(), requestName: "Fixture", method: .GET,
            url: "https://example.test/path?token=SEEDED_SECRET", status: 200, duration: 0.1,
            headers: [
                Field(name: "Set-Cookie", value: "SEEDED_SECRET"),
                Field(name: "Content-Type", value: "application/json; secret=SEEDED_SECRET"),
            ], body: Data(body.utf8),
            checks: [CheckResult(title: "Body contains SEEDED_SECRET", passed: true)])
    }
    private func temporary() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("history.json")
    }
    func testIndependentSettingsBoundsAndPreviewNeverLoseOriginalBytes() throws {
        var settings = ResponseSettings()
        settings.previewBytes = 128
        settings.downloadBytes = 1
        try settings.validate()
        let budget = try ResponseBudget(
            downloadBytes: settings.downloadBytes, previewBytes: settings.previewBytes)
        XCTAssertEqual(budget.previewBytes, 128)
        var result = exchange(String(repeating: "x", count: 1024))
        result.previewLimit = 128
        XCTAssertTrue(result.previewIsTruncated)
        XCTAssertEqual(result.previewText(pretty: false).count, 128)
        XCTAssertEqual(result.body.count, 1024)
        settings.previewBytes = 0
        XCTAssertThrowsError(try settings.validate())
        XCTAssertThrowsError(
            try ResponseBudget(downloadBytes: 1, previewBytes: 8 * 1024 * 1024 + 1))
    }
    func testSnapshotOmitsBodiesAndMasksQueryHeadersAndCheckValues() throws {
        let result = ResponseInspection.snapshot(
            exchange("SEEDED_SECRET"), settings: ResponseSettings())
        XCTAssertTrue(result.body.isEmpty)
        XCTAssertTrue(result.bodyWasTruncated == true)
        XCTAssertEqual(result.originalBodyBytes, 13)
        XCTAssertFalse(
            String(decoding: try JSONEncoder().encode(result), as: UTF8.self).contains(
                "SEEDED_SECRET"))
        XCTAssertEqual(ResponseInspection.mimeType(result), "application/json")
    }
    func testSnapshotRetentionIsExplicitlyTruncatedAndBoundedAcrossRestart() async throws {
        let url = try temporary()
        let history = ExchangeHistory(url: url)
        var settings = ResponseSettings()
        settings.retainSnapshotBodies = true
        settings.snapshotBodyBytes = 3
        settings.snapshotTotalBodyBytes = 5
        try await history.record(exchange("abcdef"), settings: settings)
        try await history.record(exchange("second"), settings: settings)
        let restarted = ExchangeHistory(url: url)
        let entries = try await restarted.open()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].body, Data("sec".utf8))
        XCTAssertEqual(entries[0].originalBodyBytes, 6)
        XCTAssertTrue(entries[0].bodyWasTruncated == true)
        let permissions =
            try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
            as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        try await restarted.clear()
        let empty = try await awaitEmpty(restarted)
        XCTAssertTrue(empty)
    }
    private func awaitEmpty(_ history: ExchangeHistory) async throws -> Bool {
        try await history.open().isEmpty
    }
    func testCorruptAndConcurrentHistoryFilesArePreserved() async throws {
        let url = try temporary()
        try Data("invalid".utf8).write(to: url)
        let bad = ExchangeHistory(url: url)
        do {
            _ = try await bad.open()
            XCTFail("Corruption accepted")
        } catch {}
        do {
            try await bad.record(exchange(), settings: ResponseSettings())
            XCTFail("Corruption overwritten")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: url), Data("invalid".utf8))
        let freshURL = try temporary()
        let first = ExchangeHistory(url: freshURL)
        let stale = ExchangeHistory(url: freshURL)
        _ = try await first.open()
        _ = try await stale.open()
        try await first.record(exchange(), settings: ResponseSettings())
        let expected = try Data(contentsOf: freshURL)
        do {
            try await stale.record(exchange(), settings: ResponseSettings())
            XCTFail("Stale history writer succeeded")
        } catch { XCTAssertEqual(error as? WorkspaceError, .conflict) }
        XCTAssertEqual(try Data(contentsOf: freshURL), expected)
    }
    func testContentDetectionIsPassiveAndBinaryPreviewIsBounded() {
        var result = exchange("<script>alert('never executed')</script>")
        result.headers = [Field(name: "Content-Type", value: "text/html")]
        XCTAssertEqual(ResponseInspection.kind(result), .html)
        result.headers = [Field(name: "Content-Type", value: "application/xml")]
        XCTAssertEqual(ResponseInspection.kind(result), .xml)
        result.body = Data([137, 80, 78, 71, 13, 10, 26, 10])
        XCTAssertEqual(ResponseInspection.kind(result), .image)
        result.body = Data([0, 255, 1])
        XCTAssertEqual(ResponseInspection.kind(result), .binary)
        XCTAssertEqual(ResponseInspection.hex(Data([0, 255, 1])), "00000000  00 ff 01")
        XCTAssertLessThan(
            ResponseInspection.hex(Data(repeating: 1, count: 1_000_000)).count, 20_000)
    }
    func testSemanticComparisonIgnoresOrderWhitespaceEscapesAndExactNumberSpelling() throws {
        let first = exchange(#"{"b":[1.00e0,true,null],"a":"\u0061","large":9007199254740993}"#)
        let equal = exchange(#"{"large":9007199254740993,"a":"a","b":[100e-2,true,null]}"#)
        XCTAssertTrue(try ResponseComparator.compare(first, equal).differences.isEmpty)
        let different = exchange(#"{"b":[1,true,null],"a":"a","large":9007199254740992}"#)
        XCTAssertEqual(
            try ResponseComparator.compare(first, different).differences.map(\.path), ["/large"])
        XCTAssertTrue(
            try ResponseComparator.compare(exchange("-0.0"), exchange("0e99")).differences.isEmpty)
    }
    func testComparisonReportsArraysMissingKeysAndEscapedPaths() throws {
        let comparison = try ResponseComparator.compare(
            exchange(#"{"a/b":{"~x":[1,2]},"removed":true}"#),
            exchange(#"{"a/b":{"~x":[1,3,4]},"added":null}"#))
        XCTAssertEqual(
            comparison.differences.map(\.path),
            ["/a~1b/~0x/1", "/a~1b/~0x/2", "/added", "/removed"])
    }
    func testComparisonRejectsIncompleteAmbiguousMalformedAndOverLimitJSON() throws {
        var incomplete = exchange("{}")
        incomplete.bodyWasTruncated = true
        XCTAssertThrowsError(try ResponseComparator.compare(incomplete, exchange("{}")))
        for text in [#"{"a":1,"a":2}"#, "not json", "[1,]", "01", "1.", "1e", "1e1000001"] {
            XCTAssertThrowsError(try ResponseComparator.compare(exchange(text), exchange("{}")))
        }
        let deep = String(repeating: "[", count: 130) + "0" + String(repeating: "]", count: 130)
        XCTAssertThrowsError(try ResponseComparator.compare(exchange(deep), exchange("{}")))
    }
    func testDifferenceOutputHasExplicitLimit() throws {
        let before = "[" + Array(repeating: "1", count: 1002).joined(separator: ",") + "]"
        let after = "[" + Array(repeating: "2", count: 1002).joined(separator: ",") + "]"
        let result = try ResponseComparator.compare(exchange(before), exchange(after))
        XCTAssertEqual(result.differences.count, 1000)
        XCTAssertTrue(result.limited)
    }
    func testRetentionPreferenceChangesTrimExistingBodiesAndLegacyTimeoutsNormalizeOnlyOnRead()
        async throws
    {
        let url = try temporary()
        let history = ExchangeHistory(url: url)
        var settings = ResponseSettings()
        settings.retainSnapshotBodies = true
        try await history.record(exchange("retained body"), settings: settings)
        settings.retainSnapshotBodies = false
        try await history.apply(settings: settings)
        let reloaded = try await ExchangeHistory(url: url).open()
        XCTAssertTrue(reloaded[0].body.isEmpty)
        XCTAssertTrue(reloaded[0].bodyWasTruncated == true)
        var workspace = Workspace.starter
        workspace.requests[0].timeout = 999
        XCTAssertThrowsError(try WorkspaceFile.encode(workspace))
        let legacy = try JSONEncoder().encode(workspace)
        let normalized = try WorkspaceFile.decode(legacy)
        XCTAssertEqual(normalized.requests[0].timeout, 300)
        workspace.requests[0].url = "https://example.test"
        XCTAssertThrowsError(try RequestEngine.prepare(workspace.requests[0], environment: nil))
    }

}
