import XCTest

@testable import RillCore

@MainActor final class EditorRecoveryTests: XCTestCase {
    private func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    private func request(_ name: String, collectionID: UUID? = nil) -> RequestDraft {
        var draft = RequestDraft(collectionID: collectionID)
        draft.name = name
        return draft
    }

    func testBulkMovePreservesIdentityOrderAndDrafts() throws {
        let source = RequestCollection(name: "Source")
        let destination = RequestCollection(name: "Destination")
        let first = request("First", collectionID: source.id)
        let second = request("Second", collectionID: source.id)
        let existing = request("Existing", collectionID: destination.id)
        var workspace = Workspace()
        workspace.collections = [source, destination]
        workspace.requests = [first, existing, second]
        var editor = EditorSessionState()
        var draft = first
        draft.body = "unsaved body"
        try editor.update(draft, savedIn: workspace)
        editor.pinnedTabs = [first.id]
        try editor.applyRequestBatch(
            [first.id, second.id], action: .move(to: destination.id), in: &workspace)
        XCTAssertEqual(workspace.requests.map(\.id), [existing.id, first.id, second.id])
        XCTAssertEqual(
            workspace.requests.map(\.collectionID), Array(repeating: destination.id, count: 3))
        XCTAssertEqual(editor.drafts.first?.body, draft.body)
        XCTAssertEqual(editor.drafts.first?.collectionID, destination.id)
        XCTAssertEqual(editor.activeID, first.id)
        XCTAssertEqual(editor.pinnedTabs, [first.id])
    }

    func testBulkDuplicateAndCopyUseVisibleDraftsWithoutOpeningTabs() throws {
        let collection = RequestCollection(name: "Source")
        let first = request("First", collectionID: collection.id)
        let second = request("Second")
        var workspace = Workspace()
        workspace.collections = [collection]
        workspace.requests = [first, second]
        var editor = EditorSessionState()
        var draft = first
        draft.name = "Visible"
        try editor.update(draft, savedIn: workspace)
        let session = editor
        let duplicates = try editor.applyRequestBatch(
            [first.id, second.id], action: .duplicate, in: &workspace)
        XCTAssertEqual(
            workspace.requests.filter { duplicates.contains($0.id) }.map(\.name),
            ["Visible copy", "Second copy"])
        XCTAssertEqual(
            workspace.requests.first { $0.id == duplicates[0] }?.collectionID, collection.id)
        let copies = try editor.applyRequestBatch(
            [first.id, second.id], action: .copy(to: nil), in: &workspace)
        XCTAssertEqual(Set(duplicates + copies).count, 4)
        XCTAssertTrue(
            workspace.requests.filter { copies.contains($0.id) }.allSatisfy {
                $0.collectionID == nil
            })
        XCTAssertEqual(editor, session)
    }

    func testBulkDeleteCleansEditorAndRejectsStaleSelectionAtomically() throws {
        let first = request("First")
        let second = request("Second")
        let remaining = request("Remaining")
        var workspace = Workspace()
        workspace.requests = [first, second, remaining]
        var editor = EditorSessionState()
        try editor.open(remaining.id)
        try editor.open(second.id)
        var draft = first
        draft.body = "unsaved body"
        try editor.update(draft, savedIn: workspace)
        editor.closedTabs = [second.id]
        editor.pinnedTabs = [first.id]
        let before = workspace
        let session = editor
        XCTAssertThrowsError(
            try editor.applyRequestBatch(
                [first.id, UUID()], action: .delete, in: &workspace))
        XCTAssertThrowsError(
            try editor.applyRequestBatch(
                [first.id, second.id], action: .move(to: UUID()), in: &workspace))
        XCTAssertEqual(workspace, before)
        XCTAssertEqual(editor, session)
        try editor.applyRequestBatch([first.id, second.id], action: .delete, in: &workspace)
        XCTAssertEqual(workspace.requests, [remaining])
        XCTAssertEqual(editor.openTabs, [remaining.id])
        XCTAssertEqual(editor.activeID, remaining.id)
        XCTAssertTrue(editor.closedTabs.isEmpty)
        XCTAssertTrue(editor.pinnedTabs.isEmpty)
        XCTAssertTrue(editor.drafts.isEmpty)
    }

    func testDraftEditingNeverChangesSavedRequestAndCloseRequiresDecision() throws {
        let workspace = Workspace.starter
        let original = workspace.requests[0]
        var editor = EditorSessionState()
        try editor.open(original.id)
        var draft = original
        draft.body = "unsaved"
        try editor.update(draft, savedIn: workspace)
        XCTAssertEqual(workspace.requests[0], original)
        XCTAssertTrue(editor.isDirty(original.id, in: workspace))
        XCTAssertThrowsError(try editor.close(original.id, in: workspace))
        XCTAssertEqual(editor.openTabs, [original.id])
        editor.discard(original.id)
        try editor.close(original.id, in: workspace)
        XCTAssertTrue(editor.openTabs.isEmpty)
        try editor.reopen(in: workspace)
        XCTAssertEqual(editor.activeID, original.id)
    }
    func testTabsReuseIDsAndPinnedTabsSurviveSessionEncoding() throws {
        var workspace = Workspace.starter
        workspace.requests.append(RequestDraft())
        var editor = EditorSessionState()
        for request in workspace.requests { try editor.open(request.id) }
        try editor.open(workspace.requests[0].id)
        editor.pinnedTabs.insert(workspace.requests[0].id)
        let restored = try JSONDecoder().decode(
            EditorSessionState.self, from: JSONEncoder().encode(editor))
        XCTAssertEqual(restored.openTabs, workspace.requests.map(\.id))
        XCTAssertEqual(restored.activeID, workspace.requests[0].id)
        XCTAssertEqual(restored.pinnedTabs, editor.pinnedTabs)
    }
    func testCheckpointRecoveryKeepsDraftCredentialsOutOfJSONAndSavedStore() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = Workspace.starter
        let credentials = TestCredentials()
        var editor = EditorSessionState()
        var draft = workspace.requests[0]
        draft.body = "recover this body"
        draft.credential = "draft-secret-marker"
        try editor.update(draft, savedIn: workspace)
        let url = directory.appendingPathComponent("session.json")
        let first = EditorSessionPersistence(url: url, credentials: credentials)
        _ = try await first.open(in: workspace)
        try await first.checkpoint(editor, workspace: workspace)
        XCTAssertFalse(
            String(decoding: try Data(contentsOf: url), as: UTF8.self).contains(
                "draft-secret-marker"))
        let restarted = EditorSessionPersistence(url: url, credentials: credentials)
        let recovered = try await restarted.open(in: workspace)
        XCTAssertEqual(recovered.drafts[0].body, "recover this body")
        XCTAssertEqual(recovered.drafts[0].credential, "draft-secret-marker")
        XCTAssertEqual(workspace.requests[0].body, "")
    }
    func testStaleCheckpointWriterCannotReplaceOtherInstance() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = Workspace.starter
        let url = directory.appendingPathComponent("session.json")
        let first = EditorSessionPersistence(url: url, credentials: TestCredentials())
        let second = EditorSessionPersistence(url: url, credentials: TestCredentials())
        let a = try await first.open(in: workspace)
        let b = try await second.open(in: workspace)
        try await first.checkpoint(a, workspace: workspace)
        do {
            try await second.checkpoint(b, workspace: workspace)
            XCTFail("Stale checkpoint accepted")
        } catch { XCTAssertEqual(error as? WorkspaceError, .conflict) }
    }
    func testBackupOmitsAuthSecretsAndChecksumRejectsTamperingAndZipData() throws {
        var workspace = Workspace.starter
        workspace.requests[0].credential = "saved-secret-marker"
        var editor = EditorSessionState()
        var draft = workspace.requests[0]
        draft.body = "draft body"
        draft.credential = "draft-secret-marker"
        try editor.update(draft, savedIn: workspace)
        let data = try WorkspaceBackup.encode(workspace: workspace, editor: editor)
        let recovered = try WorkspaceBackup.decode(data)
        XCTAssertEqual(recovered.workspace.requests[0].credential, "")
        XCTAssertEqual(recovered.editor?.drafts[0].credential, "")
        XCTAssertEqual(recovered.editor?.drafts[0].body, "draft body")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["checksum"] = "tampered"
        XCTAssertThrowsError(
            try WorkspaceBackup.decode(JSONSerialization.data(withJSONObject: object)))
        XCTAssertThrowsError(try WorkspaceBackup.decode(Data([0x50, 0x4b, 0x03, 0x04])))
    }
    func testRestoreRetainsPreviousWorkspaceAndRejectsOverwriteOfRecoveryCopy() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("workspace.json")
        let previous = directory.appendingPathComponent("previous.rillbackup")
        let session = WorkspaceSession(url: url, credentials: TestCredentials())
        var current = try await session.open()
        current.requests[0].name = "Before restore"
        try await session.save(current)
        var target = Workspace.starter
        target.requests[0].name = "Restored"
        let contents = try WorkspaceBackup.decode(
            WorkspaceBackup.encode(workspace: target, editor: nil))
        let restored = try await session.restore(
            contents, retainingPreviousAt: previous, editor: nil)
        XCTAssertEqual(restored.requests[0].name, "Restored")
        XCTAssertEqual(
            try WorkspaceBackup.load(from: previous).workspace.requests[0].name, "Before restore")
        XCTAssertEqual(try WorkspaceFile.load(from: url).requests[0].name, "Restored")
        let previousBytes = try Data(contentsOf: previous)
        do {
            _ = try await session.restore(contents, retainingPreviousAt: previous, editor: nil)
            XCTFail("Recovery copy overwritten")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: previous), previousBytes)
        do {
            _ = try await session.restore(contents, retainingPreviousAt: url, editor: nil)
            XCTFail("Active file used as recovery copy")
        } catch {}
    }
    func testCorruptCheckpointIsPreservedAndCannotBeOverwritten() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("session.json")
        let corrupt = Data("{broken".utf8)
        try corrupt.write(to: url)
        let persistence = EditorSessionPersistence(url: url, credentials: TestCredentials())
        do {
            _ = try await persistence.open(in: .starter)
            XCTFail("Invalid checkpoint accepted")
        } catch {}
        do {
            try await persistence.checkpoint(EditorSessionState(), workspace: .starter)
            XCTFail("Invalid checkpoint overwritten")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
    }
}
