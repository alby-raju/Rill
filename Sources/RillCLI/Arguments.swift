import Darwin
import Foundation
import RillCore

enum CLIError: Error { case usage(String), assertion, runtime }
struct Arguments: Sendable {
    var command = "help", operands: [String] = [], values: [String: [String]] = [:],
        flags: Set<String> = []
    init(_ input: [String]) throws {
        guard input.count <= 512, input.reduce(0, { $0 + $1.utf8.count }) <= 2 * 1024 * 1024 else {
            throw CLIError.usage("Arguments exceed limits.")
        }
        let boolean: Set<String> = [
            "quiet", "detail", "json", "apply", "continue-on-failure", "allow-insecure",
            "allow-lan", "overwrite", "show-messages", "help", "version",
        ]
        let valued: Set<String> = [
            "color", "workspace", "environment", "tls", "iterations", "delay", "retries",
            "retry-delay", "report", "report-format", "allure", "output", "format", "source",
            "endpoint", "query", "query-file", "variables", "header", "metadata", "timeout",
            "proto", "descriptor", "method", "data", "data-file", "count", "concurrency", "ramp",
            "port", "routes", "repo", "message", "token-file", "destination", "client-id",
            "client-secret-name", "scope", "save-secret", "plugins-dir", "trust-file", "plugin",
            "service", "wait", "send", "auth-profile", "proto-include",
            "environment-file", "env-var", "ssl-client-cert", "ssl-client-key",
        ]
        var index = 0
        var foundCommand = false
        while index < input.count {
            let item = ["-H": "--header", "-d": "--data"][input[index]] ?? input[index]
            if item.hasPrefix("--") {
                let name = String(item.dropFirst(2))
                if boolean.contains(name) {
                    guard flags.insert(name).inserted else {
                        throw CLIError.usage("Duplicate flag.")
                    }
                } else if valued.contains(name) {
                    index += 1
                    guard index < input.count, !input[index].hasPrefix("--") else {
                        throw CLIError.usage("Missing option value.")
                    }
                    guard
                        values[name] == nil
                            || ["header", "metadata", "proto-include", "env-var"].contains(name)
                    else { throw CLIError.usage("Duplicate option.") }
                    values[name, default: []].append(input[index])
                } else {
                    throw CLIError.usage("Unknown option; use --help.")
                }
            } else if item.hasPrefix("-") {
                throw CLIError.usage("Use named long options; see --help.")
            } else if !foundCommand {
                command = item
                foundCommand = true
            } else {
                operands.append(item)
            }
            index += 1
        }
        let preflightOnly: Set<String> = [
            "environment-file", "env-var", "ssl-client-cert", "ssl-client-key",
        ]
        let allowedInputs: Set<String> =
            command == "run"
            ? ["env-var", "environment-file"] : command == "request" ? ["env-var"] : []
        let fileOnly = preflightOnly.subtracting(allowedInputs)
        if command != "preflight", !fileOnly.isDisjoint(with: values.keys) {
            throw CLIError.usage(
                "File certificate options require preflight; environment/variable inputs are supported by run, and request also accepts --env-var."
            )
        }
        if let color = value("color"), !["auto", "always", "never"].contains(color) {
            throw CLIError.usage("--color expects auto, always or never.")
        }
        if flags.contains("json") && flags.contains("detail") {
            throw CLIError.usage("Choose --json or --detail.")
        }
        if let format = value("report-format"), !["json", "markdown", "junit"].contains(format) {
            throw CLIError.usage("Unknown report format.")
        }
        if flags.contains("help") { command = "help" }
        if flags.contains("version") { command = "version" }
    }
    func value(_ name: String) -> String? { values[name]?.first }
    func required(_ name: String) throws -> String {
        guard let value = value(name), !value.isEmpty else {
            throw CLIError.usage("Missing required --" + name + ".")
        }
        return value
    }
    func operand(_ index: Int = 0) throws -> String {
        guard operands.indices.contains(index) else {
            throw CLIError.usage("Missing command input; see --help.")
        }
        return operands[index]
    }
    func integer(_ name: String, default fallback: Int) throws -> Int {
        guard let text = value(name) else { return fallback }
        guard let number = Int(text) else { throw CLIError.usage("Expected an integer option.") }
        return number
    }
    func seconds(_ name: String = "timeout", default fallback: Double = 30) throws -> Double {
        guard let text = value(name) else { return fallback }
        guard let number = Double(text), number.isFinite, (0.1...300).contains(number) else {
            throw CLIError.usage("Expected a bounded duration.")
        }
        return number
    }
    func variableOverrides() throws -> [String: String] {
        var overrides: [String: String] = [:]
        for row in values["env-var"] ?? [] {
            guard let split = row.firstIndex(of: "="), split != row.startIndex else {
                throw CLIError.usage(
                    "--env-var expects a nonempty key=value; values are never printed.")
            }
            overrides[String(row[..<split])] = String(row[row.index(after: split)...])
        }
        return overrides
    }
    func fields(_ name: String) throws -> [Field] {
        try (values[name] ?? []).map { row in
            guard let colon = row.firstIndex(of: ":") else {
                throw CLIError.usage("Fields use name:value.")
            }
            return Field(
                name: String(row[..<colon]).trimmingCharacters(in: .whitespaces),
                value: String(row[row.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
        }
    }
    var workspaceURL: URL {
        URL(
            fileURLWithPath: value("workspace")
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
                    "Library/Application Support/Rill/workspace.json"
                ).path)
    }
    var color: Bool {
        if value("color") == "never" { return false }
        if value("color") == "always" { return true }
        let environment = ProcessInfo.processInfo.environment
        return isatty(STDOUT_FILENO) == 1 && environment["NO_COLOR"] == nil
            && environment["TERM"] != "dumb"
    }
    var liveProgress: Bool {
        !quiet && !flags.contains("json") && isatty(STDERR_FILENO) == 1
            && ProcessInfo.processInfo.environment["TERM"] != "dumb"
    }
    var quiet: Bool { flags.contains("quiet") }
    func text(_ value: String) throws {
        if !quiet { try FileHandle.standardOutput.write(contentsOf: Data((value + "\n").utf8)) }
    }
    func json<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        guard data.count <= 32 * 1024 * 1024 else { throw WorkflowError.limit }
        if !quiet { try FileHandle.standardOutput.write(contentsOf: data + Data([10])) }
    }
    func write(_ data: Data, to path: String) throws {
        let destination = URL(fileURLWithPath: path)
        if command == "run" {
            let inputs = (operands + [value("environment-file")].compactMap { $0 })
                .map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() }
            guard !inputs.contains(destination.resolvingSymlinksInPath()) else {
                throw CLIError.usage("Output cannot replace collection/environment inputs.")
            }
        }
        guard destination.resolvingSymlinksInPath() != workspaceURL.resolvingSymlinksInPath() else {
            throw CLIError.usage("Output cannot replace the active workspace.")
        }
        if !flags.contains("overwrite"), FileManager.default.fileExists(atPath: destination.path) {
            throw CLIError.usage("Output exists; choose a new path or --overwrite.")
        }
        if flags.contains("overwrite") {
            try RunReportExporter.write(data, to: destination)
        } else {
            try WorkspaceFile.writeNew(data, to: destination)
        }
    }
    func environment(_ workspace: Workspace) throws -> RillCore.Environment? {
        let selected: UUID?
        if let name = value("environment") {
            let matches = workspace.environments.filter {
                $0.id.uuidString == name || $0.name == name
            }
            guard matches.count == 1 else {
                throw CLIError.usage("Environment is missing or ambiguous.")
            }
            selected = matches[0].id
        } else {
            selected = workspace.selectedEnvironmentID
        }
        return try selected.map { try EnvironmentResolver.resolve($0, in: workspace.environments) }
    }
    func request(_ name: String, in workspace: Workspace) throws -> RequestDraft {
        let matches = workspace.requests.filter { $0.id.uuidString == name || $0.name == name }
        guard matches.count == 1 else { throw CLIError.usage("Request is missing or ambiguous.") }
        return try transport(matches[0], workspace: workspace)
    }
    func transport(_ input: RequestDraft, workspace: Workspace) throws -> RequestDraft {
        var request = input
        if let name = value("tls") {
            let matches = (workspace.tlsProfiles ?? []).filter {
                $0.id.uuidString == name || $0.name == name
            }
            guard matches.count == 1 else {
                throw CLIError.usage("TLS profile is missing or ambiguous.")
            }
            request.tlsProfileID = matches[0].id
        }
        if let id = request.tlsProfileID,
            workspace.tlsProfiles?.first(where: { $0.id == id })?.mode == .insecure,
            !flags.contains("allow-insecure")
        {
            throw CLIError.usage("Insecure TLS requires --allow-insecure on this invocation.")
        }
        if let name = value("auth-profile") {
            let matches = (workspace.authProfiles ?? []).filter {
                $0.id.uuidString == name || $0.name == name
            }
            guard matches.count == 1 else {
                throw CLIError.usage("Auth profile is missing or ambiguous.")
            }
            request.authProfileID = matches[0].id
        }
        return request
    }
    func body() throws -> String {
        if let path = value("data-file") {
            guard
                let text = String(
                    data: try BoundedFileInput.read(URL(fileURLWithPath: path), limit: 1024 * 1024),
                    encoding: .utf8)
            else { throw CLIError.usage("Expected UTF-8 data.") }
            return text
        }
        return value("data") ?? "{}"
    }
}
let usage = """
    Rill \(RillVersion.number) — native API workbench CLI (macOS 15+)

    Usage: rill COMMAND [input] [--workspace PATH] [options]

      preflight FILE               Offline Postman v2 collection inspection; sends no requests
          --environment-file FILE --env-var key=value (repeatable)
          --ssl-client-cert FILE --ssl-client-key FILE (unencrypted PEM key)
          --json                   Structured diagnostics; exit 2 for blocked inputs
      run COLLECTION.json          Run supported Postman v2 inputs without a saved workspace
          --environment-file FILE --env-var key=value (repeatable)
          --iterations N --delay MS --retries N --retry-delay MS --continue-on-failure
          --report FILE --report-format json|markdown|junit --allure DIR
          --json | --detail        Unsupported scripts/inputs block before traffic
      request METHOD URL           Ad-hoc HTTP request; no workspace required
          -H, --header name:value   Repeatable request headers
          -d, --data TEXT           UTF-8 text body; or --data-file FILE (1 MiB)
          --env-var key=value       Temporary overrides (repeatable); --timeout SECONDS
          --output FILE            Explicit raw response export; --overwrite permits replacement
          --json                   Redacted status/timing/byte summary; non-2xx exits 3
          --workspace FILE         Explicit saved --environment/--auth-profile/--tls selection
      init                         Create a new empty workspace (never overwrites)
      list | search TEXT           List saved IDs/names; search metadata
      run-request NAME_OR_ID       Run one saved request through shared workflow engine
      run-collection NAME_OR_ID    Run a collection; run-folder is an alias
      backup --output FILE        Credential-omitting native backup
      restore FILE --apply         Restore with a retained pre-restore backup
      diagnostics --output FILE   Allowlisted support data
      collection-import FILE       Preview native/postman/insomnia/har/bruno/httpie
          --format FORMAT --apply  Apply reviewed import (foreign credentials may use Keychain)
      openapi-list                  List saved definition IDs/operations
      openapi-import FILE_OR_URL    Preview; --apply commits linked requests
      openapi-refresh SOURCE_ID     Refresh saved location; --source overrides it; --apply
      contract-check REQUEST       Send a contract-linked request through shared checks
      graphql --endpoint URL       --query TEXT or --query-file FILE; --variables JSON
      grpc --endpoint URL          --proto FILE or --descriptor FILE; --method service/method
          --data JSON              Sends one message and half-closes every call mode
      sse --endpoint URL           Bounded SSE session
      ws --endpoint URL            --send TEXT --wait SECONDS; bounded WebSocket session
      perf REQUEST                 --count N --concurrency N --ramp MILLISECONDS
      mock-serve --routes FILE      --port N; Ctrl+C stops the listener
      history-diff ID ID            Compare two saved history entries
      git-init | git-status         --repo DIRECTORY (separate from runtime data)
      git-commit --repo DIRECTORY   --message TEXT; exports portable workspace first
      plugins --plugins-dir DIR    List versioned data-only native extensions
      plugin-enable ID              --plugins-dir DIR --trust-file FILE --apply
      plugin-disable ID             --trust-file FILE --apply
      plugin-template              --plugin ID --service ID --plugins-dir DIR --trust-file FILE --apply
      oauth-client                 --endpoint URL --client-id ID --client-secret-name NAME
          --save-secret NAME        Acquire client-credentials token into Keychain; never prints token
      share-serve --token-file FILE [--port N] [--allow-lan]
      share-pull URL --token-file FILE --destination FILE [--allow-lan]

    Run options: --environment NAME_OR_ID --tls NAME_OR_ID --allow-insecure
      --iterations N --delay MS --retries N --retry-delay MS --continue-on-failure
      --detail shows individual attempts/checks; --json retains machine-readable output.
      --color auto|always|never (default auto; respects NO_COLOR).
      --report FILE --report-format json|markdown|junit --allure DIRECTORY
      --output FILE explicitly exports raw response data; it may contain secrets.
    Protocols: --header name:value (repeatable), --metadata name:value (gRPC), --timeout SECONDS
      --proto-include DIRECTORY supplies additional local compiler imports (repeatable).
      --show-messages explicitly prints transient stream messages; default output is counts/status.
    General: --quiet --overwrite --help --version
    Exit codes: 0 success, 2 configuration/input, 3 runtime, 4 checks failed, 130 cancelled.
    Sharing removes bodies, credentials, profiles, values, schemas and executable hooks;
      labels and URL hosts/paths remain visible. LAN HTTP carries the token without encryption.
    Git export retains entered URL/header/body/environment content; review it before commit.
    Plugin API v1 registers data-only request-template/mock-route services; no native/JAR code loading.
    """
