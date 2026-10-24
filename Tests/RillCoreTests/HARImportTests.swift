import XCTest
@testable import RillCore

final class HARImportTests: XCTestCase {
    private func log(_ requests: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["log": ["version": "1.2", "entries": requests.map { ["request": $0, "response": ["content": ["text": "never imported"]]] }]])
    }
    func testBOMMultipleEntriesAuthAndAuthoritativeEncodedURL() throws {
        let source: [String: Any] = ["method": "GET", "url": "https://example.test/?x=%2f&x=2", "queryString": [["name": "x", "value": "/"]], "headers": [["name": "Authorization", "value": "Bearer private-token"], ["name": "Host", "value": "captured.test"]], "cookies": [["name": "a", "value": "private"]]]
        let result = try HARImporter.parse(Data([0xef, 0xbb, 0xbf]) + log([source, source]))
        XCTAssertEqual(result.count, 2); XCTAssertNotEqual(result[0].request.id, result[1].request.id)
        XCTAssertEqual(result[0].request.credential, "private-token"); XCTAssertEqual(result[0].request.auth, .bearer)
        XCTAssertTrue(result[0].request.headers.isEmpty)
        XCTAssertEqual(result[0].request.bodyMode, RequestBodyMode.none)
        XCTAssertEqual(try RequestEngine.prepare(result[0].request, environment: nil).url?.absoluteString, "https://example.test/?x=%2f&x=2")
        XCTAssertTrue(result[0].warnings.contains { $0.contains("Cookie objects") })
        XCTAssertFalse(result[0].warnings.joined().contains("private-token"))
    }
    func testRawAndOrderedDuplicateFormFields() throws {
        let common: [String: Any] = ["method": "POST", "url": "https://example.test/", "headers": []]
        var raw = common; raw["postData"] = ["mimeType": "application/json", "text": "{\"a\":1}", "params": [["name": "ignored", "value": "x"]]]
        var form = common; form["postData"] = ["mimeType": "application/x-www-form-urlencoded", "params": [["name": "x", "value": "a +"], ["name": "x", "value": "2"]]]
        let result = try HARImporter.parse(log([raw, form]))
        XCTAssertEqual(result[0].request.body, "{\"a\":1}")
        XCTAssertEqual(result[1].request.formFields?.map(\.name), ["x", "x"])
        XCTAssertEqual(String(data: try XCTUnwrap(RequestEngine.prepare(result[1].request, environment: nil).httpBody), encoding: .utf8), "x=a+%2B&x=2")
    }
    func testRejectsUnrepresentableAndMissingBodiesRatherThanSilentlyDropping() throws {
        let common: [String: Any] = ["method": "POST", "url": "https://example.test/", "headers": []]
        for body: [String: Any] in [["mimeType": "multipart/form-data", "text": "captured boundary"], ["mimeType": "text/plain", "text": "abc", "_encoding": "base64"], ["mimeType": "application/x-www-form-urlencoded", "params": [["name": "file", "fileName": "/never/read"]]]] {
            var request = common; request["postData"] = body
            XCTAssertThrowsError(try HARImporter.parse(log([request])))
        }
        var missing = common; missing["bodySize"] = 10
        XCTAssertThrowsError(try HARImporter.parse(log([missing])))
        var repeated = common; repeated["headers"] = [["name": "X-Test", "value": "a"], ["name": "x-test", "value": "b"]]
        XCTAssertThrowsError(try HARImporter.parse(log([repeated])))
    }
    func testBoundsVersionAndStructure() throws {
        XCTAssertThrowsError(try HARImporter.parse(Data(repeating: 32, count: ResourceLimits.workspaceBytes + 1)))
        XCTAssertThrowsError(try HARImporter.parse(Data((String(repeating: "[", count: 129) + String(repeating: "]", count: 129)).utf8)))
        XCTAssertThrowsError(try HARImporter.parse(log([])))
        XCTAssertThrowsError(try HARImporter.parse(log(Array(repeating: ["method": "GET", "url": "https://example.test", "headers": []], count: 1001))))
        XCTAssertThrowsError(try HARImporter.parse(Data(#"{"log":{"version":"9","entries":[]}}"#.utf8)))
    }
}
