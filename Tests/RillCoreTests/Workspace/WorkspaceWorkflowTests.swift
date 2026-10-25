import XCTest

@testable import RillCore

final class WorkspaceWorkflowTests: XCTestCase {
    func testEmptyCollectionRenameAndDeleteHaveStableIdentityAndCascadeOnlyTheirRequests() throws {
        var workspace = Workspace.starter
        let empty = RequestCollection(name: "Empty")
        workspace.collections.append(empty)
        try WorkspaceOperations.renameCollection(empty.id, to: " Renamed ", in: &workspace)
        XCTAssertEqual(workspace.collections.last?.id, empty.id)
        XCTAssertEqual(workspace.collections.last?.name, "Renamed")
        XCTAssertThrowsError(
            try WorkspaceOperations.renameCollection(empty.id, to: "  ", in: &workspace))
        let removed = try WorkspaceOperations.deleteCollection(empty.id, in: &workspace)
        XCTAssertTrue(removed.isEmpty)
        XCTAssertEqual(workspace.requests.count, 1)
        let owned = workspace.collections[0].id
        XCTAssertEqual(try WorkspaceOperations.deleteCollection(owned, in: &workspace).count, 1)
        XCTAssertTrue(workspace.requests.isEmpty)
    }
    func testReorderingPreservesHiddenSiblingsAndOtherCollections() throws {
        var workspace = Workspace.starter
        let group = workspace.collections[0].id
        let other = RequestCollection(name: "Other")
        workspace.collections.append(other)
        var a = RequestDraft(collectionID: group)
        a.name = "A"
        var hidden = RequestDraft(collectionID: group)
        hidden.name = "Hidden"
        var b = RequestDraft(collectionID: group)
        b.name = "B"
        var unrelated = RequestDraft(collectionID: other.id)
        unrelated.name = "Other"
        workspace.requests = [a, hidden, unrelated, b]
        try WorkspaceOperations.move(b.id, before: a.id, in: &workspace)
        XCTAssertEqual(
            workspace.requests.filter { $0.collectionID == group }.map(\.name),
            ["B", "A", "Hidden"])
        XCTAssertEqual(
            workspace.requests.filter { $0.collectionID == other.id }.map(\.id), [unrelated.id])
        XCTAssertThrowsError(
            try WorkspaceOperations.move(a.id, before: unrelated.id, in: &workspace))
        try WorkspaceOperations.move(b.id, offset: 1, in: &workspace)
        XCTAssertEqual(
            workspace.requests.filter { $0.collectionID == group }.map(\.name),
            ["A", "B", "Hidden"])
    }
    func testDuplicatePreservesAllCurrentFieldsAndCreatesNewIdentity() throws {
        var workspace = Workspace.starter
        workspace.requests[0].method = .PATCH
        workspace.requests[0].body = "payload"
        workspace.requests[0].credential = "secret"
        workspace.requests[0].headers = [Field(name: "X-Test", value: "value")]
        workspace.requests[0].expectedStatus = "204"
        let original = workspace.requests[0]
        let duplicate = try WorkspaceOperations.duplicate(original.id, in: &workspace)
        XCTAssertNotEqual(duplicate.id, original.id)
        var comparison = duplicate
        comparison.id = original.id
        comparison.name = original.name
        XCTAssertEqual(comparison, original)
    }
    func testInheritanceOverridesAndDeletingParentPreservesLocalValues() throws {
        var root = Environment(name: "Base")
        root.variables = [Field(name: "host", value: "base"), Field(name: "version", value: "v1")]
        var child = Environment(name: "Local")
        child.parentID = root.id
        child.variables = [Field(name: "host", value: "local")]
        var workspace = Workspace()
        workspace.environments = [root, child]
        let result = try EnvironmentResolver.resolve(child.id, in: workspace.environments)
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: result.variables.map { ($0.name, $0.value) }),
            ["host": "local", "version": "v1"])
        XCTAssertFalse(
            EnvironmentResolver.canSetParent(child.id, for: root.id, in: workspace.environments))
        WorkspaceOperations.deleteEnvironment(root.id, in: &workspace)
        XCTAssertNil(workspace.environments[0].parentID)
        XCTAssertEqual(workspace.environments[0].variables, child.variables)
    }
    func testMissingParentsAndCyclesCannotBeSavedOrImported() throws {
        var a = Environment(name: "A")
        var b = Environment(name: "B")
        a.parentID = b.id
        b.parentID = a.id
        var workspace = Workspace()
        workspace.environments = [a, b]
        XCTAssertThrowsError(try WorkspaceFile.validate(workspace))
        workspace.environments = [a]
        XCTAssertThrowsError(try WorkspaceImport.merging(workspace, into: .starter))
    }
    func testImportRemapsBothEndsOfEnvironmentInheritance() throws {
        var incoming = Workspace()
        let parent = Environment(name: "Base")
        var child = Environment(name: "Child")
        child.parentID = parent.id
        incoming.environments = [parent, child]
        let merged = try WorkspaceImport.merging(incoming, into: Workspace())
        XCTAssertNotEqual(merged.environments[0].id, parent.id)
        XCTAssertEqual(merged.environments[1].parentID, merged.environments[0].id)
    }
    func testNestedVariablesAcrossEveryRequestLayerAndCyclesFailBeforeSend() throws {
        var environment = Environment(name: "Local")
        environment.variables = [
            Field(name: "host", value: "example.invalid"),
            Field(name: "base", value: "https://{{host}}"),
            Field(name: "token", value: "{{value}}"), Field(name: "value", value: "secret"),
        ]
        var request = RequestDraft()
        request.method = .POST
        request.url = "{{base}}/test"
        request.auth = .bearer
        request.credential = "{{token}}"
        request.body = "{{token}}"
        request.parameters = [Field(name: "q", value: "{{token}}")]
        request.headers = [Field(name: "X-Test", value: "{{token}}")]
        let prepared = try RequestEngine.prepare(request, environment: environment)
        XCTAssertEqual(prepared.url?.host, "example.invalid")
        XCTAssertEqual(prepared.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        XCTAssertEqual(prepared.value(forHTTPHeaderField: "X-Test"), "secret")
        XCTAssertEqual(prepared.httpBody, Data("secret".utf8))
        XCTAssertThrowsError(
            try RequestEngine.resolve("{{a}}", variables: ["a": "{{b}}", "b": "{{a}} "]))
        XCTAssertEqual(
            try RequestEngine.resolve("ordinary { braces }", variables: [:]), "ordinary { braces }")
    }
    func testVariableExpansionBudgetRejectsExponentialGrowth() throws {
        var variables = ["v0": "x"]
        for index in 1...25 { variables["v\(index)"] = "{{v\(index - 1)}}{{v\(index - 1)}}" }
        XCTAssertThrowsError(try RequestEngine.resolve("{{v25}}", variables: variables))
    }
    func testTemplatesHaveFreshIDsAndGlobalSearchIncludesAllKinds() throws {
        let a = RequestTemplate.json.make(in: nil)
        let b = RequestTemplate.json.make(in: nil)
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertEqual(a.method, .POST)
        var workspace = Workspace.starter
        workspace.environments = [Environment(name: "Local")]
        workspace.history = [
            Exchange(
                requestID: workspace.requests[0].id, requestName: "Activity", method: .GET,
                url: "http://localhost", status: 200, duration: 1, headers: [], body: Data(),
                checks: [])
        ]
        XCTAssertEqual(
            Set(WorkspaceSearch.results("", in: workspace).map(\.kind)),
            Set([.request, .collection, .environment, .history]))
        XCTAssertEqual(WorkspaceSearch.results("activity", in: workspace).first?.kind, .history)
    }
    func testLosslessJSONFormattingPreservesDuplicateKeysNumbersAndEscapes() throws {
        let input = #"{"x":1e+02,"x":-0.00,"s":"\u0061","empty":[],"object":{}}"#
        let pretty = try JSONTextFormatter.pretty(input)
        XCTAssertTrue(pretty.contains("1e+02"))
        XCTAssertTrue(pretty.contains("-0.00"))
        XCTAssertTrue(pretty.contains(#""\u0061""#))
        XCTAssertEqual(pretty.components(separatedBy: #""x""#).count, 3)
        XCTAssertEqual(try JSONTextFormatter.pretty(pretty), pretty)
        XCTAssertThrowsError(try JSONTextFormatter.pretty("{broken}"))
    }
    func testLargeJSONAndScalarFormatting() throws {
        let literal = String(repeating: "a", count: 100000)
        let formatted = try JSONTextFormatter.pretty("{\"value\":\"\(literal)\"}")
        XCTAssertTrue(formatted.contains(literal))
        XCTAssertEqual(try JSONTextFormatter.pretty("  null  "), "null")
    }
    func testInputSuggestionsLearnSavedNamesAndKeepSupportedTypesSeparate() {
        var workspace = Workspace.starter
        workspace.requests[0].parameters = [Field(name: "customerId", value: "1")]
        XCTAssertTrue(
            InputSuggestions.keys(prefix: "auth", headers: true, workspace: workspace).contains(
                "Authorization"))
        XCTAssertEqual(
            InputSuggestions.keys(prefix: "cust", headers: false, workspace: workspace),
            ["customerId"])
    }
}
