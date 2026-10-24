import XCTest
@testable import RillCore

final class BoundedYAMLTests: XCTestCase {
    func testJSONCompatibleMappingSequencesAndBlockScalars() throws {
        let object = try BoundedYAML.object(Data("name: Example\nvalues:\n  - true\n  - 42\noff: yes\ndate: 2026-10-24\nbody: |\n  line one\n  line two\n".utf8))
        XCTAssertEqual(object["name"] as? String, "Example")
        XCTAssertEqual(object["off"] as? String, "yes")
        XCTAssertEqual(object["date"] as? String, "2026-10-24")
        XCTAssertEqual(object["body"] as? String, "line one\nline two\n")
        XCTAssertEqual((object["values"] as? [Any])?.count, 2)
    }
    func testRejectsAnchorsAliasesTagsDuplicateKeysAndMultipleDocuments() {
        for source in ["a: &a [1]\nb: *a", "a: !include /private/file", "a: 1\na: 2", "a: 1\n---\nb: 2", "a: !!binary QUJD", "a: [malformed"] {
            XCTAssertThrowsError(try BoundedYAML.object(Data(source.utf8)), source)
        }
    }
    func testBoundsDepthEventsScalarAndInputWithoutSourceInDiagnostics() {
        for source in ["a: " + String(repeating: "[", count: 65) + "0" + String(repeating: "]", count: 65), "a: " + String(repeating: "x", count: 1024 * 1024 + 1), "a: [" + String(repeating: "0,", count: 100_001) + "0]"] {
            XCTAssertThrowsError(try BoundedYAML.object(Data(source.utf8)))
        }
        XCTAssertThrowsError(try BoundedYAML.object(Data(repeating: 32, count: 8 * 1024 * 1024 + 1)))
        do { _ = try BoundedYAML.object(Data("PRIVATE_SOURCE: [bad".utf8)); XCTFail("Malformed YAML accepted") }
        catch { XCTAssertFalse(error.localizedDescription.contains("PRIVATE_SOURCE")) }
    }
}
