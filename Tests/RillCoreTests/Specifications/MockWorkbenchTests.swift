import XCTest

@testable import RillCore

@MainActor final class MockWorkbenchTests: XCTestCase {
    func call(
        _ base: URL, path: String = "/", method: HTTPMethod = .GET, headers: [Field] = [],
        body: String = ""
    ) async throws -> Exchange {
        var request = RequestDraft()
        request.url = base.absoluteString + path
        request.method = method
        request.headers = headers
        request.body = body
        request.bodyMode = body.isEmpty ? RequestBodyMode.none : .text
        return try await RequestEngine.execute(request, environment: nil)
    }
    func testProjectAndWorkspaceRoundTripsRetainDraftButPortableFileDoesNot() throws {
        var route = MockRoute()
        route.query = [Field(name: "mode", value: "blue")]
        route.requestHeaders = [Field(name: "X-Test", value: "ok")]
        route.expectedBody = "exact"
        route.delayMilliseconds = 20
        route.scenario = MockScenario(name: "flow", nextState: "done")
        route.origin = MockFixtureOrigin(kind: .response, sourceID: UUID())
        var project = MockProject(name: "Saved", routes: [route])
        project.jsonDraft = "UNAPPLIED private draft"
        project.port = 4567
        var workspace = Workspace()
        workspace.mockProjects = [project]
        let stored = try JSONEncoder().encode(workspace)
        XCTAssertEqual(
            try JSONDecoder().decode(Workspace.self, from: stored).mockProjects, [project])
        let portable = try MockProjectFile.encode(project)
        XCTAssertFalse(String(decoding: portable, as: UTF8.self).contains("UNAPPLIED"))
        let decoded = try MockProjectFile.decode(portable)
        XCTAssertNil(decoded.jsonDraft)
        XCTAssertEqual(decoded.port, 4567)
        XCTAssertEqual(
            try MockRouteFile.encode(decoded.routes), try MockRouteFile.encode(project.routes))
        XCTAssertNil(try WorkspaceSharing.sanitized(workspace).mockProjects)
        let imported = try WorkspaceImport.merging(workspace, into: Workspace())
        XCTAssertEqual(imported.mockProjects?.first?.jsonDraft, project.jsonDraft)
        XCTAssertNotEqual(imported.mockProjects?.first?.id, project.id)
        XCTAssertNil(
            try JSONDecoder().decode(Workspace.self, from: JSONEncoder().encode(Workspace()))
                .mockProjects)
    }
    func testStrictPortableValidationAndEditableStorageBounds() throws {
        var project = MockProject()
        project.routes = [MockRoute()]
        let data = try MockProjectFile.encode(project)
        let text = String(decoding: data, as: UTF8.self)
        for bad in [
            text.replacingOccurrences(of: "\"version\" : 1", with: "\"version\" : true"),
            text.replacingOccurrences(of: "\"version\" : 1", with: "\"version\" : 2"),
            text.replacingOccurrences(of: "\"port\" : 0", with: "\"port\" : 0.5"),
        ] {
            XCTAssertNotEqual(bad, text)
            XCTAssertThrowsError(try MockProjectFile.decode(Data(bad.utf8)))
        }
        XCTAssertThrowsError(
            try MockRouteFile.decode(
                Data(
                    #"[{"method":"GET","path":"/","status":200,"body":"","requestHeaders":[{"name":"X","value":"Y","enabled":1}]}]"#
                        .utf8)))
        project.routes[0].path = "not yet valid"
        XCTAssertNoThrow(try MockProject.validateStorage([project]))
        XCTAssertThrowsError(try MockProjectFile.encode(project))
        project.jsonDraft = String(repeating: "x", count: 4 * 1024 * 1024 + 1)
        XCTAssertThrowsError(try MockProject.validateStorage([project]))
    }
    func testMatchingPredicatesAndUnmatchedAreRealWireBehavior() async throws {
        var route = MockRoute()
        route.method = .POST
        route.path = "/pets/{id}"
        route.body = "matched"
        route.query = [Field(name: "color", value: "blüe")]
        route.requestHeaders = [Field(name: "X-Mode", value: "exact")]
        route.expectedBody = "payload"
        let server = MockServer()
        let base = try await server.start(routes: [route])
        do {
            let good = try await call(
                base, path: "/pets/3?color=bl%C3%BCe&extra=yes", method: .POST,
                headers: [Field(name: "x-mode", value: "exact")], body: "payload")
            XCTAssertEqual(good.text, "matched")
            let bad = try await call(
                base, path: "/pets/3?color=bl%C3%BCe", method: .POST,
                headers: [Field(name: "X-Mode", value: "wrong")], body: "payload")
            XCTAssertEqual(bad.status, 404)
            let records = await server.journal()
            XCTAssertEqual(records.count, 2)
            XCTAssertEqual(records[0].path, "/pets/3")
            XCTAssertEqual(records[0].routeIndex, 0)
            XCTAssertNil(records[1].routeIndex)
        } catch {
            await server.stop()
            throw error
        }
        await server.stop()
    }
    func testScenarioTransitionsResetAndDelayFault() async throws {
        var first = MockRoute()
        first.body = "first"
        first.delayMilliseconds = 30
        first.scenario = MockScenario(name: "flow", nextState: "done")
        var second = MockRoute()
        second.body = "second"
        second.scenario = MockScenario(name: "flow", requiredState: "done")
        var fault = MockRoute()
        fault.path = "/disconnect"
        fault.fault = .disconnect
        let server = MockServer()
        let base = try await server.start(routes: [first, second, fault])
        do {
            let began = ContinuousClock.now
            let one = try await call(base)
            XCTAssertEqual(one.text, "first")
            XCTAssertGreaterThanOrEqual(began.duration(to: .now), .milliseconds(25))
            let two = try await call(base)
            XCTAssertEqual(two.text, "second")
            await server.resetScenarios()
            let reset = await server.requestCount()
            XCTAssertEqual(reset, 0)
            let again = try await call(base)
            XCTAssertEqual(again.text, "first")
            do {
                _ = try await call(base, path: "/disconnect")
                XCTFail("Expected disconnect")
            } catch {}
            let records = await server.journal()
            XCTAssertNil(records.last?.responseStatus)
        } catch {
            await server.stop()
            throw error
        }
        await server.stop()
    }
    func testPercentEncodingAndSafeExampleQuoting() throws {
        XCTAssertTrue(MockMatching.pathMatches("/a%2Fb", "/a%2Fb"))
        XCTAssertFalse(MockMatching.pathMatches("/a%2Fb", "/a/b"))
        XCTAssertFalse(MockMatching.pathMatches("/%GG", "/%GG"))
        var route = MockRoute()
        route.path = "/a%2Fb/{id}"
        route.expectedBody = "'$(touch /tmp/must-not-run)'"
        let base = URL(string: "http://127.0.0.1:54321")!
        let url = try MockExamples.url(base: base, route: route)
        XCTAssertEqual(url.path(percentEncoded: true), "/a%2Fb/sample")
        let command = try MockExamples.curl(base: base, route: route)
        XCTAssertTrue(command.contains("'\\''$(touch /tmp/must-not-run)'\\''"))
        XCTAssertThrowsError(
            try MockExamples.url(base: URL(string: "http://example.test")!, route: route))
        var invalid = route
        invalid.path = "/%GG"
        XCTAssertThrowsError(try MockServer.validate([invalid]))
        XCTAssertThrowsError(try MockServer.validate([route, route]))
    }
    func testRegistryOwnsMultipleListenersAndStopsRemovedProjects() async throws {
        let sessions = MockSessions()
        var projects: [MockProject] = []
        do {
            for index in 0..<4 {
                let project = MockProject(name: "Mock \(index)", routes: [MockRoute()])
                projects.append(project)
                try await sessions.start(project)
                if index == 0 {
                    let snapshot = await sessions.snapshot(project.id)
                    var collision = MockProject(routes: [MockRoute()])
                    collision.port = UInt16(try XCTUnwrap(snapshot?.baseURL?.port))
                    do {
                        try await sessions.start(collision)
                        XCTFail("Occupied port accepted")
                    } catch {}
                    let failed = await sessions.snapshot(collision.id)
                    XCTAssertNil(
                        failed, "Failed starts must release retained project configuration")
                }
            }
            let fifth = MockProject(routes: [MockRoute()])
            do {
                try await sessions.start(fifth)
                XCTFail("Fifth listener accepted")
            } catch {}
            // A previously failed/stopped entry must not bypass the four-listener bound.
            do {
                try await sessions.start(fifth)
                XCTFail("Fifth listener accepted again")
            } catch {}
            let snapshot = await sessions.snapshot(projects[0].id)
            let base = try XCTUnwrap(snapshot?.baseURL)
            let response = try await call(base)
            XCTAssertEqual(response.status, 200)
            await sessions.retain([projects[0].id])
            let removed = await sessions.snapshot(projects[1].id)
            XCTAssertNil(removed)
            var edited = projects[0]
            edited.routes[0].body = "restarted"
            try await sessions.start(edited)
            let restart = await sessions.snapshot(edited.id)
            let response2 = try await call(XCTUnwrap(restart?.baseURL))
            XCTAssertEqual(response2.text, "restarted")
        } catch {
            await sessions.stopAll()
            throw error
        }
        await sessions.stopAll()
        let snapshot = await sessions.snapshot(projects[0].id)
        XCTAssertNil(snapshot)
    }
    func testJournalEvictionAndResetStayBounded() async throws {
        let server = MockServer()
        let base = try await server.start(routes: [MockRoute()])
        do {
            for _ in 0..<1003 { _ = try await call(base, path: "/?token=private-value") }
            let records = await server.journal()
            let count = await server.requestCount()
            XCTAssertEqual(count, 1003)
            XCTAssertEqual(records.count, 1000)
            XCTAssertTrue(records.allSatisfy { $0.path == "/" })
            await server.clearJournal()
            let cleared = await server.journal()
            XCTAssertTrue(cleared.isEmpty)
        } catch {
            await server.stop()
            throw error
        }
        await server.stop()
    }

    func testStoppedDelayCannotSendIntoRestartedServer() async throws {
        let server = MockServer()
        var delayed = MockRoute()
        delayed.delayMilliseconds = 200
        let base = try await server.start(routes: [delayed])
        let pending = Task { try await self.call(base) }
        for _ in 0..<100 {
            if await server.requestCount() > 0 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        await server.stop()
        let fresh = try await server.start(routes: [MockRoute()])
        do {
            _ = try await pending.value
            XCTFail("Stopped connection received a response")
        } catch {}
        let response = try await call(fresh)
        XCTAssertEqual(response.status, 200)
        try await Task.sleep(for: .milliseconds(230))
        let response2 = try await call(fresh)
        XCTAssertEqual(response2.status, 200)
        await server.stop()
    }
    func testCLIProjectReadinessResetAndTeardown() async throws {
        guard let executable = ProcessInfo.processInfo.environment["RILL_TEST_CLI_PATH"] else {
            throw XCTSkip("Built CLI required")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "rill-mock-cli-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        var first = MockRoute()
        first.body = "first"
        first.scenario = MockScenario(name: "flow", nextState: "done")
        var second = MockRoute()
        second.body = "second"
        second.scenario = MockScenario(name: "flow", requiredState: "done")
        let project = MockProject(routes: [first, second])
        let file = directory.appendingPathComponent("project with spaces.json")
        try MockProjectFile.encode(project).write(to: file)
        let output = directory.appendingPathComponent("out")
        try Data().write(to: output)
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        let input = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["mock-serve", "--project", file.path, "--json", "--control-stdin"]
        process.standardInput = input
        process.standardOutput = handle
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        func lines() throws -> [String] {
            try String(contentsOf: output, encoding: .utf8).split(separator: "\n").map(String.init)
        }
        func waitForLines(_ count: Int) async throws {
            for _ in 0..<200 {
                if try lines().count >= count || !process.isRunning { return }
                try await Task.sleep(for: .milliseconds(25))
            }
            XCTFail("Timed out waiting for mock control output")
        }
        try await waitForLines(1)
        let ready = try XCTUnwrap(try lines().first)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(ready.utf8)) as? [String: Any])
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        XCTAssertEqual(object["routeCount"] as? Int, 2)
        let base = try XCTUnwrap(URL(string: XCTUnwrap(object["baseURL"] as? String)))
        let response = try await call(base)
        XCTAssertEqual(response.text, "first")
        try input.fileHandleForWriting.write(contentsOf: Data("status\nreset\n".utf8))
        try await waitForLines(3)
        XCTAssertTrue(try lines()[1].contains("\"requestCount\":1"))
        XCTAssertTrue(try lines()[2].contains("\"state\":\"reset\""))
        let reset = try await call(base)
        XCTAssertEqual(reset.text, "first")
        try input.fileHandleForWriting.write(contentsOf: Data("stop\n".utf8))
        for _ in 0..<200 {
            if !process.isRunning { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertFalse(process.isRunning)
        if !process.isRunning { XCTAssertEqual(process.terminationStatus, 0) }
        do {
            _ = try await call(base)
            XCTFail("CLI listener survived stop")
        } catch {}
    }

    func testResponseTemplatesRemoveEveryScalarAndCapturedHeadersURL() throws {
        let response = Exchange(
            requestID: UUID(), requestName: "secret request", method: .GET,
            url: "https://private.test/token", status: 200, duration: 0.1,
            headers: [Field(name: "Set-Cookie", value: "private-cookie")],
            body: Data(
                #"{"token":"private-token","nested":[123,true,null],"unrecognised":"also-secret"}"#
                    .utf8), checks: [])
        let route = try MockResponseFixture.route(response)
        XCTAssertEqual(route.path, "/recorded-response")
        XCTAssertEqual(route.origin?.sourceID, response.id)
        XCTAssertFalse(route.body.contains("private-token"))
        XCTAssertFalse(route.body.contains("also-secret"))
        XCTAssertFalse(route.body.contains("123"))
        XCTAssertFalse(route.headers.contains { $0.name == "Set-Cookie" })
        XCTAssertTrue(route.body.contains("[REDACTED]"))
    }
}
