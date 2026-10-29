import Foundation
import RillCore

extension RillCLI {
    static func workspaceCommand(_ args: Arguments) async throws {
        let commands: Set<String> = [
            "list", "search", "run-request", "run-collection", "run-folder", "backup", "restore",
            "diagnostics", "collection-import", "openapi-list", "openapi-import", "openapi-refresh",
            "contract-check", "perf", "history-diff", "git-status", "git-init", "git-commit",
            "plugins", "plugin-enable", "plugin-disable", "plugin-template", "oauth-client",
            "share-serve",
        ]
        guard commands.contains(args.command) else {
            throw CLIError.usage("Unknown command; use --help.")
        }
        let session = WorkspaceSession(url: args.workspaceURL)
        let needsCredentials =
            (args.flags.contains("apply")
                && [
                    "restore", "collection-import", "openapi-import", "openapi-refresh",
                    "plugin-template",
                ].contains(args.command))
            || [
                "run-request", "run-collection", "run-folder", "contract-check", "perf",
                "oauth-client",
            ].contains(args.command)
        let workspace: Workspace
        if needsCredentials {
            workspace = try await session.open()
        } else if !FileManager.default.fileExists(atPath: args.workspaceURL.path)
            && ["plugins", "plugin-enable", "plugin-disable", "git-init", "git-status"].contains(
                args.command)
        {
            workspace = Workspace()
        } else {
            guard FileManager.default.fileExists(atPath: args.workspaceURL.path) else {
                throw CLIError.usage("Workspace file is missing; use init or --workspace.")
            }
            workspace = try WorkspaceFile.load(from: args.workspaceURL)
        }
        let environment = try args.environment(workspace)
        let resolver = NamedSecretResolver(catalog: workspace.namedSecrets ?? [])
        switch args.command {
        case "list", "search":
            struct Item: Encodable { let kind: String, id: UUID, name: String }
            let term = args.command == "search" ? try args.operand() : ""
            let requests = workspace.requests.filter {
                term.isEmpty || $0.name.localizedCaseInsensitiveContains(term)
                    || $0.url.localizedCaseInsensitiveContains(term)
            }.map { Item(kind: "request", id: $0.id, name: $0.name) }
            let collections = workspace.collections.filter {
                term.isEmpty || $0.name.localizedCaseInsensitiveContains(term)
            }.map { Item(kind: "collection", id: $0.id, name: $0.name) }
            try args.json(collections + requests)
        case "run-request", "contract-check", "run-collection", "run-folder":
            let requests: [RequestDraft]
            let runTitle: String
            if args.command == "run-request" || args.command == "contract-check" {
                let request = try args.request(args.operand(), in: workspace)
                if args.command == "contract-check", request.apiLink == nil {
                    throw CLIError.usage("Select a contract-linked request.")
                }
                requests = [request]
                runTitle = request.name
            } else {
                let target = try args.operand()
                let matches = workspace.collections.filter {
                    $0.id.uuidString == target || $0.name == target
                }
                guard matches.count == 1 else {
                    throw CLIError.usage("Collection is missing or ambiguous.")
                }
                runTitle = matches[0].name
                requests = try workspace.requests.filter { $0.collectionID == matches[0].id }.map {
                    try args.transport($0, workspace: workspace)
                }
            }
            var config = RunConfiguration()
            config.iterations = try args.integer("iterations", default: 1)
            config.retries = try args.integer("retries", default: 0)
            config.delayMilliseconds = try args.integer("delay", default: 0)
            config.retryDelayMilliseconds = try args.integer("retry-delay", default: 0)
            config.stopOnFailure = !args.flags.contains("continue-on-failure")
            let progressLabels = Dictionary(
                requests.map { ($0.id, RunConsole.label($0.name, limit: 40)) },
                uniquingKeysWith: { first, _ in first })
            let progress: (@Sendable (RunProgress) async -> Void)? =
                args.liveProgress
                ? { @Sendable event in
                    // Append-only status survives scrollback and never mixes ANSI cursor controls with logs.
                    try? FileHandle.standardError.write(
                        contentsOf: Data(
                            ("  Rill · attempt \(event.completed) · \(event.state.rawValue) · \(progressLabels[event.requestID] ?? "Request")\n")
                                .utf8))
                } : nil
            if args.liveProgress {
                try FileHandle.standardError.write(
                    contentsOf: Data("Rill · running requests…\n".utf8))
            }
            let report = try await CollectionRunner.run(
                requests: requests, environment: environment, configuration: config,
                profiles: workspace.authProfiles ?? [], secrets: resolver,
                tlsProfiles: workspace.tlsProfiles ?? [],
                definitions: workspace.apiDefinitions ?? [], progress: progress)
            try await reports(report, arguments: args)
            if let output = args.value("output"), let body = report.outcomes.last?.retainedBody {
                try args.write(body, to: output)
            }
            if args.flags.contains("json") {
                try args.json([
                    "passed": report.passed, "cancelled": report.cancelled,
                    "exhausted": report.exhausted,
                ])
            } else {
                try args.text(
                    RunConsole.render(
                        report, requests: requests, title: runTitle,
                        detail: args.flags.contains("detail"), color: args.color))
            }
            try requireSuccessfulRun(report)
        case "perf":
            let request = try args.request(args.operand(), in: workspace)
            var config = LoadConfiguration()
            config.count = try args.integer("count", default: 10)
            config.concurrency = try args.integer("concurrency", default: 1)
            config.rampMilliseconds = try args.integer("ramp", default: 0)
            let report = try await LoadRunner.run(
                request: request, environment: environment, configuration: config,
                profiles: workspace.authProfiles ?? [], secrets: resolver,
                tlsProfiles: workspace.tlsProfiles ?? [],
                definitions: workspace.apiDefinitions ?? [])
            if args.flags.contains("json") {
                try args.json(report)
            } else {
                try args.text(
                    RunConsole.renderLoad(
                        report, title: request.name, detail: args.flags.contains("detail"),
                        color: args.color))
            }
            if report.cancelled { throw CancellationError() }
            if !report.passed { throw CLIError.assertion }
        case "backup":
            try args.write(
                WorkspaceBackup.encode(workspace: workspace, editor: nil),
                to: args.required("output"))
        case "restore":
            let contents = try WorkspaceBackup.load(from: URL(fileURLWithPath: args.operand()))
            guard args.flags.contains("apply") else {
                try args.text(
                    "Validated backup. --apply restores it and retains a pre-restore backup; auth credentials are not restored."
                )
                return
            }
            let retained = args.workspaceURL.deletingLastPathComponent().appendingPathComponent(
                "pre-restore-" + UUID().uuidString + ".rillbackup")
            _ = try await session.restore(contents, retainingPreviousAt: retained, editor: nil)
            try args.text("Restore committed; previous metadata retained")
        case "diagnostics":
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try args.write(
                encoder.encode(
                    SupportDiagnostics(workspace: workspace, persistence: .saved, lastFailure: nil)),
                to: args.required("output"))
        case "collection-import":
            let url = try URL(fileURLWithPath: args.operand())
            let format = args.value("format") ?? "native"
            if format == "native" {
                let plan = try WorkspaceImportPlan(
                    incoming: WorkspaceFile.load(from: url), current: workspace)
                try args.json([
                    "requests": plan.preview.requests, "collections": plan.preview.collections,
                    "environments": plan.preview.environments,
                ])
                if args.flags.contains("apply") {
                    _ = try await session.applyImport(plan, current: workspace)
                }
            } else {
                let incoming: ForeignWorkspaceImport
                if format == "har" {
                    let entries = try HARImporter.parse(
                        BoundedFileInput.read(url, limit: 32 * 1024 * 1024))
                    var imported = Workspace()
                    imported.requests = entries.map(\.request)
                    incoming = ForeignWorkspaceImport(
                        workspace: imported, warnings: entries.flatMap(\.warnings))
                } else {
                    let selected: ForeignImportFormat
                    switch format {
                    case "postman": selected = .postman
                    case "insomnia": selected = .insomnia
                    case "bruno": selected = .bruno
                    case "httpie": selected = .httpieDesktop
                    default: throw CLIError.usage("Unknown import format.")
                    }
                    incoming = try selected.load(from: url)
                }
                let plan = try ForeignImportPlan(incoming, current: workspace)
                try args.json([
                    "requests": plan.preview.requests, "collections": plan.preview.collections,
                    "secretDescriptors": plan.preview.secretDescriptors,
                ])
                if args.flags.contains("apply") {
                    _ = try await session.applyForeignImport(plan, current: workspace)
                }
            }
        case "openapi-list":
            struct Source: Encodable { let id: UUID, title: String, operations: Int }
            try args.json(
                try (workspace.apiDefinitions ?? []).map {
                    Source(
                        id: $0.id, title: $0.title,
                        operations: try APIDefinitionLoader.parse(
                            $0.snapshot, location: $0.location, sourceID: $0.id
                        ).operations.count)
                })
        case "openapi-import", "openapi-refresh":
            let sourceID: UUID?
            let location: String
            if args.command == "openapi-refresh" {
                guard let id = UUID(uuidString: try args.operand()),
                    let saved = workspace.apiDefinitions?.first(where: { $0.id == id })
                else { throw CLIError.usage("Definition source ID is missing.") }
                sourceID = id
                location = args.value("source") ?? saved.location
            } else {
                sourceID = nil
                location = try args.operand()
            }
            let definition = try await loadDefinition(location)
            let plan = try APIImportPlan(definition, current: workspace, refreshing: sourceID)
            try args.json(
                Dictionary(grouping: plan.changes, by: { $0.state.rawValue }).mapValues(\.count))
            if args.flags.contains("apply") {
                _ = try await session.applyAPIPlan(plan, current: workspace)
            }
        case "history-diff":
            let entries = try await ExchangeHistory(
                url: args.workspaceURL.deletingLastPathComponent().appendingPathComponent(
                    "exchange-history.json")
            ).open()
            guard let first = entries.first(where: { $0.id.uuidString == (try? args.operand()) }),
                let second = entries.first(where: { $0.id.uuidString == (try? args.operand(1)) })
            else { throw CLIError.usage("History entries are missing.") }
            let result = try ResponseComparator.compare(first, second)
            try args.json([
                "differences": result.differences.count, "limited": result.limited ? 1 : 0,
            ])
            if args.flags.contains("show-messages") { try args.text(result.text) }
        case "git-init":
            try await WorkspaceGit.initialize(URL(fileURLWithPath: args.required("repo")))
            try args.text("Workspace repository initialized")
        case "git-status":
            try args.text(await WorkspaceGit.status(URL(fileURLWithPath: args.required("repo"))))
        case "git-commit":
            let directory = try URL(fileURLWithPath: args.required("repo"))
            try WorkspaceGit.export(workspace, to: directory)
            try args.text(await WorkspaceGit.commit(directory, message: args.required("message")))
        case "plugins", "plugin-enable", "plugin-disable", "plugin-template":
            try await pluginCommand(args, workspace: workspace, session: session)
        case "oauth-client":
            var config = OAuthConfiguration()
            config.tokenEndpoint = try args.required("endpoint")
            config.clientID = try args.required("client-id")
            config.clientSecretName = args.value("client-secret-name") ?? ""
            config.scope = args.value("scope") ?? ""
            config.clientAuthentication = config.clientSecretName.isEmpty ? .none : .basic
            let name = try args.required("save-secret")
            try NamedSecretResolver.validateName(name)
            let token = try await OAuthClient.acquire(configuration: config, secrets: resolver)
            var updated = workspace
            let descriptor =
                workspace.namedSecrets?.first(where: { $0.name == name }) ?? NamedSecret(name: name)
            if !(updated.namedSecrets ?? []).contains(where: { $0.id == descriptor.id }) {
                updated.namedSecrets = (updated.namedSecrets ?? []) + [descriptor]
                try await session.save(updated)
            }
            try await NamedSecretVault().set(token.accessToken, for: descriptor)
            try args.text("Token acquired and stored in Keychain; value omitted")
        case "share-serve":
            let path = try args.required("token-file")
            let tokenURL = URL(fileURLWithPath: path)
            let token: String
            if FileManager.default.fileExists(atPath: path) {
                token = try tokenFromFile(path)
            } else {
                token = try WorkspaceSharing.token()
                try WorkspaceFile.writeNew(Data(token.utf8), to: tokenURL)
            }
            let port = try args.integer("port", default: 0)
            guard (0...65535).contains(port) else { throw CLIError.usage("Invalid port.") }
            let server = WorkspaceShareServer()
            let url = try await server.start(
                workspace: workspace, token: token, port: UInt16(port),
                allowLAN: args.flags.contains("allow-lan"))
            try args.text(url.absoluteString)
            if args.flags.contains("allow-lan") {
                try args.text(
                    "Listening on all IPv4 interfaces. HTTP/token traffic is plaintext; labels and URL paths remain visible."
                )
            }
            do { try await waitForCancellation() } catch {
                await server.stop()
                throw error
            }
        default: throw CLIError.usage("Unknown command.")
        }
    }
    static func loadDefinition(_ location: String) async throws -> APIDefinition {
        do {
            if location.hasPrefix("https://") || location.hasPrefix("http://") {
                return try await APIDefinitionLoader.fetch(location)
            }
            let url = URL(fileURLWithPath: location).standardizedFileURL
            return try APIDefinitionLoader.parse(
                BoundedFileInput.read(url, limit: 8 * 1024 * 1024), location: url.path)
        } catch is SchemaError {
            throw CLIError.usage(
                "Invalid or unsupported OpenAPI/Swagger definition. Supply an OpenAPI 3.x or Swagger 2.0 JSON/YAML document within supported limits; source content omitted."
            )
        } catch is ComparisonError {
            throw CLIError.usage(
                "Could not parse an OpenAPI/Swagger JSON document within supported limits; source content omitted."
            )
        } catch is YAMLImportError {
            throw CLIError.usage(
                "Could not parse an OpenAPI/Swagger JSON/YAML document within supported limits; source content omitted."
            )
        }
    }

    static func reports(_ report: RunReport, arguments args: Arguments) async throws {
        var outputs: [String: Data] = [:]
        if let destination = args.value("report") {
            let format: RunReportFormat
            switch args.value("report-format") ?? "json" {
            case "json": format = .json
            case "markdown": format = .markdown
            case "junit": format = .junit
            default: throw CLIError.usage("Unknown report format.")
            }
            guard let data = try RunReportExporter.files(report, format: format).values.first else {
                throw CLIError.runtime
            }
            outputs[destination] = data
        }
        if let directory = args.value("allure") {
            for (name, data) in try RunReportExporter.files(report, format: .allure) {
                outputs[URL(fileURLWithPath: directory).appendingPathComponent(name).path] = data
            }
        }
        let files = outputs
        // A bounded report flush has its own cancellation context so an interrupted run can
        // still write its explicitly requested cancelled outcome without restarting traffic.
        try await Task.detached { for (path, data) in files { try args.write(data, to: path) } }
            .value
    }
    static func tokenFromFile(_ path: String) throws -> String {
        guard
            let value = String(
                data: try BoundedFileInput.read(URL(fileURLWithPath: path), limit: 4096),
                encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
            WorkspaceSharing.validToken(value)
        else { throw CLIError.usage("Invalid token file.") }
        return value
    }
    static func pluginCommand(_ args: Arguments, workspace: Workspace, session: WorkspaceSession)
        async throws
    {
        let trustURL = URL(
            fileURLWithPath: args.value("trust-file")
                ?? args.workspaceURL.deletingLastPathComponent().appendingPathComponent(
                    "plugin-trust.json"
                ).path)
        var trust = try PluginTrust.load(trustURL)
        if args.command == "plugin-disable" {
            guard args.flags.contains("apply") else {
                throw CLIError.usage("Use --apply to revoke this local trust grant.")
            }
            trust.disable(try args.operand())
            try trust.save(trustURL)
            return
        }
        let plugins = try PluginRegistry.discover(
            URL(fileURLWithPath: args.required("plugins-dir")))
        if args.command == "plugins" {
            struct Item: Encodable {
                let id: String, name: String, version: String
                let enabled: Bool
                let services: [PluginService]
            }
            try args.json(
                plugins.map {
                    Item(
                        id: $0.id, name: $0.descriptor.name, version: $0.descriptor.version,
                        enabled: trust.allows($0), services: $0.descriptor.services)
                })
            return
        }
        if args.command == "plugin-enable" {
            guard args.flags.contains("apply"),
                let selected = plugins.first(where: { $0.id == (try? args.operand()) })
            else {
                throw CLIError.usage(
                    "Select a discovered plugin and use --apply after reviewing its files.")
            }
            trust.enable(selected)
            try trust.save(trustURL)
            return
        }
        guard args.flags.contains("apply") else {
            throw CLIError.usage("Use --apply to insert the trusted template.")
        }
        let registry = PluginRegistry(
            plugins: plugins, trust: trust, context: PluginContext(workspace: workspace))
        let request = try registry.request(
            plugin: args.required("plugin"), service: args.required("service"))
        _ = try await session.importRequest(request, current: workspace)
    }
}
