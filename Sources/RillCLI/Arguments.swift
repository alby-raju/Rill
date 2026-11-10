import Darwin
import Foundation
import RillCore

enum CLIError: Error { case usage(String), assertion, runtime }
struct Arguments: Sendable {
    var command = "help", operands: [String] = [], values: [String: [String]] = [:],
        flags: Set<String> = []
    var referencedRunInputs: [URL] = []
    static let booleanOptions: Set<String> = [
        "quiet", "detail", "json", "apply", "continue-on-failure", "allow-insecure",
        "allow-lan", "overwrite", "show-messages", "help", "version", "insecure",
        "fail-fast", "metadata-only", "strict-headers", "github-annotations", "control-stdin",
        "include-system-roots", "cookies", "script-inventory", "translate-scripts", "dry-run",
        "multipart",
    ]
    static let valueOptions: Set<String> = [
        "color", "workspace", "environment", "tls", "iterations", "delay", "retries",
        "retry-delay", "report", "report-format", "allure", "output", "format", "source",
        "endpoint", "query", "query-file", "variables", "header", "metadata", "timeout",
        "proto", "descriptor", "method", "data", "data-file", "count", "concurrency", "ramp",
        "config", "seed", "seed-time", "deadline", "comparison-output", "ignore-json",
        "ignore-header",
        "latency-percent", "latency-floor", "port", "routes", "project", "repo", "message",
        "token-file", "destination", "client-id",
        "client-secret-name", "scope", "save-secret", "plugins-dir", "trust-file", "plugin",
        "service", "wait", "send", "auth-profile", "proto-include", "collection",
        "environment-file", "env-var", "ssl-client-cert", "ssl-client-key", "folder",
        "iteration-data", "iteration-data-format", "globals", "export-environment",
        "ca-cert", "ssl-client-p12", "ssl-passphrase-file", "ssl-client-origin", "ssl-client-map",
        "binary-file", "form", "download", "attachments", "session", "session-key-file",
        "request-id",
    ]
    init(_ input: [String]) throws {
        guard input.count <= 512, input.reduce(0, { $0 + $1.utf8.count }) <= 2 * 1024 * 1024 else {
            throw CLIError.usage("Arguments exceed limits.")
        }
        let boolean = Self.booleanOptions
        let valued = Self.valueOptions
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
                            || [
                                "header", "metadata", "proto-include", "env-var", "ignore-json",
                                "ignore-header", "form", "request-id",
                            ].contains(name)
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
        try applyRunConfig()
        if command != "run",
            !Set(["config", "seed", "seed-time", "deadline", "comparison-output"]).isDisjoint(
                with: values.keys)
                || !Set(["github-annotations", "fail-fast"]).isDisjoint(with: flags)
        {
            throw CLIError.usage(
                "Run configuration, seed, deadline, snapshot and annotation options require a file run."
            )
        }
        if command != "report-diff",
            !Set(["ignore-json", "ignore-header", "latency-percent", "latency-floor"]).isDisjoint(
                with: values.keys)
                || !Set(["metadata-only", "strict-headers"]).isDisjoint(with: flags)
        {
            throw CLIError.usage("Comparison rules require report-diff.")
        }
        let preflightOnly: Set<String> = [
            "environment-file", "env-var", "ssl-client-cert", "ssl-client-key", "folder", "globals",
        ]
        let allowedInputs: Set<String> =
            command == "run"
            ? [
                "env-var", "environment-file", "folder", "ssl-client-cert", "ssl-client-key",
                "globals",
            ]
            : command == "request" ? ["env-var", "ssl-client-cert", "ssl-client-key"] : []
        let fileOnly = preflightOnly.subtracting(allowedInputs)
        if command != "preflight", !fileOnly.isDisjoint(with: values.keys) {
            throw CLIError.usage(
                "PEM certificate/key options require run, request or preflight; folder/environment/variable inputs are supported by run and preflight, and request also accepts --env-var."
            )
        }
        if value("collection") != nil && command != "run" {
            throw CLIError.usage("--collection is supported only by native file runs.")
        }
        if value("request-id") != nil && command != "contract-run" {
            throw CLIError.usage("--request-id requires contract-run.")
        }
        if !["run", "request"].contains(command),
            !FileTLSOptions.values.subtracting(["ssl-client-cert", "ssl-client-key"]).isDisjoint(
                with: values.keys)
                || !FileTLSOptions.flags.isDisjoint(with: flags)
        {
            throw CLIError.usage(
                "TLS file execution options require run or request; preflight supports only PEM pair inspection."
            )
        }
        if command != "run", value("iteration-data") != nil || value("iteration-data-format") != nil
        {
            throw CLIError.usage("Iteration-data options are supported only by file runs.")
        }
        if !["run", "preflight"].contains(command), flags.contains("translate-scripts") {
            throw CLIError.usage(
                "--translate-scripts requires a Postman file run or offline preflight.")
        }
        if command != "preflight", flags.contains("script-inventory") {
            throw CLIError.usage(
                "--script-inventory is supported only by offline Postman preflight.")
        }
        if command != "request",
            flags.contains("multipart")
                || !Set(["binary-file", "form", "download"]).isDisjoint(with: values.keys)
        {
            throw CLIError.usage("Upload and download options require request.")
        }
        if command != "request", value("session") != nil || value("session-key-file") != nil {
            throw CLIError.usage("Persistent cookie sessions require request.")
        }
        if command != "run", value("attachments") != nil {
            throw CLIError.usage("--attachments requires a Postman file run.")
        }
        if command != "run", flags.contains("dry-run") {
            throw CLIError.usage("--dry-run is supported only by file runs.")
        }
        if command != "run", flags.contains("cookies") {
            throw CLIError.usage("--cookies is supported only by file runs.")
        }
        if command != "run", value("export-environment") != nil {
            throw CLIError.usage("--export-environment is supported only by file runs.")
        }
        if let color = value("color"), !["auto", "always", "never"].contains(color) {
            throw CLIError.usage("--color expects auto, always or never.")
        }
        if flags.contains("json") && flags.contains("detail") {
            throw CLIError.usage("Choose --json or --detail.")
        }
        if let format = value("report-format"),
            !["json", "markdown", "junit", "html", "ndjson"].contains(format)
        {
            throw CLIError.usage("Unknown report format.")
        }
        if flags.contains("help") {
            operands = command == "help" ? operands : [command]
            command = "help"
        }
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
    func savedRunConfiguration() throws -> RunConfiguration {
        var configuration = RunConfiguration()
        configuration.iterations = try integer("iterations", default: 1)
        configuration.retries = try integer("retries", default: 0)
        configuration.delayMilliseconds = try integer("delay", default: 0)
        configuration.retryDelayMilliseconds = try integer("retry-delay", default: 0)
        configuration.stopOnFailure = !flags.contains("continue-on-failure")
        return configuration
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
            guard !protectsFileRunInput(destination) else {
                throw CLIError.usage(
                    "Output cannot replace run inputs, including data and TLS files.")
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

      doctor [--workspace FILE] [--json]  Read-only local installation/input diagnostics
      completion bash|zsh|fish           Print shell completion source
      help COMMAND                      Show focused command help

      preflight FILE               Offline Postman v2 collection inspection; sends no requests
          --folder /Parent/Child   Exact folder names; escape ~ as ~0 and / as ~1
          --translate-scripts      Validate the finite native script subset; never evaluate JavaScript
          --script-inventory       Redacted source locations, inheritance counts and lexical API hints
          --globals FILE           Postman globals JSON; lower precedence than collection variables
          --environment-file FILE --env-var key=value (repeatable)
          --ssl-client-cert FILE --ssl-client-key FILE (unencrypted PEM key)
          --json                   Structured diagnostics; exit 2 for blocked inputs
      run COLLECTION.json          Run Postman v2 (default) or native inputs without desktop setup
          --folder /Parent/Child   Selected subtree; inherited scripts/settings still checked
          --format native          Read a native Rill workspace file without opening Keychain
          --collection NAME_OR_ID --environment NAME_OR_ID   Native selection
          --allow-insecure         Native insecure profiles require explicit opt-in
          --attachments FILE       Bind Postman upload slots to explicit local files
          --dry-run                Print a redacted plan without sending or writing outputs
          --ca-cert FILE           DER/PEM roots for this run; --include-system-roots adds system trust
          --ssl-client-cert FILE --ssl-client-key FILE   PEM identity (encrypted PKCS#8 or clear)
          --ssl-client-p12 FILE   Memory-only PKCS#12 identity
          --ssl-passphrase-file FILE   Required for encrypted PEM, optional for PKCS#12
          --ssl-client-origin https://HOST:PORT   Required exact origin for a single client identity
          --ssl-client-map FILE    Versioned JSON map for up to 16 exact HTTPS origins
          --insecure               Explicitly disable server certificate/hostname verification
          --globals FILE           Postman globals JSON; lowest variable precedence
          --environment-file FILE --env-var key=value (repeatable)
          --iteration-data FILE    JSON/CSV rows; sets iteration count (cannot use --iterations)
          --iteration-data-format json|csv   Optional override for the file extension
          --iterations N --delay MS --retries N --retry-delay MS --continue-on-failure
          --report FILE --report-format json|markdown|junit|html|ndjson --allure DIR
          --config FILE            Versioned option defaults; CLI options take precedence
          --seed UINT64 --seed-time EPOCH   Run-scoped deterministic templates (SplitMix64-v1)
          --deadline SECONDS       Total execution deadline (0.01–86400), including pacing
          --comparison-output FILE Explicit raw body/header snapshot; may contain credentials
          --github-annotations     Redacted final failure annotations on stderr
          --translate-scripts      Opt-in finite script translation (Postman only)
          --cookies                Private in-memory cookie jar for this run only
          --export-environment FILE  Explicit raw final variables (Postman environment JSON)
          --output FILE --timeout SECONDS   Explicit last-response export and request timeout
          --json | --detail        Unsupported scripts/inputs block before traffic
      report-diff BEFORE AFTER     Compare versioned reports/raw snapshots; --metadata-only
          --ignore-json POINTER --ignore-header NAME (repeatable) --strict-headers
          --latency-percent N --latency-floor MS --json; unknown data cannot prove equality
      request METHOD URL           Ad-hoc HTTP request; no workspace required
          -H, --header name:value   Repeatable request headers
          -d, --data TEXT           UTF-8 text body; or --data-file FILE (1 MiB)
          --binary-file FILE       Stream an explicit binary body
          --form NAME=VALUE|NAME@PATH   Repeatable form fields; --multipart forces multipart
          --ca-cert FILE           Explicit trust roots; scoped client TLS flags also apply
          --env-var key=value       Temporary overrides (repeatable); --timeout SECONDS
          --output FILE            Explicit raw response export; --overwrite permits replacement
          --session FILE --session-key-file FILE   Encrypted cookies for one HTTP origin
          --download FILE          Stream a successful GET to disk (256 MiB)
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
      contract-run SOURCE_ID       Run a saved definition's contracts [--request-id UUID ...]
      graphql --endpoint URL       --query TEXT or --query-file FILE; --variables JSON
      grpc --endpoint URL          --proto FILE or --descriptor FILE; --method service/method
          --data JSON              Sends one message and half-closes every call mode
      sse --endpoint URL           Bounded SSE session
      ws --endpoint URL            --send TEXT --wait SECONDS; bounded WebSocket session
      perf REQUEST                 --count N --concurrency N --ramp MILLISECONDS
      mock-serve --project FILE     Or --routes FILE; --port N --json --control-stdin
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
      --report FILE --report-format json|markdown|junit|html|ndjson --allure DIRECTORY
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
