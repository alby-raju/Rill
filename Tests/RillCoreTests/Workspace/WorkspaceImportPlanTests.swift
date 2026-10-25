import XCTest
@testable import RillCore

@MainActor final class WorkspaceImportPlanTests: XCTestCase {
    private func url() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }; return directory.appendingPathComponent("workspace.json")
    }
    func testPreviewExplainsDiscardedCredentialsAndRegeneratedDescriptorsWithoutChangingInputs() throws {
        var incoming = Workspace.starter; incoming.requests[0].credential = "SEEDED_SECRET"; incoming.namedSecrets = [NamedSecret(name: "token")]
        var trust = TLSProfile(); trust.mode = .insecure; trust.identityReference = Data([1]); trust.requiresClientIdentity = true; incoming.tlsProfiles = [trust]
        let current = Workspace.starter, before = incoming
        let plan = try WorkspaceImportPlan(incoming: incoming, current: current)
        XCTAssertEqual(plan.preview.requests, 1); XCTAssertEqual(plan.preview.secretDescriptors, 1)
        XCTAssertEqual(plan.preview.requestNames, incoming.requests.map(\.name))
        XCTAssertTrue(plan.preview.warnings.contains { $0.contains("discarded") }); XCTAssertTrue(plan.preview.warnings.contains { $0.contains("insecure") })
        XCTAssertFalse(plan.preview.warnings.joined().contains("SEEDED_SECRET")); XCTAssertEqual(incoming, before)
        let applied = try plan.applying(to: current)
        XCTAssertEqual(applied.requests.count, 2); XCTAssertEqual(applied.requests[1].credential, ""); XCTAssertNotEqual(applied.requests[1].id, incoming.requests[0].id)
    }
    func testPlanRejectsUserEditsButPreservesSessionOnlyActivity() throws {
        let baseline = Workspace.starter, plan = try WorkspaceImportPlan(incoming: Workspace.starter, current: baseline)
        var changed = baseline; changed.requests[0].name = "Edited"
        XCTAssertThrowsError(try plan.applying(to: changed))
        var active = baseline
        active.history = [Exchange(requestID: baseline.requests[0].id, requestName: "Recent", method: .GET, url: "https://example.test", status: 200, duration: 0.1, headers: [], body: Data(), checks: [])]
        XCTAssertEqual(try plan.applying(to: active).history, active.history)
    }
    func testImportCommitNeedsNoKeychainWritesAndSurvivesCompanionWriteDenial() async throws {
        let location = try url(), credentials = TestCredentials(), session = WorkspaceSession(url: location, credentials: credentials)
        let baseline = try await session.open(); try await session.save(baseline)
        let before = credentials.count
        credentials.failures(write: true)
        let plan = try WorkspaceImportPlan(incoming: Workspace.starter, current: baseline)
        let applied = try await session.applyImport(plan, current: baseline)
        XCTAssertEqual(credentials.count, before)
        XCTAssertEqual(try WorkspaceFile.load(from: location).requests.count, applied.requests.count)
    }
    func testStaleImportDoesNotChangeDiskOrCredentialStore() async throws {
        let location = try url(), credentials = TestCredentials(), first = WorkspaceSession(url: location, credentials: credentials), second = WorkspaceSession(url: location, credentials: credentials)
        let baseline = try await first.open(); try await first.save(baseline)
        var newer = try await second.open(); newer.requests[0].name = "Newer"; try await second.save(newer)
        let bytes = try Data(contentsOf: location), count = credentials.count
        let plan = try WorkspaceImportPlan(incoming: Workspace.starter, current: baseline)
        do { _ = try await first.applyImport(plan, current: baseline); XCTFail("Stale import succeeded") } catch { XCTAssertEqual(error as? WorkspaceError, .conflict) }
        XCTAssertEqual(try Data(contentsOf: location), bytes); XCTAssertEqual(credentials.count, count)
    }
    func testInvalidPlanAndExportPreserveDestination() throws {
        var invalid = Workspace.starter; invalid.requests.append(invalid.requests[0])
        XCTAssertThrowsError(try WorkspaceImportPlan(incoming: invalid, current: Workspace.starter))
        let location = try url(); try Data("original destination".utf8).write(to: location)
        XCTAssertThrowsError(try WorkspaceFile.save(invalid, to: location))
        XCTAssertEqual(try Data(contentsOf: location), Data("original destination".utf8))
    }
}
