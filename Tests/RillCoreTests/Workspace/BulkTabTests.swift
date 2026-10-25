import XCTest
@testable import RillCore

final class BulkTabTests: XCTestCase {
    func fixture() throws -> (Workspace, EditorSessionState) {
        var workspace = Workspace();workspace.requests = (0..<5).map { index in var request = RequestDraft();request.name = "Request \(index)";return request }
        var editor = EditorSessionState()
        for request in workspace.requests { try editor.open(request.id) }
        return (workspace,editor)
    }
    func testRelativeClosuresUseVisualOrderAndKeepAnchorAndRequests() throws {
        let (workspace,original) = try fixture(), ids = original.openTabs
        var left = original;try left.closeTabs(left.tabsToClose(.left,relativeTo:ids[2]),in:workspace)
        XCTAssertEqual(left.openTabs,Array(ids[2...]));XCTAssertEqual(workspace.requests.count,5)
        var right = original;try right.closeTabs(right.tabsToClose(.right,relativeTo:ids[2]),in:workspace)
        XCTAssertEqual(right.openTabs,Array(ids[...2]));XCTAssertEqual(right.activeID,ids[2])
        XCTAssertTrue(original.tabsToClose(.left,relativeTo:ids[0]).isEmpty)
        XCTAssertTrue(original.tabsToClose(.right,relativeTo:ids[4]).isEmpty)
        XCTAssertTrue(original.tabsToClose(.left,relativeTo:UUID()).isEmpty)
    }
    func testUnsavedDraftBlocksEntireBatchUntilExplicitDiscard() throws {
        let (workspace,original) = try fixture();var editor = original
        var draft = workspace.requests[2];draft.body = "unsaved payload";try editor.update(draft,savedIn:workspace)
        let before = editor
        XCTAssertThrowsError(try editor.closeTabs(editor.tabsToClose(.all),in:workspace))
        XCTAssertEqual(editor,before) // No clean prefix closed before the dirty tab was encountered.
        try editor.closeTabs(editor.tabsToClose(.left,relativeTo:workspace.requests[4].id),in:workspace,discardChanges:true)
        XCTAssertEqual(editor.openTabs,[workspace.requests[4].id]);XCTAssertTrue(editor.drafts.isEmpty)
        XCTAssertEqual(workspace.requests[2].body,"")
    }
    func testCloseAllIncludesPinsAndReopenWorksWithoutDeletingSavedRequests() throws {
        let (workspace,original) = try fixture();var editor = original
        editor.pinnedTabs.insert(workspace.requests[0].id)
        try editor.closeTabs(editor.tabsToClose(.all),in:workspace)
        XCTAssertTrue(editor.openTabs.isEmpty);XCTAssertTrue(editor.pinnedTabs.isEmpty);XCTAssertNil(editor.activeID)
        XCTAssertEqual(workspace.requests.count,5)
        try editor.reopen(in:workspace);XCTAssertEqual(editor.activeID,workspace.requests[4].id)
    }
    func testUntargetedDirtyDraftAndPinSurvivePartialClose() throws {
        let (workspace,original) = try fixture();var editor = original
        var draft = workspace.requests[0];draft.body = "keep this";try editor.update(draft,savedIn:workspace)
        editor.pinnedTabs.insert(draft.id)
        try editor.closeTabs(editor.tabsToClose(.right,relativeTo:workspace.requests[2].id),in:workspace,discardChanges:true)
        XCTAssertTrue(editor.isDirty(draft.id,in:workspace));XCTAssertTrue(editor.pinnedTabs.contains(draft.id));XCTAssertEqual(editor.activeID,draft.id)
    }
}
