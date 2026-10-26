import XCTest

@testable import RillCore

final class RequestTransferTests: XCTestCase {
    func testCopyPreservesVisibleSettingsWithoutChangingOriginal() throws {
        var workspace = Workspace()
        let source = RequestCollection(name: "Source")
        let destination = RequestCollection(name: "Destination")
        workspace.collections = [source, destination]
        var request = RequestDraft(collectionID: source.id)
        request.name = "Saved"
        request.url = "https://example.test/saved"
        workspace.requests = [request]
        var visible = request
        visible.body = "unsaved content"
        visible.auth = .bearer
        visible.credential = "synthetic-test-token"
        let same = try WorkspaceOperations.copy(visible, to: source.id, in: &workspace)
        let other = try WorkspaceOperations.copy(visible, to: destination.id, in: &workspace)
        XCTAssertNotEqual(same.id, request.id)
        XCTAssertNotEqual(other.id, same.id)
        XCTAssertEqual(same.collectionID, source.id)
        XCTAssertEqual(other.collectionID, destination.id)
        XCTAssertEqual(other.body, visible.body)
        XCTAssertEqual(other.credential, visible.credential)
        XCTAssertEqual(workspace.requests.first, request)
        try WorkspaceFile.validate(workspace)
    }
    func testMoveAcrossCollectionsAndUnfiledRetainsIdentityAndOrdering() throws {
        var workspace = Workspace()
        let a = RequestCollection(name: "A")
        let b = RequestCollection(name: "B")
        workspace.collections = [a, b]
        let first = RequestDraft(collectionID: a.id)
        let second = RequestDraft(collectionID: b.id)
        workspace.requests = [first, second]
        try WorkspaceOperations.place(first.id, before: second.id, after: true, in: &workspace)
        XCTAssertEqual(workspace.requests.map(\.id), [second.id, first.id])
        XCTAssertEqual(workspace.requests.last?.collectionID, b.id)
        try WorkspaceOperations.relocate(first.id, to: nil, in: &workspace)
        XCTAssertEqual(workspace.requests.last?.id, first.id)
        XCTAssertNil(workspace.requests.last?.collectionID)
        let saved = workspace
        XCTAssertThrowsError(try WorkspaceOperations.relocate(first.id, to: UUID(), in: &workspace))
        XCTAssertEqual(workspace, saved)
        try WorkspaceFile.validate(workspace)
    }
}
