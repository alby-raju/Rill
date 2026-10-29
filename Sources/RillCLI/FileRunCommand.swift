import Foundation
import RillCore

extension RillCLI {
    static func runFile(_ args: Arguments) async throws {
        guard args.operands.count == 1,
            Set(args.values.keys).isSubset(of: [
                "environment-file", "env-var", "iterations", "delay", "retries", "retry-delay",
                "report", "report-format", "allure", "output", "timeout", "color",
            ]),
            args.flags.isSubset(of: ["json", "quiet", "detail", "continue-on-failure", "overwrite"]
            ),
            args.value("report-format") == nil || args.value("report") != nil
        else {
            throw CLIError.usage(
                "Use run COLLECTION.json with Postman v2 environment/variable, pacing/retry and report options. Saved workspace, folder, TLS-file and iteration-data options are not supported in this increment."
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
        let plan: PostmanFileRun
        do {
            plan = try PostmanFileRun.prepare(
                collection: BoundedFileInput.read(
                    URL(fileURLWithPath: args.operands[0]), limit: ResourceLimits.workspaceBytes),
                environment: try args.value("environment-file").map {
                    try BoundedFileInput.read(
                        URL(fileURLWithPath: $0), limit: ResourceLimits.workspaceBytes)
                },
                overrides: args.variableOverrides())
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
                "Could not prepare bounded Postman v2 collection/environment JSON inputs; no requests sent; source content omitted."
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
                "Rill file run · \(requests.count) requests · HTTP 2xx checks · Postman scripts are not executed"
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
            }
            try args.json(
                Summary(
                    passed: report.passed, cancelled: report.cancelled, exhausted: report.exhausted,
                    attempts: report.outcomes.filter { $0.state != .notRun }.count))
        } else {
            try args.text(
                RunConsole.render(
                    report, requests: requests,
                    title: "Collection file (HTTP 2xx checks; no Postman scripts)",
                    detail: args.flags.contains("detail"), color: args.color))
        }
        try requireSuccessfulRun(report)
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
