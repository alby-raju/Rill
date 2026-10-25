import XCTest
@testable import RillCore

final class ImportResourceTests: XCTestCase {
    func testLargeFlatAndSharedParentHierarchyValidatesWithoutRepeatedResolution() throws {
        let root = Environment(name: "Root")
        var workspace = Workspace(); workspace.environments = [root]
        for index in 0..<5000 { var child = Environment(name: "Child \(index)"); child.parentID = root.id; workspace.environments.append(child) }
        try WorkspaceFile.validate(workspace)
        let selected = workspace.environments[1]
        XCTAssertEqual(EnvironmentResolver.validParents(for: selected.id, in: workspace.environments).count, 5000)
    }
    func testParentOptionsRespectAllDescendantsAndCachedDepthBounds() throws {
        var environments: [Environment] = []
        for index in 0..<64 { var environment = Environment(name: "Level \(index)"); environment.parentID = environments.last?.id; environments.append(environment) }
        let other = Environment(name: "Other"); environments.append(other)
        try EnvironmentResolver.validateHierarchy(environments)
        XCTAssertFalse(EnvironmentResolver.canSetParent(other.id, for: environments[0].id, in: environments))
        XCTAssertTrue(EnvironmentResolver.validParents(for: environments[0].id, in: environments).isEmpty)
        XCTAssertFalse(EnvironmentResolver.canSetParent(environments[63].id, for: other.id, in: environments))
        XCTAssertTrue(EnvironmentResolver.canSetParent(nil, for: environments[63].id, in: environments))
        environments[0].parentID = environments[10].id
        XCTAssertThrowsError(try EnvironmentResolver.validateHierarchy(environments))
    }
    func testHostilePreviewNamesAreByteBoundedWithoutChangingSavedData() throws {
        var incoming = Workspace.starter
        incoming.requests[0].name = "a" + String(repeating: "\u{0301}", count: 20_000)
        let plan = try WorkspaceImportPlan(incoming: incoming, current: Workspace())
        XCTAssertLessThanOrEqual(plan.preview.requestNames[0].utf8.count, 517)
        XCTAssertEqual(try plan.applying(to: Workspace()).requests[0].name, incoming.requests[0].name)
    }
    func testJSONComparisonUsesDecodedCodeUnitsAndByteBoundsForUnicode() throws {
        func exchange(_ text: String) -> Exchange { Exchange(requestID: UUID(), requestName: "Unicode", method: .GET, url: "https://example.test", status: 200, duration: 0, headers: [], body: Data(text.utf8), checks: []) }
        let composed = exchange(#""é""#), decomposed = exchange(#""e\u0301""#)
        XCTAssertEqual(try ResponseComparator.compare(composed, decomposed).differences.count, 1)
        let first = exchange(#"{"é":1,"e\u0301":2}"#), reordered = exchange(#"{"e\u0301":2,"é":1}"#)
        XCTAssertTrue(try ResponseComparator.compare(first, reordered).differences.isEmpty)
        let long = "e" + String(repeating: "\u{0301}", count: 20_000)
        let encoded = String(decoding: try JSONEncoder().encode(long), as: UTF8.self)
        let result = try ResponseComparator.compare(exchange(encoded), exchange(#""different""#))
        XCTAssertLessThan(result.differences[0].before.utf8.count, 4000)
    }

}
