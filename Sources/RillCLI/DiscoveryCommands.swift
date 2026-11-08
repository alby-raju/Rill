import Foundation
import RillCore

extension RillCLI {
    static func help(_ args: Arguments) throws {
        guard args.operands.count <= 1 else { throw CLIError.usage("Use help [COMMAND].") }
        guard let command = args.operands.first else {
            try args.text(usage)
            return
        }
        guard commandNames.contains(command) else {
            throw CLIError.usage("Unknown help command; use --help.")
        }
        let focused: [String: String] = [
            "report-diff":
                "report-diff BEFORE AFTER [--metadata-only] [--ignore-json POINTER] [--ignore-header NAME] [--strict-headers] [--latency-percent N] [--latency-floor MS] [--json|--quiet]\nCompare versioned reports or explicit raw snapshots. Missing payloads are unknown; ordinary reports require --metadata-only. Exit 4 for observed drift, 2 for incomplete/invalid comparison, 0 for complete equality under selected rules. Output never echoes payload/header values.",
            "mock-serve":
                "mock-serve --project FILE|--routes FILE [--port N] [--json] [--control-stdin] [--quiet]\nLoopback-only HTTP. Port 0 chooses an available port. Project version 1 is shared with the desktop. --json emits one compact readiness record. --control-stdin accepts newline-terminated status/reset/stop (64 bytes maximum); EOF stops. Ctrl+C/SIGTERM stops and exits 130. No personal workspace or Keychain access.",
            "doctor":
                "doctor [--workspace FILE] [--json|--quiet]\nChecks local installation and optional explicit workspace without network, Keychain access or mutation. Optional compiler absence is a warning; invalid workspace exits 2.",
            "completion":
                "completion bash|zsh|fish\nPrint static shell completion source. No workspace, network or credential access. Preserve the full CLI installation when adding its bin directory to PATH.",
            "run":
                "run FILE [--format postman|native] [--dry-run]\nPostman: --folder /Parent/Child --globals FILE --environment-file FILE --attachments FILE\nNative: --collection NAME_OR_ID --environment NAME_OR_ID\nBoth: --env-var key=value --iteration-data FILE --cookies --export-environment FILE\n--iterations N --retries N --delay MS --retry-delay MS --continue-on-failure\n--report FILE --report-format json|markdown|junit|html|ndjson --allure DIR --output FILE --overwrite\n--config FILE --seed N [--seed-time EPOCH] --deadline SECONDS --github-annotations\n--comparison-output FILE explicitly saves raw response payloads/headers for report-diff.\n--json|--detail|--quiet; see full help for bounded TLS inputs. Postman file attachments require explicit bindings. Unsupported scripts block before traffic; --translate-scripts opts into the finite native subset. No desktop workspace or Keychain access.",
            "preflight":
                "preflight FILE [--translate-scripts] [--script-inventory] [--folder /Parent/Child] [--globals FILE] [--environment-file FILE] [--env-var key=value] [--json]\nOffline Postman validation; no requests or credential hydration. Does not execute scripts, iteration data or cookie chains.",
            "request":
                "request METHOD URL [--header 'Name: value'] [--data TEXT|--data-file FILE|--binary-file FILE|--form NAME=VALUE|NAME@PATH] [--multipart] [--env-var key=value] [--output FILE|--download FILE] [--json]\nForm fields repeat. File fields use multipart automatically. Use --ca-cert and scoped --ssl-client options for headless TLS. --download streams a successful GET to disk. One explicit HTTP request; no saved workflows, foreign scripts or cookie session. Raw output can contain secrets.",
        ]
        if let text = focused[command] {
            try args.text(
                "rill " + text
                    + "\n\nExit codes: 0 success, 2 invalid input, 3 runtime/transport, 4 failed assertions, 130 cancellation."
            )
        } else {
            try args.text("Command: " + command + "\n\n" + usage)
        }
    }
    static let commandNames = [
        "report-diff", "help", "version", "doctor", "completion", "preflight", "request", "run",
        "init", "list",
        "search", "run-request", "run-collection", "run-folder", "backup", "restore", "diagnostics",
        "collection-import", "openapi-list", "openapi-import", "openapi-refresh", "contract-check",
        "perf", "history-diff", "git-status", "git-init", "git-commit", "plugins", "plugin-enable",
        "plugin-disable", "plugin-template", "oauth-client", "share-serve", "share-pull", "graphql",
        "grpc", "sse", "ws", "mock-serve",
    ]

    static func doctor(_ args: Arguments) throws {
        guard args.operands.isEmpty, Set(args.values.keys).isSubset(of: ["workspace"]),
            args.flags.isSubset(of: ["json", "quiet"])
        else { throw CLIError.usage("Use doctor [--workspace FILE] [--json|--quiet].") }
        struct Check: Encodable {
            let id: String
            let status: String
            let guidance: String
        }
        var checks = [
            Check(id: "platform", status: "passed", guidance: "Native macOS 15+ CLI."),
            Check(
                id: "credentials", status: "notChecked",
                guidance:
                    "No Keychain or process secrets inspected. Supply explicit inputs for file runs."
            ),
        ]
        let compiler = try? ProtobufCompiler.bundledExecutable()
        checks.append(
            Check(
                id: "protobufCompiler", status: compiler == nil ? "warning" : "passed",
                guidance: compiler == nil
                    ? "Bundled protoc unavailable. Keep the complete CLI archive or app installation; HTTP file runs remain available."
                    : "Bundled protoc is executable. No host PATH compiler selected."))
        if args.value("workspace") != nil {
            do {
                _ = try WorkspaceFile.load(from: args.workspaceURL)
                checks.append(
                    Check(
                        id: "workspace", status: "passed",
                        guidance: "Explicit workspace decoded read-only; no credentials loaded."))
            } catch {
                checks.append(
                    Check(
                        id: "workspace", status: "failed",
                        guidance:
                            "Explicit workspace is missing, unreadable or invalid. Check file format/permissions; content and path omitted."
                    ))
            }
        }
        let passed = !checks.contains { $0.status == "failed" }
        if args.flags.contains("json") {
            struct Result: Encodable {
                let schemaVersion = 1
                let version = RillVersion.number
                let passed: Bool
                let checks: [Check]
            }
            try args.json(Result(passed: passed, checks: checks))
        } else {
            try args.text("Rill \(RillVersion.number) · local diagnostics (no network requests)")
            for check in checks {
                try args.text("\(check.id): \(check.status) · \(check.guidance)")
            }
        }
        if !passed { throw CLIError.usage("Doctor found invalid inputs; see the redacted checks.") }
    }

    static func completion(_ args: Arguments) throws {
        guard args.operands.count == 1, args.values.isEmpty, args.flags.isEmpty else {
            throw CLIError.usage(
                "Use completion bash|zsh|fish; redirect stdout to your shell's completion file.")
        }
        let commands = commandNames.joined(separator: " ")
        let options =
            (Arguments.booleanOptions.union(Arguments.valueOptions).sorted().map { "--" + $0 })
            .joined(separator: " ")
        let result: String
        switch args.operands[0] {
        case "bash":
            result = """
                _rill_complete() {
                  local cur="${COMP_WORDS[COMP_CWORD]}" candidate
                  COMPREPLY=()
                  if [[ "$COMP_CWORD" -eq 1 ]]; then
                    while IFS= read -r candidate; do COMPREPLY+=("$candidate"); done < <(compgen -W '\(commands)' -- "$cur")
                  elif [[ "$cur" == --* ]]; then
                    while IFS= read -r candidate; do COMPREPLY+=("$candidate"); done < <(compgen -W '\(options)' -- "$cur")
                  else
                    while IFS= read -r candidate; do COMPREPLY+=("$candidate"); done < <(compgen -f -- "$cur")
                  fi
                }
                complete -F _rill_complete -o filenames rill
                """
        case "zsh":
            let arguments =
                Arguments.booleanOptions.sorted().map { "'--\($0)'" }
                + Arguments.valueOptions.sorted().map { "'--\($0):value:_files'" }
            result = """
                #compdef rill
                _arguments \\
                  '1:command:(\(commands))' \\
                  \(arguments.joined(separator: " \\\n  ")) \\
                  '*:file:_files'
                """
        case "fish":
            var lines = [
                "complete -c rill -f",
                "complete -c rill -n '__fish_use_subcommand' -a '\(commands)'",
            ]
            lines += Arguments.booleanOptions.sorted().map { "complete -c rill -l \($0)" }
            lines += Arguments.valueOptions.sorted().map { "complete -c rill -l \($0) -r -F" }
            result = lines.joined(separator: "\n")
        default: throw CLIError.usage("Completion shell must be bash, zsh or fish.")
        }
        try args.text(result)
    }
}
