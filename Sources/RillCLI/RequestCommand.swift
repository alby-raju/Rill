import Foundation
import RillCore

extension RillCLI {
    static func request(_ args: Arguments) async throws {
        guard args.operands.count == 2,
            Set(args.values.keys).isSubset(of: [
                "header", "data", "data-file", "env-var", "output", "timeout", "color",
                "workspace", "environment", "auth-profile", "tls",
            ]), args.flags.isSubset(of: ["json", "quiet", "overwrite", "allow-insecure"]),
            let method = HTTPMethod(rawValue: args.operands[0].uppercased()),
            !(args.value("data") != nil && args.value("data-file") != nil)
        else {
            throw CLIError.usage(
                "Use request METHOD URL with --header, --data or --data-file, --env-var, --timeout, --output and --json. Conflicting or unrelated options are rejected."
            )
        }
        guard
            args.value("workspace") != nil
                || ["environment", "auth-profile", "tls"].allSatisfy({ args.value($0) == nil })
        else {
            throw CLIError.usage(
                "Saved environment/auth/TLS selection requires an explicit --workspace.")
        }
        guard !args.flags.contains("allow-insecure") || args.value("tls") != nil else {
            throw CLIError.usage("--allow-insecure requires an explicitly selected --tls profile.")
        }
        guard !args.flags.contains("overwrite") || args.value("output") != nil else {
            throw CLIError.usage("--overwrite requires --output.")
        }
        if let output = args.value("output") {
            let target = URL(fileURLWithPath: output).resolvingSymlinksInPath()
            guard target != args.workspaceURL.resolvingSymlinksInPath(),
                args.value("data-file").map({
                    target != URL(fileURLWithPath: $0).resolvingSymlinksInPath()
                }) ?? true
            else {
                throw CLIError.usage("Output cannot replace the workspace or request body input.")
            }
            guard
                args.flags.contains("overwrite") || !FileManager.default.fileExists(atPath: output)
            else {
                throw CLIError.usage("Output exists; choose a new path or --overwrite.")
            }
        }
        var draft = RequestDraft()
        draft.name = "Ad-hoc request"
        draft.method = method
        draft.url = args.operands[1]
        draft.headers = try args.fields("header")
        draft.timeout = try args.seconds()
        guard draft.timeout >= 1 else {
            throw CLIError.usage("--timeout must be between 1 and 300 seconds.")
        }
        if args.value("data") != nil || args.value("data-file") != nil {
            guard method != .GET && method != .HEAD else {
                throw CLIError.usage("GET/HEAD bodies are not supported; no payload was discarded.")
            }
            draft.bodyMode = .text
            do { draft.body = try args.body() } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw CLIError.usage(
                    "Could not read a bounded UTF-8 body input; source content omitted.")
            }
        } else {
            draft.bodyMode = RequestBodyMode.none
        }
        var overrides: [String: String] = [:]
        for row in args.values["env-var"] ?? [] {
            guard let split = row.firstIndex(of: "="), split != row.startIndex else {
                throw CLIError.usage(
                    "--env-var expects a nonempty key=value; values are never printed.")
            }
            overrides[String(row[..<split])] = String(row[row.index(after: split)...])
        }
        let workspace: Workspace
        if args.value("workspace") != nil {
            // Read explicit saved profiles; never create or persist an ad-hoc request.
            workspace = try WorkspaceFile.load(from: args.workspaceURL)
        } else {
            workspace = Workspace()
        }
        var environment = try args.environment(workspace) ?? Environment(name: "Ad-hoc")
        environment.variables.removeAll { overrides[$0.name] != nil }
        environment.variables += overrides.keys.sorted().map {
            Field(name: $0, value: overrides[$0] ?? "")
        }
        draft = try args.transport(draft, workspace: workspace)
        let exchange: Exchange
        do {
            exchange = try await RequestEngine.execute(
                draft, environment: environment, profiles: workspace.authProfiles ?? [],
                secrets: NamedSecretResolver(catalog: workspace.namedSecrets ?? []),
                tlsProfiles: workspace.tlsProfiles ?? [])
        } catch RillError.responseTooLarge {
            throw CLIError.runtime
        } catch is RillError {
            throw CLIError.usage(
                "Invalid request URL, headers or unresolved variables; input content omitted.")
        } catch WorkflowError.invalidConfiguration {
            throw CLIError.usage(
                "Unsupported or malformed dynamic template; input content omitted.")
        } catch is EditingError {
            throw CLIError.usage(
                "Request variable expansion failed or exceeded its limits; input content omitted.")
        }
        if let output = args.value("output") { try args.write(exchange.body, to: output) }
        struct Summary: Encodable {
            let schemaVersion = 1
            let status: Int
            let duration: Double
            let bodyBytes: Int
        }
        if args.flags.contains("json") {
            try args.json(
                Summary(
                    status: exchange.status, duration: exchange.duration,
                    bodyBytes: exchange.body.count))
        } else {
            try args.text(
                "HTTP \(exchange.status) · \(exchange.body.count) response bytes · \(String(format: "%.3f", exchange.duration)) s"
            )
        }
        if !(200...299).contains(exchange.status) { throw CLIError.runtime }
    }
}
