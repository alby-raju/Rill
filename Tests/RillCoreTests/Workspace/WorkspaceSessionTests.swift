import XCTest
@testable import RillCore

final class TestCredentials: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID: String] = [:]
    private var failRead = false
    private var failWrite = false
    private var writeCount = 0
    func failures(read: Bool = false, write: Bool = false) {
        lock.withLock { failRead = read; failWrite = write }
    }
    func read(_ id: UUID) throws -> String {
        try lock.withLock {
            if failRead { throw NSError(domain: NSOSStatusErrorDomain, code: -1) }
            return values[id] ?? ""
        }
    }
    func write(_ value: String, id: UUID) throws {
        try lock.withLock {
            if failWrite { throw NSError(domain: NSOSStatusErrorDomain, code: -1) }
            writeCount += 1
            if value.isEmpty { values.removeValue(forKey: id) }
            else { values[id] = value }
        }
    }
    var count: Int { lock.withLock { writeCount } }
    var nonemptyCount: Int { lock.withLock { values.count } }
}

@MainActor final class WorkspaceSessionTests: XCTestCase {
    private func temporary() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("workspace.json")
    }
    func testReadFailureCannotBecomeAnEmptySavedCredential() async throws {
        let file = try temporary()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let original = Workspace.starter
        try WorkspaceFile.save(original, to: file)
        let bytes = try Data(contentsOf: file)
        let credentials = TestCredentials(); credentials.failures(read: true)
        let session = WorkspaceSession(url: file, credentials: credentials)
        do { _ = try await session.open(); XCTFail("Denied credential read was accepted") } catch { }
        do { try await session.save(original); XCTFail("Unopened session saved") } catch { }
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        XCTAssertEqual(credentials.count, 0)
    }
    func testCredentialFailureCanRetryWithoutFalseWorkspaceConflict() async throws {
        let file = try temporary()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let credentials = TestCredentials()
        let session = WorkspaceSession(url: file, credentials: credentials)
        var workspace = try await session.open()
        workspace.requests[0].credential = "pending-secret"
        credentials.failures(write: true)
        do { try await session.save(workspace); XCTFail("Credential write failure was ignored") } catch { }
        XCTAssertEqual(try WorkspaceFile.load(from: file).requests[0].credential, "")
        credentials.failures()
        try await session.save(workspace)
        XCTAssertEqual(try credentials.read(workspace.requests[0].id), "pending-secret")
        XCTAssertFalse(String(decoding: try Data(contentsOf: file), as: UTF8.self).contains("pending-secret"))
    }
    func testUnchangedCredentialsAreNotRewrittenAndDeletionFollowsSuccessfulSave() async throws {
        let file = try temporary()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let credentials = TestCredentials()
        let session = WorkspaceSession(url: file, credentials: credentials)
        var workspace = try await session.open()
        let id = workspace.requests[0].id
        workspace.requests[0].credential = "secret"
        try await session.save(workspace)
        let saved = credentials.count
        workspace.requests[0].name = "Rename only"
        try await session.save(workspace)
        XCTAssertEqual(credentials.count, saved)
        workspace.requests.removeAll()
        try await session.save(workspace)
        XCTAssertEqual(try credentials.read(id), "")
        XCTAssertEqual(credentials.count, saved + 1)
    }
    func testStaleSessionCannotOverwriteCredentialOnlyChanges() async throws {
        let file = try temporary()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let credentials = TestCredentials()
        let seed = WorkspaceSession(url: file, credentials: credentials)
        let initial = try await seed.open()
        try await seed.save(initial)
        let first = WorkspaceSession(url: file, credentials: credentials)
        let second = WorkspaceSession(url: file, credentials: credentials)
        var a = try await first.open(), b = try await second.open()
        a.requests[0].credential = "new-secret"
        try await first.save(a)
        do { try await second.save(b); XCTFail("Stale credential write was accepted") }
        catch { XCTAssertEqual(error as? WorkspaceError, .conflict) }
        XCTAssertEqual(try credentials.read(a.requests[0].id), "new-secret")
    }
}
