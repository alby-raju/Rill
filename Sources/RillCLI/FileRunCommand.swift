import Foundation
import RillCore

extension RillCLI {
    static func runFile(_ input: Arguments) async throws {
        let tlsOptions = try FileTLSOptions(input)
        var resolved = input
        if !input.flags.contains("dry-run") {
            resolved.referencedTLSInputs = tlsOptions.referencedInputs
        }
        let args = resolved
        let dryRun = args.flags.contains("dry-run")
        guard args.operands.count == 1,
            Set(args.values.keys).isSubset(of: FileRunOptions.values.union(["config"])),
            args.flags.isSubset(of: FileRunOptions.flags),
            args.value("report-format") == nil || args.value("report") != nil
        else {
            throw CLIError.usage(
                "Use run FILE with --format postman|native, supported selection/environment/data/TLS options, pacing/retry and reports. Saved-workspace options are separate."
            )
        }
        guard args.value("iteration-data-format") == nil || args.value("iteration-data") != nil,
            args.value("iteration-data") == nil || args.value("iterations") == nil
        else {
            throw CLIError.usage(
                "--iteration-data determines the iteration count and cannot be combined with --iterations. --iteration-data-format requires --iteration-data. No requests sent."
            )
        }
        guard
            ["json", "markdown", "junit", "html", "ndjson"].contains(
                args.value("report-format") ?? "json")
        else { throw CLIError.usage("Unknown report format. No requests sent.") }
        let format = args.value("format") ?? "postman"
        guard ["postman", "native"].contains(format),
            format != "postman"
                || (args.value("collection") == nil && args.value("environment") == nil
                    && !args.flags.contains("allow-insecure")),
            format != "native"
                || (args.value("folder") == nil && args.value("environment-file") == nil
                    && args.value("globals") == nil && !args.flags.contains("translate-scripts"))
        else {
            throw CLIError.usage(
                "Postman runs use --folder/--globals/--environment-file; native runs use --collection/--environment and optional --allow-insecure. Choose --format postman|native explicitly; no requests sent."
            )
        }
        var config = RunConfiguration()
        config.iterations = try args.integer("iterations", default: 1)
        config.retries = try args.integer("retries", default: 0)
        config.delayMilliseconds = try args.integer("delay", default: 0)
        config.retryDelayMilliseconds = try args.integer("retry-delay", default: 0)
        guard !args.flags.isSuperset(of: ["fail-fast", "continue-on-failure"]) else {
            throw CLIError.usage("Choose --fail-fast or --continue-on-failure.")
        }
        config.stopOnFailure = !args.flags.contains("continue-on-failure")
        if let value = args.value("seed") {
            guard let seed = UInt64(value) else {
                throw CLIError.usage("--seed requires an unsigned 64-bit integer.")
            }
            config.seed = seed
        }
        if let value = args.value("seed-time") {
            guard let epoch = Int64(value) else {
                throw CLIError.usage("--seed-time requires Unix epoch seconds.")
            }
            config.seedTimestamp = epoch
        }
        if let value = args.value("deadline") {
            guard let seconds = Double(value) else {
                throw CLIError.usage("--deadline requires seconds from 0.01 to 86400.")
            }
            config.totalDeadlineSeconds = seconds
        }
        if args.value("comparison-output") != nil {
            config.retainComparisonHeaders = true
            config.retentionBytes = 8 * 1024 * 1024
        }
        do { try config.validate() } catch { throw CLIError.usage("Run limits are invalid.") }
        let timeout = try args.seconds()
        guard timeout >= 1 else {
            throw CLIError.usage("--timeout must be between 1 and 300 seconds.")
        }
        if !dryRun { try validateFileRunOutputs(args) }
        let iterationData: IterationData?
        do {
            iterationData = try args.value("iteration-data").map { path in
                let name =
                    args.value("iteration-data-format")
                    ?? URL(fileURLWithPath: path).pathExtension.lowercased()
                guard let format = IterationData.Format(rawValue: name) else {
                    throw CLIError.usage(
                        "Iteration data needs a .json/.csv extension or --iteration-data-format json|csv. No requests sent; path omitted."
                    )
                }
                return try IterationData(
                    data: BoundedFileInput.read(
                        URL(fileURLWithPath: path), limit: IterationData.maximumBytes),
                    format: format)
            }
        } catch is CancellationError { throw CancellationError() } catch let error as CLIError {
            throw error
        } catch {
            throw CLIError.usage(
                "Could not read bounded UTF-8 JSON/CSV iteration rows. Check shape, unique variable names, quoting and row/value limits. No requests sent; data content omitted."
            )
        }
        if let iterationData { config.iterations = iterationData.rows.count }
        let planningTLS = dryRun ? try tlsOptions.planningTLS(args) : nil
        let fileTLS = dryRun ? nil : try tlsOptions.load(args)
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
                        processEnvironment: dryRun ? [:] : ProcessInfo.processInfo.environment,
                        allowInsecure: args.flags.contains("allow-insecure"),
                        iterationData: iterationData, fileTLS: fileTLS, planningTLS: planningTLS))
            } else {
                plan = .postman(
                    try PostmanFileRun.prepare(
                        collection: data,
                        environment: try args.value("environment-file").map {
                            try BoundedFileInput.read(
                                URL(fileURLWithPath: $0), limit: ResourceLimits.workspaceBytes)
                        }, overrides: args.variableOverrides(), folder: args.value("folder"),
                        iterationData: iterationData, fileTLS: fileTLS,
                        globals: try args.value("globals").map {
                            try BoundedFileInput.read(
                                URL(fileURLWithPath: $0), limit: ResourceLimits.workspaceBytes)
                        }, translateScripts: args.flags.contains("translate-scripts"),
                        planningOnly: dryRun))
            }
        } catch let error as PostmanScriptPlanError {
            throw CLIError.usage(
                "Bounded script translation blocked: \(error.code) at \(error.location), source line \(error.line), UTF-8 column \(error.byteColumn). No requests sent; source omitted."
            )
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
                reason =
                    "Native file runs cannot look up saved Keychain client identities; supply scoped PEM or PKCS#12 files instead."
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
        if dryRun {
            let output = plan.preview(
                args, format: format, configuration: config,
                tlsInputsDeferred: planningTLS?.identityDeclared == true
                    || args.value("ca-cert") != nil)
            if args.flags.contains("json") {
                try args.json(output)
            } else {
                try args.text(output.terminal(detail: args.flags.contains("detail")))
            }
            return
        }
        if !args.flags.contains("json") {
            if fileTLS?.profile.mode == .insecure {
                try args.text(
                    "TLS: insecure for this run; certificate and hostname verification are disabled."
                )
            }
            try args.text(
                "Rill file run · \(format) · \(args.value("folder") != nil ? "selected folder" : args.value("collection") != nil ? "selected collection" : "entire file") · \(requests.count) requests · \(config.iterations) iterations · \(plan.policy)"
            )
        }
        let environmentExport: CollectionRunner.EnvironmentExport? =
            args.value("export-environment").map { path in
                { @Sendable values in
                    try args.write(try FinalEnvironmentExport.encode(values), to: path)
                }
            }
        let report = try await plan.run(
            configuration: config, timeout: args.value("timeout") == nil ? nil : timeout,
            exportEnvironment: environmentExport,
            cookieJar: args.flags.contains("cookies") ? CookieJar() : nil)
        try await reports(report, arguments: args)
        if let output = args.value("comparison-output") {
            try args.write(try RunSnapshotFile.encode(report), to: output)
        }
        if args.flags.contains("github-annotations") && !args.quiet { try annotations(report) }
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
                let timedOut: Bool
                let attempts: Int
                let folderSelected: Bool
                let collectionSelected: Bool
                let inputFormat: String
                let iterationDataRows: Int?
                let globalsSupplied: Bool
                let tlsPolicy: String?
                let clientIdentityConfigured: Bool?
                let scriptTranslation: Bool?
            }
            try args.json(
                Summary(
                    passed: report.passed, cancelled: report.cancelled, exhausted: report.exhausted,
                    timedOut: report.timedOut ?? false,
                    attempts: report.outcomes.filter { $0.state != .notRun }.count,
                    folderSelected: args.value("folder") != nil,
                    collectionSelected: args.value("collection") != nil, inputFormat: format,
                    iterationDataRows: iterationData?.rows.count,
                    globalsSupplied: args.value("globals") != nil,
                    tlsPolicy: fileTLS?.overridesTrust == true || format == "postman"
                        ? fileTLS?.profile.mode.rawValue : nil,
                    clientIdentityConfigured: fileTLS?.hasClientIdentity,
                    scriptTranslation: args.flags.contains("translate-scripts") ? true : nil))
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

    private static func validateFileRunOutputs(_ args: Arguments) throws {
        guard
            !args.flags.contains("overwrite") || args.value("report") != nil
                || args.value("output") != nil || args.value("allure") != nil
                || args.value("export-environment") != nil || args.value("comparison-output") != nil
        else {
            throw CLIError.usage("--overwrite requires a report/output destination.")
        }
        let destinations = [
            args.value("report"), args.value("output"), args.value("export-environment"),
            args.value("comparison-output"),
        ].compactMap { $0 }
        let normalized = destinations.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() }
        let inputs = args.fileRunInputs
        guard Set(normalized).count == normalized.count, Set(normalized).isDisjoint(with: inputs),
            !normalized.contains(args.workspaceURL.resolvingSymlinksInPath())
        else {
            throw CLIError.usage(
                "Outputs must be distinct and cannot replace run inputs (including data and TLS files) or the desktop workspace."
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
        case .postman(let plan):
            plan.translatesScripts
                ? "bounded native script subset; no foreign runtime"
                : "HTTP 2xx checks; no Postman scripts"
        case .native: "native checks; unchecked responses require HTTP 2xx"
        }
    }
    func preview(
        _ args: Arguments, format: String, configuration: RunConfiguration, tlsInputsDeferred: Bool
    ) -> OfflineRunPlan {
        let sources: [String: String]
        let environment: String
        let deferred: Set<Int>
        let dynamicOrder: Bool
        switch self {
        case .postman(let plan):
            sources = plan.sourceLocations
            environment = args.value("environment-file") == nil ? "none" : "explicitFile"
            deferred = plan.deferredRequestPositions
            dynamicOrder = plan.scriptsMayChangeOrder
        case .native(let plan):
            sources = plan.sourceLocations
            environment =
                args.value("environment") != nil
                ? "explicitSelection" : plan.hasSelectedEnvironment ? "workspaceSelection" : "none"
            deferred = plan.deferredRequestPositions
            dynamicOrder = plan.requests.contains { $0.postHook != nil }
        }
        let steps = requests.enumerated().map { position, request in
            OfflineRunPlan.Step(
                position: position + 1, source: sources[request.id.uuidString] ?? "",
                method: request.method.rawValue,
                runtimeValidationDeferred: deferred.contains(position))
        }
        return OfflineRunPlan(
            inputFormat: format,
            selection: args.value("folder") != nil
                ? "folder" : args.value("collection") != nil ? "collection" : "entireFile",
            environmentSource: environment, iterations: configuration.iterations,
            baseSteps: steps.count * configuration.iterations, retries: configuration.retries,
            dynamicOrder: dynamicOrder, tlsInputsDeferred: tlsInputsDeferred, steps: steps)
    }

    func run(
        configuration: RunConfiguration, timeout: Double?,
        exportEnvironment: CollectionRunner.EnvironmentExport?, cookieJar: CookieJar?
    ) async throws -> RunReport {
        switch self {
        case .postman(let plan):
            try await plan.run(
                configuration: configuration, timeout: timeout,
                exportEnvironment: exportEnvironment,
                cookieJar: cookieJar
            )
        case .native(let plan):
            try await plan.run(
                configuration: configuration, timeout: timeout,
                exportEnvironment: exportEnvironment,
                cookieJar: cookieJar
            )
        }
    }
}
