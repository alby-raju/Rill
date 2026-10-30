import XCTest

@testable import RillCore

final class NativeFileRunTests: XCTestCase {
    private func request(_ collection: UUID? = nil, url: String = "http://127.0.0.1:1")
        -> RequestDraft
    {
        var request = RequestDraft(collectionID: collection)
        request.method = .POST
        request.url = url
        return request
    }
    private func bytes(_ requests: [RequestDraft]) throws -> Data {
        var workspace = Workspace()
        workspace.requests = requests
        return try WorkspaceFile.encode(workspace)
    }
    func testSelectionEnvironmentInheritanceOverridesAndProcessSecretBinding() throws {
        let collection = RequestCollection(name: "Selected")
        let other = RequestCollection(name: "Other")
        var parent = Environment(name: "Parent")
        parent.variables = [
            Field(name: "tag", value: "parent"), Field(name: "inherited", value: "yes"),
        ]
        var child = Environment(name: "Child")
        child.parentID = parent.id
        child.variables = [Field(name: "tag", value: "child")]
        let secret = NamedSecret(name: "service-token")
        var profile = AuthenticationProfile()
        profile.secretName = secret.name
        var selected = request(collection.id)
        selected.authProfileID = profile.id
        var excluded = request(other.id)
        excluded.foreignScripts = [
            .init(origin: "fixture", stage: "test", source: "excluded-script")
        ]
        var workspace = Workspace()
        workspace.collections = [other, collection]
        workspace.requests = [excluded, selected, request(collection.id)]
        workspace.environments = [parent, child]
        workspace.selectedEnvironmentID = parent.id
        workspace.namedSecrets = [secret]
        workspace.authProfiles = [profile]
        let plan = try NativeFileRun.prepare(
            workspace: WorkspaceFile.encode(workspace), collection: "Selected",
            environment: "Child",
            overrides: ["tag": "", "override": "yes"],
            processEnvironment: [
                "RILL_SECRET_SERVICE_TOKEN": "fixture-process-secret", "UNRELATED": "ignored",
            ])
        XCTAssertEqual(plan.requests.map(\.id), [selected.id, workspace.requests[2].id])
        let values = WorkflowEngine.variables(in: plan.environment)
        XCTAssertEqual(values["tag"], "")
        XCTAssertEqual(values["inherited"], "yes")
        XCTAssertEqual(values["override"], "yes")
        XCTAssertEqual(try plan.secrets.resolve(secret.name), "fixture-process-secret")
        XCTAssertThrowsError(try plan.secrets.resolve("UNRELATED"))
        let prepared = try RequestEngine.prepare(
            selected, environment: plan.environment, profiles: [profile], secrets: plan.secrets)
        XCTAssertEqual(
            prepared.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-process-secret")
        XCTAssertThrowsError(try NativeFileRun.prepare(workspace: WorkspaceFile.encode(workspace)))
        let noProcess = try NativeFileRun.prepare(
            workspace: WorkspaceFile.encode(workspace), collection: "Selected")
        XCTAssertThrowsError(try noProcess.secrets.resolve(secret.name))
        let byID = try NativeFileRun.prepare(
            workspace: WorkspaceFile.encode(workspace),
            collection: collection.id.uuidString.lowercased())
        XCTAssertEqual(byID.requests.count, 2)
        XCTAssertEqual(WorkflowEngine.variables(in: byID.environment)["tag"], "parent")
    }
    func testMissingAmbiguousEmptyAndInvalidInputsBlock() throws {
        let a = RequestCollection(name: "duplicate")
        let b = RequestCollection(name: "duplicate")
        var workspace = Workspace()
        workspace.collections = [a, b]
        workspace.requests = [request(a.id)]
        let data = try WorkspaceFile.encode(workspace)
        for selector in ["missing", "duplicate", b.id.uuidString] {
            XCTAssertThrowsError(try NativeFileRun.prepare(workspace: data, collection: selector))
        }
        XCTAssertThrowsError(try NativeFileRun.prepare(workspace: data, environment: "missing"))
        workspace.environments = [Environment(name: "duplicate"), Environment(name: "duplicate")]
        XCTAssertThrowsError(
            try NativeFileRun.prepare(
                workspace: WorkspaceFile.encode(workspace), environment: "duplicate"))
        XCTAssertThrowsError(try NativeFileRun.prepare(workspace: bytes([])))
        XCTAssertThrowsError(try NativeFileRun.prepare(workspace: data, overrides: ["": "value"]))
        XCTAssertThrowsError(
            try NativeFileRun.prepare(
                workspace: data, overrides: ["x": String(repeating: "x", count: 1024 * 1024 + 1)]))
        workspace.requests.append(workspace.requests[0])
        XCTAssertThrowsError(try NativeFileRun.prepare(workspace: JSONEncoder().encode(workspace)))
        workspace.requests.removeLast()
        workspace.version = 99
        XCTAssertThrowsError(try NativeFileRun.prepare(workspace: JSONEncoder().encode(workspace)))
    }
    func testForeignScriptsUploadsInvalidHooksAndKeychainIdentitiesBlockBeforeRun() throws {
        var foreign = request()
        foreign.foreignScripts = [.init(origin: "fixture", stage: "test", source: "private-script")]
        XCTAssertThrowsError(try NativeFileRun.prepare(workspace: bytes([request(), foreign])))
        var upload = request()
        upload.bodyMode = .binary
        XCTAssertThrowsError(try NativeFileRun.prepare(workspace: bytes([request(), upload])))
        var hook = RequestHook()
        hook.enabled = true
        hook.source = #"[{"op":"unsupported"}]"#
        var invalidHook = request()
        invalidHook.postHook = hook
        XCTAssertThrowsError(try NativeFileRun.prepare(workspace: bytes([request(), invalidHook])))
        var missingProfile = request()
        missingProfile.authProfileID = UUID()
        XCTAssertThrowsError(
            try NativeFileRun.prepare(workspace: bytes([request(), missingProfile])))
        var tls = TLSProfile()
        tls.identityReference = Data("not-a-real-keychain-reference".utf8)
        var selected = request()
        selected.tlsProfileID = tls.id
        var workspace = Workspace()
        workspace.requests = [request(), selected]
        workspace.tlsProfiles = [tls]
        XCTAssertThrowsError(try NativeFileRun.prepare(workspace: WorkspaceFile.encode(workspace)))
        {
            guard case NativeFileRunError.unsupportedIdentity = $0 else {
                return XCTFail("Wrong blocker")
            }
        }
        tls.identityReference = nil
        tls.mode = .insecure
        workspace.tlsProfiles = [tls]
        let data = try WorkspaceFile.encode(workspace)
        XCTAssertThrowsError(try NativeFileRun.prepare(workspace: data)) {
            guard case NativeFileRunError.insecureNotAllowed = $0 else {
                return XCTFail("Wrong blocker")
            }
        }
        XCTAssertEqual(
            try NativeFileRun.prepare(workspace: data, allowInsecure: true).requests.count, 2)
    }
    func testNativeChecksPreserveExpectedErrorStatusAndUncheckedResponsesRequire2xx() async throws {
        guard let base = ProcessInfo.processInfo.environment["RILL_TEST_BASE_URL"] else {
            throw XCTSkip("Fixture required")
        }
        var expected = request(url: base + "/oauth/token")
        expected.expectedStatus = "400"
        let native = try NativeFileRun.prepare(workspace: bytes([expected]))
        let allowedError = try await native.run(configuration: RunConfiguration())
        XCTAssertTrue(allowedError.passed)
        XCTAssertEqual(allowedError.outcomes[0].status, 400)
        expected.expectedStatus = ""
        let unchecked = try NativeFileRun.prepare(workspace: bytes([expected]))
        let rejectedError = try await unchecked.run(configuration: RunConfiguration())
        XCTAssertFalse(rejectedError.passed)
        XCTAssertEqual(rejectedError.outcomes[0].checks.count, 1)
        expected.expectedStatus = "201"
        expected.url = base + "/echo"
        let failedAssertion = try NativeFileRun.prepare(workspace: bytes([expected]))
        let failed = try await failedAssertion.run(configuration: RunConfiguration())
        XCTAssertFalse(failed.passed)
    }
    func testNativeHooksAndResponseExtractionChainThroughSharedEngine() async throws {
        guard let base = ProcessInfo.processInfo.environment["RILL_TEST_BASE_URL"] else {
            throw XCTSkip("Fixture required")
        }
        var first = request(url: base + "/echo")
        var hook = RequestHook()
        hook.enabled = true
        hook.source = #"[{"op":"set","name":"tag","value":"hook"}]"#
        first.preHook = hook
        var extraction = ResponseExtraction()
        extraction.selector = "$.path"
        extraction.variable = "prior"
        first.extractions = [extraction]
        var second = request(url: base + "/echo")
        second.bodyMode = .text
        second.body = "{{prior}}/{{tag}}"
        let plan = try NativeFileRun.prepare(workspace: bytes([first, second]))
        let result = try await plan.run(configuration: RunConfiguration())
        XCTAssertTrue(result.passed)
        XCTAssertEqual(result.outcomes.map(\.requestID), [first.id, second.id])
        let body = try XCTUnwrap(result.outcomes.last?.retainedBody)
        let echo = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(echo["body"] as? String, Data("/echo/hook".utf8).base64EncodedString())
    }
    func testCancelledNativePreparationStopsBeforeParsing() async throws {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try NativeFileRun.prepare(workspace: Data())
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled plan succeeded")
        } catch is CancellationError {}
    }
}
