import XCTest
@testable import RillCore

@MainActor final class EditorRecoveryTests: XCTestCase {
    private func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    func testDraftEditingNeverChangesSavedRequestAndCloseRequiresDecision() throws {
        let workspace = Workspace.starter
        let original = workspace.requests[0]
        var editor = EditorSessionState(); try editor.open(original.id)
        var draft = original; draft.body = "unsaved"; try editor.update(draft, savedIn: workspace)
        XCTAssertEqual(workspace.requests[0], original)
        XCTAssertTrue(editor.isDirty(original.id, in: workspace))
        XCTAssertThrowsError(try editor.close(original.id, in: workspace))
        XCTAssertEqual(editor.openTabs, [original.id])
        editor.discard(original.id); try editor.close(original.id, in: workspace)
        XCTAssertTrue(editor.openTabs.isEmpty)
        try editor.reopen(in: workspace); XCTAssertEqual(editor.activeID, original.id)
    }
    func testTabsReuseIDsAndPinnedTabsSurviveSessionEncoding() throws {
        var workspace = Workspace.starter; workspace.requests.append(RequestDraft())
        var editor = EditorSessionState()
        for request in workspace.requests { try editor.open(request.id) }
        try editor.open(workspace.requests[0].id)
        editor.pinnedTabs.insert(workspace.requests[0].id)
        let restored = try JSONDecoder().decode(EditorSessionState.self, from: JSONEncoder().encode(editor))
        XCTAssertEqual(restored.openTabs, workspace.requests.map(\.id))
        XCTAssertEqual(restored.activeID, workspace.requests[0].id)
        XCTAssertEqual(restored.pinnedTabs, editor.pinnedTabs)
    }
    func testCheckpointRecoveryKeepsDraftCredentialsOutOfJSONAndSavedStore() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = Workspace.starter, credentials = TestCredentials()
        var editor = EditorSessionState(); var draft = workspace.requests[0]
        draft.body = "recover this body"; draft.credential = "draft-secret-marker"
        try editor.update(draft, savedIn: workspace)
        let url = directory.appendingPathComponent("session.json")
        let first = EditorSessionPersistence(url: url, credentials: credentials)
        _ = try await first.open(in: workspace)
        try await first.checkpoint(editor, workspace: workspace)
        XCTAssertFalse(String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("draft-secret-marker"))
        let restarted = EditorSessionPersistence(url: url, credentials: credentials)
        let recovered = try await restarted.open(in: workspace)
        XCTAssertEqual(recovered.drafts[0].body, "recover this body")
        XCTAssertEqual(recovered.drafts[0].credential, "draft-secret-marker")
        XCTAssertEqual(workspace.requests[0].body, "")
    }
    func testStaleCheckpointWriterCannotReplaceOtherInstance() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = Workspace.starter, url = directory.appendingPathComponent("session.json")
        let first = EditorSessionPersistence(url: url, credentials: TestCredentials())
        let second = EditorSessionPersistence(url: url, credentials: TestCredentials())
        let a = try await first.open(in: workspace), b = try await second.open(in: workspace)
        try await first.checkpoint(a, workspace: workspace)
        do { try await second.checkpoint(b, workspace: workspace); XCTFail("Stale checkpoint accepted") }
        catch { XCTAssertEqual(error as? WorkspaceError, .conflict) }
    }
    func testBackupOmitsAuthSecretsAndChecksumRejectsTamperingAndZipData() throws {
        var workspace = Workspace.starter; workspace.requests[0].credential = "saved-secret-marker"
        var editor = EditorSessionState(); var draft = workspace.requests[0]; draft.body = "draft body"; draft.credential = "draft-secret-marker"
        try editor.update(draft, savedIn: workspace)
        let data = try WorkspaceBackup.encode(workspace: workspace, editor: editor)
        let recovered = try WorkspaceBackup.decode(data)
        XCTAssertEqual(recovered.workspace.requests[0].credential, "")
        XCTAssertEqual(recovered.editor?.drafts[0].credential, "")
        XCTAssertEqual(recovered.editor?.drafts[0].body, "draft body")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["checksum"] = "tampered"
        XCTAssertThrowsError(try WorkspaceBackup.decode(JSONSerialization.data(withJSONObject: object)))
        XCTAssertThrowsError(try WorkspaceBackup.decode(Data([0x50, 0x4b, 0x03, 0x04])))
    }
    func testRestoreRetainsPreviousWorkspaceAndRejectsOverwriteOfRecoveryCopy() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("workspace.json"), previous = directory.appendingPathComponent("previous.rillbackup")
        let session = WorkspaceSession(url: url, credentials: TestCredentials())
        var current = try await session.open(); current.requests[0].name = "Before restore"
        try await session.save(current)
        var target = Workspace.starter; target.requests[0].name = "Restored"
        let contents = try WorkspaceBackup.decode(WorkspaceBackup.encode(workspace: target, editor: nil))
        let restored = try await session.restore(contents, retainingPreviousAt: previous, editor: nil)
        XCTAssertEqual(restored.requests[0].name, "Restored")
        XCTAssertEqual(try WorkspaceBackup.load(from: previous).workspace.requests[0].name, "Before restore")
        XCTAssertEqual(try WorkspaceFile.load(from: url).requests[0].name, "Restored")
        let previousBytes = try Data(contentsOf: previous)
        do { _ = try await session.restore(contents, retainingPreviousAt: previous, editor: nil); XCTFail("Recovery copy overwritten") } catch { }
        XCTAssertEqual(try Data(contentsOf: previous), previousBytes)
        do { _ = try await session.restore(contents, retainingPreviousAt: url, editor: nil); XCTFail("Active file used as recovery copy") } catch { }
    }
    func testCorruptCheckpointIsPreservedAndCannotBeOverwritten() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("session.json"), corrupt = Data("{broken".utf8)
        try corrupt.write(to: url)
        let persistence = EditorSessionPersistence(url: url, credentials: TestCredentials())
        do { _ = try await persistence.open(in: .starter); XCTFail("Invalid checkpoint accepted") } catch { }
        do { try await persistence.checkpoint(EditorSessionState(), workspace: .starter); XCTFail("Invalid checkpoint overwritten") } catch { }
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
    }
}
