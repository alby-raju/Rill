import Foundation
import RillCore

extension RillCLI {
    static func runContracts(_ args: Arguments) async throws {
        guard args.operands.count == 1, let sourceID = UUID(uuidString: try args.operand()),
            Set(args.values.keys).isSubset(of: [
                "workspace", "request-id", "environment", "tls", "iterations", "retries", "delay",
                "retry-delay", "report", "report-format", "color",
            ]),
            args.flags.isSubset(of: [
                "quiet", "detail", "json", "continue-on-failure", "allow-insecure", "overwrite",
            ])
        else { throw CLIError.usage("Use contract-run SOURCE_ID [--request-id UUID ...].") }
        try validateContractReport(args)
        var selectedIDs = Set<UUID>()
        for text in args.values["request-id"] ?? [] {
            guard let id = UUID(uuidString: text), selectedIDs.insert(id).inserted else {
                throw CLIError.usage("Each --request-id must be a distinct request UUID.")
            }
        }

        let workspace: Workspace
        do {
            workspace = try WorkspaceFile.decode(
                BoundedFileInput.read(args.workspaceURL, limit: ResourceLimits.workspaceBytes))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CLIError.usage("Could not read the contract workspace. Input content omitted.")
        }
        guard let source = workspace.apiDefinitions?.first(where: { $0.id == sourceID }) else {
            throw CLIError.usage("Definition source ID is missing from the workspace.")
        }
        let selected = workspace.requests.enumerated().filter { _, request in
            request.apiLink?.sourceID == sourceID
                && (selectedIDs.isEmpty || selectedIDs.contains(request.id))
        }
        guard !selected.isEmpty, selectedIDs.isEmpty || selected.count == selectedIDs.count else {
            throw CLIError.usage("Select requests linked to the specified definition.")
        }

        var configuration = try args.savedRunConfiguration()
        configuration.retentionBytes = 0
        do { try configuration.validate() } catch {
            throw CLIError.usage("Run limits are invalid.")
        }
        guard selected.count <= configuration.executionLimit / configuration.iterations else {
            throw CLIError.usage("Requested contract run exceeds the execution limit.")
        }
        let definition = try APIDefinitionLoader.parse(
            source.snapshot, location: source.location, sourceID: sourceID)
        let operations = Set(definition.operations.map(\.key))
        for (_, request) in selected {
            try Task.checkCancellation()
            guard let link = request.apiLink, link.checkContract,
                operations.contains(link.operationKey)
            else {
                throw CLIError.usage(
                    "All selected requests require enabled checks and a current operation link.")
            }
            do {
                for hook in [request.preHook, request.postHook].compactMap({ $0 }) {
                    try HookRuntime.validate(hook, allowControlFlow: false)
                }
            } catch {
                throw CLIError.usage(
                    "Contract batches require valid hooks without next or stop operations.")
            }
        }
        let environment = try args.environment(workspace)
        let credentials = KeychainCredentialStore()
        let requests = try selected.map { _, draft in
            var request = try args.transport(draft, workspace: workspace)
            if request.authProfileID == nil, request.auth != .none {
                request.credential = try credentials.read(request.id)
            }
            return request
        }
        let resolver = NamedSecretResolver(catalog: workspace.namedSecrets ?? [])
        var report = try await CollectionRunner.run(
            requests: requests, environment: environment, configuration: configuration,
            profiles: workspace.authProfiles ?? [], secrets: resolver,
            tlsProfiles: workspace.tlsProfiles ?? [], definitions: [source])
        report.sourceFormat = "native-id-v1"
        report.sources = Dictionary(
            uniqueKeysWithValues: selected.map { index, request in
                (request.id.uuidString, "/requests/\(index)")
            })
        try await reports(report, arguments: args)
        if args.flags.contains("json") {
            struct Summary: Encodable {
                let schemaVersion = 1
                let passed: Bool
                let cancelled: Bool
                let selectedRequests: Int
            }
            try args.json(
                Summary(
                    passed: report.passed, cancelled: report.cancelled,
                    selectedRequests: requests.count))
        } else {
            let labels = requests.map { request in
                var label = RequestDraft()
                label.id = request.id
                label.name = request.id.uuidString
                label.method = request.method
                return label
            }
            try args.text(
                RunConsole.render(
                    report, requests: labels, title: "Saved contract batch",
                    detail: args.flags.contains("detail"), color: args.color))
        }
        try requireSuccessfulRun(report)
    }

    private static func validateContractReport(_ args: Arguments) throws {
        guard args.value("report") != nil else {
            guard args.value("report-format") == nil, !args.flags.contains("overwrite") else {
                throw CLIError.usage("--report-format and --overwrite require --report.")
            }
            return
        }
        let path = try args.required("report")
        let destination = URL(fileURLWithPath: path)
        guard
            !Arguments.aliasesInput(
                destination, among: [args.workspaceURL.resolvingSymlinksInPath()])
        else {
            throw CLIError.usage("Report output cannot replace the contract workspace.")
        }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
            isDirectory.boolValue || !args.flags.contains("overwrite")
        {
            throw CLIError.usage(
                "Choose a new report file or use --overwrite for an existing file.")
        }
    }
}
