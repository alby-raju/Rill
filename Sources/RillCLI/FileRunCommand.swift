import Foundation
import RillCore

extension RillCLI {
    static func runFile(_ args: Arguments) async throws {
        guard args.operands.count == 1,
            Set(args.values.keys).isSubset(of: [
                "environment-file", "env-var", "iterations", "delay", "retries", "retry-delay",
                "report", "report-format", "allure", "output", "timeout", "color", "folder",
                "format", "collection", "environment",
            ]),
            args.flags.isSubset(of: [
                "json", "quiet", "detail", "continue-on-failure", "overwrite", "allow-insecure",
            ]
            ),
            args.value("report-format") == nil || args.value("report") != nil
        else {
            throw CLIError.usage(
                "Use run FILE with --format postman|native, supported selection/environment options, pacing/retry and reports. Saved workspace, TLS-file and iteration-data options are not supported."
            )
        }
        let format = args.value("format") ?? "postman"
        guard ["postman", "native"].contains(format),
            format != "postman"
                || (args.value("collection") == nil && args.value("environment") == nil
                    && !args.flags.contains("allow-insecure")),
            format != "native"
                || (args.value("folder") == nil && args.value("environment-file") == nil)
        else {
            throw CLIError.usage(
                "Postman runs use --folder/--environment-file; native runs use --collection/--environment and optional --allow-insecure. Choose --format postman|native explicitly; no requests sent."
            )
        }
        var config = RunConfiguration()
        config.iterations = try args.integer("iterations", default: 1)
        config.retries = try args.integer("retries", default: 0)
        config.delayMilliseconds = try args.integer("delay", default: 0)
        config.retryDelayMilliseconds = try args.integer("retry-delay", default: 0)
        config.stopOnFailure = !args.flags.contains("continue-on-failure")
        do { try config.validate() } catch { throw CLIError.usage("Run limits are invalid.") }
        let timeout = try args.seconds()
        guard timeout >= 1 else {
            throw CLIError.usage("--timeout must be between 1 and 300 seconds.")
        }
        guard
            !args.flags.contains("overwrite") || args.value("report") != nil
                || args.value("output") != nil || args.value("allure") != nil
        else {
            throw CLIError.usage("--overwrite requires a report/output destination.")
        }
        let destinations = [args.value("report"), args.value("output")].compactMap { $0 }
        let normalized = destinations.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() }
        let inputs = ([args.operands[0]] + [args.value("environment-file")].compactMap { $0 })
            .map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() }
        guard Set(normalized).count == normalized.count, Set(normalized).isDisjoint(with: inputs),
            !normalized.contains(args.workspaceURL.resolvingSymlinksInPath())
        else {
            throw CLIError.usage(
                "Outputs must be distinct and cannot replace collection/environment inputs or the desktop workspace."
            )
        }
        for destination in destinations
        where FileManager.default.fileExists(atPath: destination)
            && !args.flags.contains("overwrite")
        {
            throw CLIError.usage("Output exists; choose a new path or --overwrite.")
        }
        if let directory = args.value("allure") {
            var isDirectory: ObjCBool = false
            guard !inputs.contains(URL(fileURLWithPath: directory).resolvingSymlinksInPath()),
                URL(fileURLWithPath: directory).resolvingSymlinksInPath()
                    != args.workspaceURL.resolvingSymlinksInPath(),
                !FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory)
                    || isDirectory.boolValue
            else {
                throw CLIError.usage("Allure output must be a directory distinct from input files.")
            }
        }
        let plan: FileRunPlan
        do {
            let data = try BoundedFileInput.read(
                URL(fileURLWithPath: args.operands[0]), limit: ResourceLimits.workspaceBytes)
            if format == "native" {
                plan = .native(
                    try NativeFileRun.prepare(
                        workspace: data, collection: args.value("collection"),
                        environment: args.value("environment"),
                        overrides: args.variableOverrides(),
                        processEnvironment: ProcessInfo.processInfo.environment,
                        allowInsecure: args.flags.contains("allow-insecure")))
            } else {
                plan = .postman(
                    try PostmanFileRun.prepare(
                        collection: data,
                        environment: try args.value("environment-file").map {
                            try BoundedFileInput.read(
                                URL(fileURLWithPath: $0), limit: ResourceLimits.workspaceBytes)
                        }, overrides: args.variableOverrides(), folder: args.value("folder")))
            }
        } catch let error as NativeFileRunError {
            let reason: String
            switch error {
            case .invalidSelection:
                reason = "Native collection/environment is missing or ambiguous."
            case .emptySelection: reason = "Native selection is empty or exceeds the request limit."
            case .unsupportedScripts:
                reason =
                    "Native file contains foreign script source; only native JSON operations are supported."
            case .unsupportedUpload:
                reason = "Native file runs reject multipart/binary/upload references."
            case .unsupportedIdentity:
                reason = "Native file runs cannot use saved Keychain client identities."
            case .insecureNotAllowed:
                reason = "Native insecure TLS profiles require explicit --allow-insecure."
            }
            throw CLIError.usage(reason + " No requests sent; source content omitted.")
        } catch let error as PostmanFolderSelectionError {
            throw folderSelectionUsage(error)
        } catch PostmanFileRunError.blocked(let preflight) {
            if args.flags.contains("json") {
                struct Blocked: Encodable {
                    let schemaVersion = 1
                    let passed = false
                    let sendsRequests = false
                    let checks: CollectionPreflight
                }
                try args.json(Blocked(checks: preflight))
            } else {
                for issue in preflight.issues.prefix(20) {
                    try args.text(issue.code + " at " + issue.location)
                }
            }
            throw CLIError.usage(
                "Collection file blocked by offline preflight; no requests sent. Resolve unsupported scripts, variables or representations first."
            )
        } catch PostmanFileRunError.unsupportedBody {
            throw CLIError.usage(
                "File runs currently reject multipart and binary/upload bodies; no referenced files opened and no requests sent."
            )
        } catch is CancellationError { throw CancellationError() } catch let error as CLIError {
            throw error
        } catch {
            throw CLIError.usage(
                "Could not prepare bounded collection/environment JSON inputs for the selected format; no requests sent; source content omitted."
            )
        }
        var requests = plan.requests
        if args.value("timeout") != nil {
            for index in requests.indices { requests[index].timeout = timeout }
        }
        guard requests.count * config.iterations <= 10_000 else {
            throw CLIError.usage("Requested run exceeds the execution limit; no requests sent.")
        }
        if !args.flags.contains("json") {
            try args.text(
                "Rill file run · \(format) · \(args.value("folder") != nil ? "selected folder" : args.value("collection") != nil ? "selected collection" : "entire file") · \(requests.count) requests · \(plan.policy)"
            )
        }
        let report = try await plan.run(
            configuration: config, timeout: args.value("timeout") == nil ? nil : timeout)
        try await reports(report, arguments: args)
        if let output = args.value("output") {
            guard let body = report.outcomes.last(where: { $0.status != nil })?.retainedBody else {
                try? FileHandle.standardError.write(
                    contentsOf: Data(
                        "Raw response export unavailable: the last response was not retained. No raw output written.\n"
                            .utf8))
                throw CLIError.runtime
            }
            try args.write(body, to: output)
        }
        if args.flags.contains("json") {
            struct Summary: Encodable {
                let schemaVersion = 1
                let passed: Bool
                let cancelled: Bool
                let exhausted: Bool
                let attempts: Int
                let folderSelected: Bool
                let collectionSelected: Bool
                let inputFormat: String
            }
            try args.json(
                Summary(
                    passed: report.passed, cancelled: report.cancelled, exhausted: report.exhausted,
                    attempts: report.outcomes.filter { $0.state != .notRun }.count,
                    folderSelected: args.value("folder") != nil,
                    collectionSelected: args.value("collection") != nil, inputFormat: format))
        } else {
            try args.text(
                RunConsole.render(
                    report, requests: requests,
                    title:
                        "File run (\(format); \(plan.policy))",
                    detail: args.flags.contains("detail"), color: args.color))
        }
        try requireSuccessfulRun(report)
    }

    static func folderSelectionUsage(_ error: PostmanFolderSelectionError) -> CLIError {
        switch error {
        case .invalidPath:
            .usage(
                "--folder requires an absolute, case-sensitive folder path such as /Parent/Child (escape ~ as ~0 and / as ~1), up to 32 levels and 4096 UTF-8 bytes. No requests sent; path omitted."
            )
        case .missingOrAmbiguous:
            .usage(
                "Folder path is missing, ambiguous or not a folder. Each segment must match exactly one sibling folder. No requests sent; path omitted."
            )
        }
    }

    static func requireSuccessfulRun(_ report: RunReport) throws {
        if report.cancelled || Task.isCancelled { throw CancellationError() }
        if !report.passed {
            let executed = report.outcomes.filter { $0.state != .notRun }
            for (index, outcome) in executed.enumerated() where outcome.state == .failed {
                if index + 1 < executed.count {
                    let next = executed[index + 1]
                    if next.requestID == outcome.requestID
                        && next.iteration == outcome.iteration
                        && next.attempt == outcome.attempt + 1
                    {
                        continue
                    }
                }
                if let failure = outcome.failure {
                    if [
                        "invalidRequest", "invalidConfiguration", "invalidSelector",
                        "invalidBranch",
                    ].contains(failure) {
                        throw CLIError.usage("Invalid request/workflow configuration.")
                    }
                    throw CLIError.runtime
                }
            }
            throw CLIError.assertion
        }
    }
}

private enum FileRunPlan {
    case postman(PostmanFileRun)
    case native(NativeFileRun)
    var requests: [RequestDraft] {
        switch self {
        case .postman(let plan): plan.requests
        case .native(let plan): plan.requests
        }
    }
    var policy: String {
        switch self {
        case .postman: "HTTP 2xx checks; no Postman scripts"
        case .native: "native checks; unchecked responses require HTTP 2xx"
        }
    }
    func run(configuration: RunConfiguration, timeout: Double?) async throws -> RunReport {
        switch self {
        case .postman(let plan): try await plan.run(configuration: configuration, timeout: timeout)
        case .native(let plan): try await plan.run(configuration: configuration, timeout: timeout)
        }
    }
}
