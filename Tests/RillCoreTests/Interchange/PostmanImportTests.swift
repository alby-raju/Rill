import XCTest

@testable import RillCore

@MainActor final class PostmanImportTests: XCTestCase {
    private func collection(_ items: [[String: Any]], extra: [String: Any] = [:]) throws -> Data {
        var root: [String: Any] = [
            "info": [
                "name": "API",
                "schema": "https://schema.getpostman.com/json/collection/v2.1.0/collection.json",
            ], "item": items,
        ]
        root.merge(extra) { _, new in new }
        return try JSONSerialization.data(withJSONObject: root)
    }
    private func item(_ request: [String: Any]) -> [String: Any] {
        ["name": "Example", "request": request]
    }
    private func location() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.appendingPathComponent("workspace.json")
    }
    func testFoldersBOMAuthInheritanceScriptsAndExactQuery() throws {
        let data = try collection(
            [
                [
                    "name": "Folder",
                    "item": [
                        item([
                            "method": "GET",
                            "url": [
                                "raw": "https://example.test/?x=%2f&x=2",
                                "query": [["key": "x", "value": "/"]],
                            ],
                        ])
                    ],
                ]
            ],
            extra: [
                "auth": [
                    "type": "bearer", "bearer": [["key": "token", "value": "PRIVATE_TOKEN"]],
                ], "event": [["listen": "test", "script": ["exec": ["throw Error('never run')"]]]],
            ])
        let result = try PostmanImporter.parse(Data([0xef, 0xbb, 0xbf]) + data)
        XCTAssertEqual(result.workspace.collections.map(\.name), ["API / Folder"])
        XCTAssertEqual(
            result.workspace.requests[0].collectionID, result.workspace.collections[0].id)
        XCTAssertEqual(result.workspace.requests[0].auth, .bearer)
        XCTAssertEqual(result.workspace.requests[0].credential, "PRIVATE_TOKEN")
        XCTAssertEqual(result.workspace.requests[0].url, "https://example.test/?x=%2f&x=2")
        XCTAssertTrue(result.warnings.contains { $0.contains("never executed") })
        XCTAssertFalse(result.warnings.joined().contains("PRIVATE_TOKEN"))
    }
    func testDisabledQueryHeadersAndFormRows() throws {
        let request: [String: Any] = [
            "method": "POST",
            "url": [
                "raw": "https://example.test/?a=1&b=2",
                "query": [
                    ["key": "a", "value": "1"], ["key": "b", "value": "2", "disabled": true],
                ],
            ], "header": [["key": "X-Off", "value": "ignored", "disabled": true]],
            "body": [
                "mode": "urlencoded",
                "urlencoded": [
                    ["key": "x", "value": "a +"], ["key": "x", "value": "2"],
                    ["key": "off", "value": "3", "disabled": true],
                ],
            ],
        ]
        let result = try PostmanImporter.parse(collection([item(request)]))
        let draft = result.workspace.requests[0]
        XCTAssertEqual(draft.parameters.map(\.enabled), [true, false])
        XCTAssertFalse(draft.headers[0].enabled)
        let prepared = try RequestEngine.prepare(draft, environment: nil)
        XCTAssertEqual(prepared.url?.absoluteString, "https://example.test/?a=1")
        XCTAssertEqual(String(data: prepared.httpBody!, encoding: .utf8), "x=a+%2B&x=2")
        XCTAssertNil(prepared.value(forHTTPHeaderField: "X-Off"))
    }
    func testRawMultipartAndFileReferencesNeverReadFiles() throws {
        let requests = [
            item([
                "method": "POST", "url": "{{base}}/api",
                "body": ["mode": "raw", "raw": "{\"a\":1}"],
            ]),
            item([
                "method": "POST", "url": "https://example.test",
                "body": [
                    "mode": "formdata",
                    "formdata": [
                        ["key": "field", "value": "v", "type": "text"],
                        ["key": "upload", "type": "file", "src": "/never/read/private"],
                    ],
                ],
            ]),
            item([
                "method": "PUT", "url": "https://example.test",
                "body": ["mode": "file", "file": ["src": "/never/read/binary"]],
            ]),
        ]
        let result = try PostmanImporter.parse(collection(requests))
        XCTAssertEqual(result.workspace.requests[0].contentType, "text/plain")
        XCTAssertEqual(result.workspace.requests[2].contentType, "application/octet-stream")
        XCTAssertEqual(result.workspace.requests[0].url, "{{base}}/api")
        XCTAssertEqual(result.workspace.requests[0].body, "{\"a\":1}")
        XCTAssertEqual(result.workspace.requests[1].multipartParts?.map(\.kind), [.text, .file])
        XCTAssertEqual(result.workspace.requests[2].binaryFile?.byteCount, 0)
        XCTAssertTrue(result.warnings.contains { $0.contains("File paths were not read") })
    }
    func testUnselectedUploadsAndMultipleFilesPreserveEditableRequests() throws {
        let placeholders: [Any] = [NSNull(), "", []]
        for source in placeholders {
            let data = try collection([
                item([
                    "method": "POST", "url": "https://example.test/upload",
                    "body": [
                        "mode": "formdata",
                        "formdata": [["key": "upload", "type": "file", "src": source]],
                    ],
                ])
            ])
            let imported = try PostmanImporter.parse(data)
            XCTAssertEqual(imported.workspace.requests[0].multipartParts?.count, 1)
            XCTAssertEqual(imported.workspace.requests[0].multipartParts?.first?.kind, .file)
            XCTAssertNil(imported.workspace.requests[0].multipartParts?.first?.file)
            XCTAssertThrowsError(
                try UploadBody.create(imported.workspace.requests[0], environment: nil))
            XCTAssertTrue(imported.warnings.contains { $0.contains("Unselected upload") })
        }
        let data = try collection([
            item([
                "method": "POST", "url": "https://example.test",
                "body": ["mode": "file", "file": ["src": NSNull()]],
            ]),
            item([
                "method": "POST", "url": "https://example.test",
                "body": [
                    "mode": "formdata",
                    "formdata": [
                        [
                            "key": "upload", "type": "file",
                            "src": ["/never/read/one", "/never/read/two"], "disabled": true,
                        ]
                    ],
                ],
            ]),
        ])
        let imported = try PostmanImporter.parse(data)
        XCTAssertEqual(imported.workspace.requests[0].bodyMode, .binary)
        XCTAssertNil(imported.workspace.requests[0].binaryFile)
        XCTAssertThrowsError(
            try UploadBody.create(imported.workspace.requests[0], environment: nil))
        XCTAssertEqual(imported.workspace.requests[1].multipartParts?.count, 2)
        XCTAssertTrue(
            imported.workspace.requests[1].multipartParts?.allSatisfy { !$0.enabled } == true)
        XCTAssertThrowsError(
            try PostmanImporter.parse(
                collection([
                    item([
                        "method": "POST", "url": "https://example.test",
                        "body": ["mode": "file", "file": ["src": 42]],
                    ])
                ])))
    }
    func testMultipartExpansionRetainsPartBoundsAndWrongFormatHint() throws {
        let files = Array(repeating: "/never/read/file", count: 5_001)
        XCTAssertThrowsError(
            try PostmanImporter.parse(
                collection([
                    item([
                        "method": "POST", "url": "https://example.test",
                        "body": [
                            "mode": "formdata",
                            "formdata": [
                                ["key": "first", "type": "file", "src": files],
                                ["key": "second", "type": "file", "src": files],
                            ],
                        ],
                    ])
                ])))
        XCTAssertThrowsError(
            try HTTPieDesktopImporter.parse(
                collection([item(["method": "GET", "url": "https://example.test"])]))
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("Import Postman JSON"))
        }
    }
    func testEnvironmentMarkedSecretsTypedValuesAndDisabledState() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "_postman_variable_scope": "environment", "name": "Dev",
            "values": [
                ["key": "token", "value": "PRIVATE_ENV", "type": "secret"],
                ["key": "count", "value": 7, "enabled": false],
            ],
        ])
        let result = try PostmanImporter.parse(data)
        let environment = result.workspace.environments[0]
        XCTAssertEqual(result.secretValues.values.first, "PRIVATE_ENV")
        XCTAssertTrue(environment.variables[0].value.hasPrefix("{{secret:postman-"))
        XCTAssertFalse(environment.variables[1].enabled)
        XCTAssertEqual(environment.variables[1].value, "7")
        XCTAssertFalse(
            String(decoding: try WorkspaceFile.encode(result.workspace), as: UTF8.self).contains(
                "PRIVATE_ENV"))
    }
    func testUnsupportedOAuthBodiesScopedVariablesAndDuplicateHeadersFail() throws {
        let variants: [[String: Any]] = [
            ["auth": ["type": "oauth2", "oauth2": []]], ["auth": "malformed"],
            ["body": ["mode": "graphql", "graphql": [:]]],
            ["variable": [["key": "local", "value": "x"]]],
            ["header": [["key": "X", "value": "1"], ["key": "x", "value": "2"]]],
            ["body": "malformed"],
        ]
        for variant in variants {
            var request: [String: Any] = ["method": "POST", "url": "https://example.test"]
            request.merge(variant) { _, new in new }
            XCTAssertThrowsError(try PostmanImporter.parse(collection([item(request)])))
        }
        XCTAssertThrowsError(
            try PostmanImporter.parse(Data(repeating: 32, count: ResourceLimits.workspaceBytes + 1))
        )
        XCTAssertThrowsError(
            try PostmanImporter.parse(Data(#"{"_postman_variable_scope":"environment"}"#.utf8)))
    }
    private func incoming() -> ForeignWorkspaceImport {
        var workspace = Workspace.starter
        workspace.requests[0].url = "https://example.test"
        workspace.requests[0].auth = .bearer
        workspace.requests[0].credential = "PRIVATE_REQUEST"
        let secret = NamedSecret(name: "token")
        workspace.namedSecrets = [secret]
        return ForeignWorkspaceImport(
            workspace: workspace, warnings: [], secretValues: [secret.id: "PRIVATE_NAMED"])
    }
    func testForeignApplyStoresFreshCredentialsSeparatelyAndRejectsStalePreview() async throws {
        let url = try location()
        let requests = TestCredentials()
        let named = TestCredentials()
        let session = WorkspaceSession(url: url, credentials: requests, namedCredentials: named)
        let baseline = try await session.open()
        try await session.save(baseline)
        let plan = try ForeignImportPlan(incoming(), current: baseline)
        var edited = baseline
        edited.requests[0].name = "Changed"
        XCTAssertThrowsError(try plan.applying(to: edited))
        let updated = try await session.applyForeignImport(plan, current: baseline)
        XCTAssertEqual(try requests.read(updated.requests.last!.id), "PRIVATE_REQUEST")
        XCTAssertEqual(try named.read(updated.namedSecrets!.last!.id), "PRIVATE_NAMED")
        let disk = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        XCTAssertFalse(disk.contains("PRIVATE_"))
        XCTAssertFalse(plan.preview.warnings.joined().contains("PRIVATE_"))
        let reopened = try await session.open()
        XCTAssertFalse(reopened.needsSave(comparedTo: updated))
    }
    func testSecretNameCollisionRemapsCredentialReferencesAndEnvironmentValues() throws {
        var existing = Workspace.starter
        existing.namedSecrets = [NamedSecret(name: "token")]
        var source = incoming()
        source.workspace.requests[0].credential = "{{secret:token}}"
        var environment = Environment(name: "Dev")
        environment.variables = [Field(name: "token", value: "{{secret:token}}")]
        source.workspace.environments = [environment]
        let plan = try ForeignImportPlan(source, current: existing)
        let merged = try plan.applying(to: existing)
        let name = merged.namedSecrets!.last!.name
        XCTAssertNotEqual(name, "token")
        XCTAssertEqual(merged.requests.last!.credential, "{{secret:" + name + "}}")
        XCTAssertEqual(
            merged.environments.last!.variables[0].value, merged.requests.last!.credential)
    }
    func testSecondStoreFailureRollsBackEarlierWritesAndAllowsRetry() async throws {
        let url = try location()
        let requests = TestCredentials()
        let named = TestCredentials()
        let session = WorkspaceSession(url: url, credentials: requests, namedCredentials: named)
        let baseline = try await session.open()
        try await session.save(baseline)
        let bytes = try Data(contentsOf: url)
        let plan = try ForeignImportPlan(incoming(), current: baseline)
        named.failures(write: true)
        do {
            _ = try await session.applyForeignImport(plan, current: baseline)
            XCTFail("Denied named secret write succeeded")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertEqual(requests.nonemptyCount, 0)
        named.failures()
        _ = try await session.applyForeignImport(plan, current: baseline)
        XCTAssertEqual(requests.nonemptyCount, 1)
        XCTAssertEqual(named.nonemptyCount, 1)
    }
    func testCleanupFailureReportsAnUnreferencedCredentialWithoutCommitting() async throws {
        let url = try location()
        let requests = CleanupDeniedCredentials()
        let named = TestCredentials()
        let session = WorkspaceSession(url: url, credentials: requests, namedCredentials: named)
        let baseline = try await session.open()
        try await session.save(baseline)
        let bytes = try Data(contentsOf: url)
        let plan = try ForeignImportPlan(incoming(), current: baseline)
        named.failures(write: true)
        do {
            _ = try await session.applyForeignImport(plan, current: baseline)
            XCTFail("Failure ignored")
        } catch { XCTAssertEqual(error as? WorkspaceError, .companionRollback) }
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertEqual(requests.backing.nonemptyCount, 1)
    }
    func testFileFailureRollsBackBothStoresAndExternalRevisionPreventsStaging() async throws {
        let url = try location()
        let requests = TestCredentials()
        let named = TestCredentials()
        let session = WorkspaceSession(url: url, credentials: requests, namedCredentials: named)
        let baseline = try await session.open()
        try await session.save(baseline)
        let bytes = try Data(contentsOf: url)
        let plan = try ForeignImportPlan(incoming(), current: baseline)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500], ofItemAtPath: directory.path)
        do {
            _ = try await session.applyForeignImport(plan, current: baseline)
            XCTFail("Read-only destination succeeded")
        } catch {}
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: directory.path)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertEqual(requests.nonemptyCount, 0)
        XCTAssertEqual(named.nonemptyCount, 0)
        let other = WorkspaceSession(url: url, credentials: requests, namedCredentials: named)
        var changed = try await other.open()
        changed.requests[0].name = "Other"
        try await other.save(changed)
        let count = requests.count
        do {
            _ = try await session.applyForeignImport(plan, current: baseline)
            XCTFail("Stale revision succeeded")
        } catch { XCTAssertEqual(error as? WorkspaceError, .conflict) }
        XCTAssertEqual(requests.count, count)
    }
    func testEmptyGETAndHEADRawBodiesImportWithoutDroppingPayloads() throws {
        for method in ["GET", "HEAD"] {
            let source: [String: Any] = [
                "method": method, "url": "https://example.test/resource",
                "body": ["mode": "raw", "raw": ""],
            ]
            let result = try PostmanImporter.parse(collection([item(source)]))
            XCTAssertEqual(result.workspace.requests.first?.bodyMode, RequestBodyMode.none)
            XCTAssertTrue(result.warnings.contains { $0.contains("explicitly empty") })
            for payload in [" ", "nonempty"] {
                var nonempty = source
                nonempty["body"] = ["mode": "raw", "raw": payload]
                XCTAssertThrowsError(try PostmanImporter.parse(collection([item(nonempty)]))) {
                    error in
                    guard case PostmanImportError.unsupportedBody = error else {
                        return XCTFail("Expected collection-specific unsupported body error")
                    }
                }
            }
        }
    }

    func testGroupingOnlyParentsAreSkippedButEmptyLeavesAndMixedParentsRemain() throws {
        let request = item(["method": "GET", "url": "https://example.test"])
        let grouped = try PostmanImporter.parse(
            collection([["name": "Group", "item": [["name": "Leaf", "item": [request]]]]]))
        XCTAssertEqual(grouped.workspace.collections.map(\.name), ["API / Group / Leaf"])
        XCTAssertEqual(
            grouped.workspace.requests.first?.collectionID, grouped.workspace.collections.first?.id)
        let empty = try PostmanImporter.parse(collection([["name": "Empty", "item": []]]))
        XCTAssertEqual(empty.workspace.collections.map(\.name), ["API / Empty"])
        let mixed = try PostmanImporter.parse(
            collection([request, ["name": "Leaf", "item": [request]]]))
        XCTAssertEqual(mixed.workspace.collections.map(\.name), ["API", "API / Leaf"])
        XCTAssertEqual(
            mixed.workspace.requests.map(\.collectionID),
            mixed.workspace.collections.map { Optional($0.id) })
    }

}

private struct CleanupDeniedCredentials: CredentialStore {
    let backing = TestCredentials()
    func read(_ id: UUID) throws -> String { try backing.read(id) }
    func write(_ value: String, id: UUID) throws {
        if value.isEmpty { throw WorkspaceError.unavailable }
        try backing.write(value, id: id)
    }

}
