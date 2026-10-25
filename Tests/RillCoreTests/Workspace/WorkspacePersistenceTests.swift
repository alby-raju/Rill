import XCTest
import Darwin
@testable import RillCore

final class WorkspacePersistenceTests: XCTestCase {
    private func withFile(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory.appendingPathComponent("workspace.json"))
    }
    func testDanglingCollectionAndEnvironmentReferencesAreRejected() throws {
        var workspace = Workspace.starter
        workspace.requests[0].collectionID = UUID()
        XCTAssertThrowsError(try WorkspaceFile.validate(workspace))
        workspace = .starter
        workspace.selectedEnvironmentID = UUID()
        XCTAssertThrowsError(try WorkspaceFile.validate(workspace))
    }
    func testDuplicateFieldIdentitiesAndInvalidTimeoutAreRejected() throws {
        var workspace = Workspace.starter
        let field = Field(name: "q", value: "1")
        workspace.requests[0].parameters = [field, field]
        XCTAssertThrowsError(try WorkspaceFile.validate(workspace))
        workspace.requests[0].parameters = []
        workspace.requests[0].timeout = .infinity
        XCTAssertThrowsError(try WorkspaceFile.validate(workspace))
    }
    func testInvalidSavePreservesOriginalBytes() throws {
        try withFile { file in
            var workspace = Workspace.starter
            try WorkspaceFile.save(workspace, to: file)
            let original = try Data(contentsOf: file)
            workspace.requests.append(workspace.requests[0])
            XCTAssertThrowsError(try WorkspaceFile.save(workspace, to: file))
            XCTAssertEqual(try Data(contentsOf: file), original)
        }
    }
    func testUnknownSchemaAndCorruptionAreNeverOverwritten() throws {
        try withFile { file in
            var workspace = Workspace.starter; workspace.version = 99
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let unsupported = try JSONEncoder().encode(workspace)
            try unsupported.write(to: file)
            let repository = WorkspaceRepository(url: file)
            XCTAssertThrowsError(try repository.load()) { XCTAssertEqual($0 as? WorkspaceError, .unsupportedVersion(99)) }
            XCTAssertThrowsError(try repository.commit(.starter, expecting: .absent))
            XCTAssertEqual(try Data(contentsOf: file), unsupported)
            let corrupt = Data("{broken".utf8); try corrupt.write(to: file)
            XCTAssertThrowsError(try repository.load())
            XCTAssertThrowsError(try repository.commit(.starter, expecting: .absent))
            XCTAssertEqual(try Data(contentsOf: file), corrupt)
        }
    }
    func testStaleWriterCannotReplaceNewerWorkspace() throws {
        try withFile { file in
            let first = WorkspaceRepository(url: file), second = WorkspaceRepository(url: file)
            let a = try first.load(), b = try second.load()
            var updated = a.workspace; updated.requests[0].name = "Newer edit"
            let revision = try first.commit(updated, expecting: a.revision)
            XCTAssertNotEqual(revision, a.revision)
            XCTAssertThrowsError(try second.commit(b.workspace, expecting: b.revision)) { XCTAssertEqual($0 as? WorkspaceError, .conflict) }
            XCTAssertEqual(try first.load().workspace.requests[0].name, "Newer edit")
        }
    }
    func testExternalEditAndExternalDeletionCauseConflicts() throws {
        try withFile { file in
            let repository = WorkspaceRepository(url: file)
            let initial = try repository.load()
            _ = try repository.commit(initial.workspace, expecting: initial.revision)
            let snapshot = try repository.load()
            var external = snapshot.workspace; external.requests[0].name = "External"
            try WorkspaceFile.save(external, to: file)
            XCTAssertThrowsError(try repository.commit(snapshot.workspace, expecting: snapshot.revision))
            try FileManager.default.removeItem(at: file)
            XCTAssertThrowsError(try repository.commit(snapshot.workspace, expecting: snapshot.revision))
        }
    }
    func testHeldLockFailsWithoutBlockingOrChangingFile() throws {
        try withFile { file in
            try WorkspaceFile.save(.starter, to: file)
            let repository = WorkspaceRepository(url: file)
            let snapshot = try repository.load()
            let descriptor = Darwin.open(file.appendingPathExtension("lock").path, O_RDWR | O_CREAT, 0o600)
            XCTAssertGreaterThanOrEqual(descriptor, 0)
            defer { Darwin.close(descriptor) }
            XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
            defer { flock(descriptor, LOCK_UN) }
            XCTAssertThrowsError(try repository.commit(snapshot.workspace, expecting: snapshot.revision)) { XCTAssertEqual($0 as? WorkspaceError, .unavailable) }
        }
    }
    func testWorkspaceFilePermissionsArePrivate() throws {
        try withFile { file in
            try WorkspaceFile.save(.starter, to: file)
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
    }
    func testOversizedWorkspaceAndDeepJSONAreRejected() throws {
        XCTAssertThrowsError(try WorkspaceFile.decode(Data(repeating: 32, count: ResourceLimits.workspaceBytes + 1))) { XCTAssertEqual($0 as? WorkspaceError, .tooLarge) }
        let depth = ResourceLimits.jsonDepth + 1
        let deep = String(repeating: "[", count: depth) + "0" + String(repeating: "]", count: depth)
        XCTAssertThrowsError(try WorkspaceFile.decode(Data(deep.utf8))) { XCTAssertEqual($0 as? WorkspaceError, .tooDeep) }
    }
    func testBracketsAndEscapesInsideStringsDoNotCountAsNesting() throws {
        var workspace = Workspace.starter
        workspace.requests[0].body = String(repeating: "[\\\"{}", count: 200)
        let data = try WorkspaceFile.encode(workspace)
        XCTAssertEqual(try WorkspaceFile.decode(data).requests, workspace.requests)
    }
    func testLegacyVersionOneRoundTripPreservesIdentities() throws {
        try withFile { file in
            let workspace = Workspace.starter
            // Represents the original version-one encoding without extra envelope fields.
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(workspace).write(to: file)
            let repository = WorkspaceRepository(url: file)
            let loaded = try repository.load()
            _ = try repository.commit(loaded.workspace, expecting: loaded.revision)
            XCTAssertEqual(try repository.load().workspace.requests, workspace.requests)
        }
    }
    func testRepeatedImportsRemapIdentitiesAndStripCredentialsWithoutChangingExistingData() throws {
        let existing = Workspace.starter
        var incoming = Workspace.starter
        incoming.requests[0].credential = "imported-sensitive-token"
        let once = try WorkspaceImport.merging(incoming, into: existing)
        let twice = try WorkspaceImport.merging(incoming, into: once)
        XCTAssertEqual(existing.requests.count, 1)
        XCTAssertEqual(twice.requests.count, 3)
        XCTAssertEqual(twice.requests[0], existing.requests[0])
        XCTAssertEqual(Set(twice.requests.map(\.id)).count, 3)
        XCTAssertEqual(Set(twice.collections.map(\.id)).count, 3)
        XCTAssertEqual(twice.requests[1].collectionID, twice.collections[1].id)
        XCTAssertEqual(twice.requests[2].collectionID, twice.collections[2].id)
        XCTAssertEqual(twice.requests[1].credential, "")
    }
    func testInvalidImportCannotProduceAnAppliedWorkspace() throws {
        let existing = Workspace.starter
        var incoming = Workspace.starter
        incoming.requests[0].collectionID = UUID()
        XCTAssertThrowsError(try WorkspaceImport.merging(incoming, into: existing))
        XCTAssertEqual(existing.requests.count, 1)
    }

    func testIdenticalSavesStillInvalidateStaleWriters() throws {
        try withFile { file in
            let repository = WorkspaceRepository(url: file)
            let initial = try repository.load()
            _ = try repository.commit(initial.workspace, expecting: initial.revision)
            let a = try repository.load(), b = try repository.load()
            let next = try repository.commit(a.workspace, expecting: a.revision)
            XCTAssertNotEqual(next, a.revision)
            XCTAssertThrowsError(try repository.commit(b.workspace, expecting: b.revision)) { XCTAssertEqual($0 as? WorkspaceError, .conflict) }
        }
    }
    func testCompanionFailureReceivesCommittedRevisionForRetry() throws {
        try withFile { file in
            let repository = WorkspaceRepository(url: file)
            let snapshot = try repository.load()
            var committed: WorkspaceRevision?
            XCTAssertThrowsError(try repository.commit(snapshot.workspace, expecting: snapshot.revision) { revision in
                committed = revision
                throw WorkspaceError.unavailable
            })
            let accepted = try XCTUnwrap(committed)
            XCTAssertEqual(try repository.load().revision, accepted)
            XCTAssertNoThrow(try repository.commit(snapshot.workspace, expecting: accepted))
        }
    }

}
