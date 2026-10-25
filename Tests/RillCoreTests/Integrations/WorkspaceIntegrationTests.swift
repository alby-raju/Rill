import XCTest

@testable import RillCore

@MainActor final class WorkspaceIntegrationTests: XCTestCase {
    func testReadOnlyShareRequiresTokenScrubsAndPullRefusesOverwrite() async throws {
        var workspace = Workspace()
        var request = RequestDraft()
        request.url = "https://user:private@example.com/path?token=private"
        request.body = "private-body"
        request.credential = "private-credential"
        request.headers = [Field(name: "Authorization", value: "private-header")]
        workspace.requests = [request]
        var environment = Environment(name: "Test")
        environment.variables = [Field(name: "token", value: "private-environment")]
        workspace.environments = [environment]
        let token = try WorkspaceSharing.token()
        let server = WorkspaceShareServer()
        let url = try await server.start(workspace: workspace, token: token)
        var probe = RequestDraft()
        probe.url = url.absoluteString
        let rejected = try await RequestEngine.execute(probe, environment: nil)
        XCTAssertEqual(rejected.status, 401)
        probe.auth = .bearer
        probe.credential = String(repeating: "x", count: 64)
        let wrong = try await RequestEngine.execute(probe, environment: nil)
        XCTAssertEqual(wrong.status, 401)
        probe.credential = token
        let response = try await RequestEngine.execute(probe, environment: nil)
        XCTAssertEqual(response.status, 200)
        XCTAssertFalse(response.text.contains("private"))
        let shared = try WorkspaceSharing.decode(response.body)
        XCTAssertTrue(shared.history.isEmpty)
        XCTAssertNil(shared.authProfiles)
        XCTAssertNil(shared.requests[0].preHook)
        XCTAssertEqual(shared.requests[0].auth, .none)
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: destination) }
        try await WorkspaceSharing.pull(url, token: token, destination: destination)
        XCTAssertNotEqual(try WorkspaceFile.load(from: destination).requests.first?.id, request.id)
        do {
            try await WorkspaceSharing.pull(url, token: token, destination: destination)
            XCTFail("Existing destination must not change")
        } catch {}
        probe.method = .POST
        let mutation = try await RequestEngine.execute(probe, environment: nil)
        XCTAssertEqual(mutation.status, 405)
        await server.stop()
    }
    func testGitOnlyCommitsPortableWorkspaceAndNeverRunsHooks() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "rill-git-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await WorkspaceGit.initialize(directory)
        var workspace = Workspace()
        var request = RequestDraft()
        request.credential = "private-keychain"
        workspace.requests = [request]
        try WorkspaceGit.export(workspace, to: directory)
        let config = directory.appendingPathComponent(".git/config")
        var text = try String(contentsOf: config, encoding: .utf8)
        text += "\n[user]\nname = Rill Fixture\nemail = fixture@example.invalid\n"
        try text.write(to: config, atomically: false, encoding: .utf8)
        let hook = directory.appendingPathComponent(".git/hooks/pre-commit")
        try "#!/bin/sh\nexit 99\n".write(to: hook, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook.path)
        let commit = try await WorkspaceGit.commit(directory, message: "Independent fixture")
        XCTAssertEqual(commit.count, 40)
        let status = try await WorkspaceGit.status(directory)
        XCTAssertEqual(status, "")
        XCTAssertFalse(
            try String(
                contentsOf: directory.appendingPathComponent("workspace.json"), encoding: .utf8
            ).contains("private-keychain"))
    }
    func testPluginTrustIsContentBoundAndMockServicesStayDataOnly() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "rill-plugin-" + UUID().uuidString)
        let directory = root.appendingPathComponent("fixture")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = Data(
            #"{"apiVersion":1,"id":"fixture","name":"Fixture","version":"1","services":[{"id":"routes","kind":"mockRoutes","file":"routes.json"}]}"#
                .utf8)
        try manifest.write(to: directory.appendingPathComponent("rill-plugin.json"))
        var route = MockRoute()
        route.path = "/fixture"
        let file = directory.appendingPathComponent("routes.json")
        try MockRouteFile.encode([route]).write(to: file)
        let plugins = try PluginRegistry.discover(root)
        var trust = PluginTrust()
        let disabled = PluginRegistry(
            plugins: plugins, trust: trust, context: PluginContext(workspace: Workspace()))
        XCTAssertThrowsError(try disabled.mockRoutes(plugin: "fixture", service: "routes"))
        trust.enable(plugins[0])
        let registry = PluginRegistry(
            plugins: plugins, trust: trust, context: PluginContext(workspace: Workspace()))
        XCTAssertEqual(
            try registry.mockRoutes(plugin: "fixture", service: "routes").first?.path, "/fixture")
        route.body = "changed"
        try MockRouteFile.encode([route]).write(to: file)
        XCTAssertThrowsError(try registry.mockRoutes(plugin: "fixture", service: "routes"))
        XCTAssertFalse(trust.allows(try PluginRegistry.discover(root)[0]))
        let trustFile = root.appendingPathComponent("trust.json")
        try Data(#"{"approved":{"fixture":"invalid"}}"#.utf8).write(to: trustFile)
        XCTAssertThrowsError(try PluginTrust.load(trustFile))
    }

}
