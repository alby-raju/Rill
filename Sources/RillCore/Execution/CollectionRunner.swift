import CryptoKit
import Foundation

public struct RunConfiguration: Codable, Equatable, Sendable {
    public var iterations = 1
    public var executionLimit = 10_000
    public var retries = 0
    public var delayMilliseconds = 0
    public var retryDelayMilliseconds = 0
    public var stopOnFailure = true
    public var retentionBytes = 32 * 1024 * 1024
    /// Missing in older saved configurations; each enabled run receives a fresh private jar.
    public var cookieSession: Bool? = nil
    public var seed: UInt64?
    public var seedTimestamp: Int64?
    public var totalDeadlineSeconds: Double?
    public var retainComparisonHeaders: Bool?
    public init() {}
    public func validate() throws {
        guard seedTimestamp == nil || seed != nil,
            seedTimestamp.map({ (0...253402300799).contains($0) }) ?? true,
            totalDeadlineSeconds.map({ $0.isFinite && (0.01...86400).contains($0) }) ?? true
        else { throw WorkflowError.invalidConfiguration }
        guard (1...10_000).contains(iterations), (1...10_000).contains(executionLimit),
            (0...5).contains(retries),
            (0...60_000).contains(delayMilliseconds), (0...60_000).contains(retryDelayMilliseconds),
            (0...(32 * 1024 * 1024)).contains(retentionBytes)
        else { throw WorkflowError.invalidConfiguration }
    }
}
public enum RunState: String, Codable, Sendable { case passed, failed, cancelled, notRun, skipped }
public struct RunAttempt: Codable, Identifiable, Sendable {
    public var id = UUID()
    public var requestID: UUID
    public var started: Date? = nil
    public var iteration: Int
    public var attempt: Int
    public var state: RunState
    public var status: Int?
    public var duration: Double
    public var checks: [CheckResult]
    public var checkCount: Int? = nil
    public var failedCheckCount: Int? = nil
    public var checksOmitted: Bool? = nil
    public var checkSignature: String? = nil
    public var failure: String?
    public var failureKind: RunFailureKind? = nil
    public var fingerprint: String?
    public var retainedBody: Data?
    public var responseHeaders: [Field]? = nil
    public var headersOmitted: Bool? = nil
    public var bodyBytes: Int
    public var bodyOmitted: Bool
}
public struct RunReport: Codable, Identifiable, Sendable {
    public var id = UUID()
    public var started = Date()
    public var duration: Double = 0
    public var outcomes: [RunAttempt] = []
    public var cancelled = false
    public var exhausted = false
    public var stopped = false
    public var timedOut: Bool?
    public var sourceFormat: String?
    public var sources: [String: String]?
    public var requestedSteps: Int
    /// A failed attempt recovered by an explicit retry does not fail the whole run.
    public var passed: Bool {
        guard !outcomes.isEmpty, !cancelled, !exhausted, timedOut != true else { return false }
        let executed = outcomes.filter { $0.state != .notRun }
        guard !executed.isEmpty else { return false }
        return executed.enumerated().allSatisfy { index, outcome in
            if index + 1 < executed.count {
                let next = executed[index + 1]
                if next.requestID == outcome.requestID && next.iteration == outcome.iteration
                    && next.attempt == outcome.attempt + 1
                {
                    return true
                }
            }
            return outcome.state == .passed || outcome.state == .skipped
        }
    }
}
public struct RunProgress: Sendable {
    public let completed: Int
    public let requestID: UUID
    public let state: RunState
}
public struct RunStepContext: Sendable {
    public let iteration: Int
    public let attempt: Int
}

public enum CollectionRunner {
    public typealias Executor =
        @Sendable (RequestDraft, [String: String]) async throws -> WorkflowStepResult
    public typealias ContextualExecutor =
        @Sendable (RequestDraft, [String: String], RunStepContext) async throws ->
        WorkflowStepResult
    /// Opt-in raw variable handoff; values never enter RunReport or ordinary diagnostics.
    public typealias EnvironmentExport = @Sendable ([String: String]) async throws -> Void
    public static func run(
        requests: [RequestDraft], environment: Environment?, configuration: RunConfiguration,
        profiles: [AuthenticationProfile] = [], secrets: NamedSecretResolver? = nil,
        tlsProfiles: [TLSProfile] = [], definitions: [APIDefinitionSource] = [],
        iterationData: IterationData? = nil, iterationOverrides: [String: String] = [:],
        progress: (@Sendable (RunProgress) async -> Void)? = nil,
        exportEnvironment: EnvironmentExport? = nil, cookieJar: CookieJar? = nil,
        executor: Executor? = nil, contextualExecutor: ContextualExecutor? = nil
    ) async throws -> RunReport {
        try configuration.validate()
        if let seed = configuration.seed {
            return try await DynamicTemplates.withSeed(
                seed, epochSeconds: configuration.seedTimestamp ?? 0
            ) {
                try await executeRun(
                    requests: requests, environment: environment, configuration: configuration,
                    profiles: profiles, secrets: secrets, tlsProfiles: tlsProfiles,
                    definitions: definitions,
                    iterationData: iterationData, iterationOverrides: iterationOverrides,
                    progress: progress, exportEnvironment: exportEnvironment, cookieJar: cookieJar,
                    executor: executor, contextualExecutor: contextualExecutor)
            }
        }
        return try await executeRun(
            requests: requests, environment: environment, configuration: configuration,
            profiles: profiles, secrets: secrets, tlsProfiles: tlsProfiles,
            definitions: definitions,
            iterationData: iterationData, iterationOverrides: iterationOverrides,
            progress: progress, exportEnvironment: exportEnvironment, cookieJar: cookieJar,
            executor: executor, contextualExecutor: contextualExecutor)
    }
    private static func executeRun(
        requests: [RequestDraft], environment: Environment?, configuration: RunConfiguration,
        profiles: [AuthenticationProfile] = [], secrets: NamedSecretResolver? = nil,
        tlsProfiles: [TLSProfile] = [], definitions: [APIDefinitionSource] = [],
        iterationData: IterationData? = nil, iterationOverrides: [String: String] = [:],
        progress: (@Sendable (RunProgress) async -> Void)? = nil,
        exportEnvironment: EnvironmentExport? = nil, cookieJar: CookieJar? = nil,
        executor: Executor? = nil, contextualExecutor: ContextualExecutor? = nil
    ) async throws -> RunReport {
        try configuration.validate()
        guard executor == nil || contextualExecutor == nil else {
            throw WorkflowError.invalidConfiguration
        }
        guard requests.count <= 10_000, requests.count * configuration.iterations <= 10_000,
            Set(requests.map(\.id)).count == requests.count
        else { throw WorkflowError.invalidConfiguration }
        let started = ProcessInfo.processInfo.systemUptime
        let deadline = configuration.totalDeadlineSeconds.map {
            ContinuousClock.now.advanced(by: .seconds($0))
        }
        var report = RunReport(requestedSteps: requests.count * configuration.iterations)
        report.cancelled = Task.isCancelled
        var variables = WorkflowEngine.variables(in: environment)
        let baseVariables = variables
        if let iterationData {
            guard iterationData.rows.count == configuration.iterations else {
                throw WorkflowError.invalidConfiguration
            }
            for index in iterationData.rows.indices {
                try Task.checkCancellation()
                _ = try iterationData.variables(
                    at: index, base: baseVariables, overrides: iterationOverrides)
            }
        } else if !iterationOverrides.isEmpty {
            throw WorkflowError.invalidConfiguration
        }
        var retained = 0
        var retainedChecks = 0
        var retainedHeaderBytes = 0
        try WorkflowEngine.validateVariables(variables)
        let cookieJar = cookieJar ?? (configuration.cookieSession == true ? CookieJar() : nil)
        let execute: Executor =
            executor ?? { request, values in
                try await WorkflowEngine.execute(
                    request, variables: values, profiles: profiles, secrets: secrets,
                    tlsProfiles: tlsProfiles, definitions: definitions, cookieJar: cookieJar)
            }
        func pause(_ milliseconds: Int) async throws {
            try Task.checkCancellation()
            try await RunDeadline.perform(until: deadline) {
                if milliseconds > 0 { try await Task.sleep(for: .milliseconds(milliseconds)) }
            }
        }
        func branch(_ target: String, from request: RequestDraft) throws -> Int {
            if let id = UUID(uuidString: target),
                let index = requests.firstIndex(where: { $0.id == id })
            {
                guard requests[index].collectionID == request.collectionID else {
                    throw WorkflowError.invalidBranch
                }
                return index
            }
            let matches = requests.indices.filter {
                requests[$0].name == target && requests[$0].collectionID == request.collectionID
            }
            guard matches.count == 1 else { throw WorkflowError.invalidBranch }
            return matches[0]
        }
        loop: for iteration in 1...configuration.iterations {
            if let iterationData {
                variables = try iterationData.variables(
                    at: iteration - 1, base: baseVariables, overrides: iterationOverrides)
            }
            var index = 0
            while index < requests.count {
                let request = requests[index]
                var next: Int?
                var stop = false
                var finalPassed = false
                for attempt in 1...(configuration.retries + 1) {
                    guard report.outcomes.count < configuration.executionLimit else {
                        report.exhausted = true
                        break loop
                    }
                    do {
                        try await pause(
                            report.outcomes.isEmpty
                                ? 0
                                : attempt == 1
                                    ? configuration.delayMilliseconds
                                    : configuration.retryDelayMilliseconds)
                        let attemptStarted = Date()
                        let before = ProcessInfo.processInfo.systemUptime
                        do {
                            let stepVariables = variables
                            let context = RunStepContext(iteration: iteration, attempt: attempt)
                            let result = try await RunDeadline.perform(until: deadline) {
                                if let contextualExecutor {
                                    return try await contextualExecutor(
                                        request, stepVariables, context)
                                }
                                return try await execute(request, stepVariables)
                            }
                            try Task.checkCancellation()
                            var outcome = RunAttempt(
                                requestID: request.id, started: attemptStarted,
                                iteration: iteration, attempt: attempt,
                                state: result.skipped
                                    ? .skipped : result.passed ? .passed : .failed,
                                status: result.skipped ? nil : result.exchange.status,
                                duration: result.exchange.duration,
                                checks: result.exchange.checks,
                                fingerprint: result.skipped
                                    ? nil
                                    : SHA256.hash(data: result.exchange.body).map {
                                        String(format: "%02x", $0)
                                    }.joined(), bodyBytes: result.exchange.body.count,
                                bodyOmitted: result.skipped
                                    || result.exchange.bodyWasTruncated == true)
                            if configuration.retainComparisonHeaders == true && !result.skipped {
                                let headers = result.exchange.headers
                                let bytes = headers.reduce(0) {
                                    $0 + $1.name.utf8.count + $1.value.utf8.count
                                }
                                if headers.count <= 100 && bytes <= 65536
                                    && retainedHeaderBytes + bytes <= 4 * 1024 * 1024
                                {
                                    outcome.responseHeaders = headers
                                    outcome.headersOmitted = false
                                    retainedHeaderBytes += bytes
                                } else {
                                    outcome.headersOmitted = true
                                }
                            }
                            if outcome.state == .failed { outcome.failureKind = .assertion }
                            if result.passed || result.commitVariablesOnFailure {
                                do {
                                    if let target = result.next {
                                        next = try branch(target, from: request)
                                    }
                                } catch {
                                    outcome.state = .failed
                                    outcome.failure = WorkflowError.invalidBranch.rawValue
                                    outcome.failureKind = .configuration
                                }
                            }
                            if !result.skipped,
                                result.exchange.body.count <= configuration.retentionBytes
                                    - retained
                            {
                                outcome.retainedBody = result.exchange.body
                                retained += result.exchange.body.count
                            } else {
                                outcome.bodyOmitted = true
                            }
                            outcome.checkCount = outcome.checks.count
                            outcome.failedCheckCount = outcome.checks.filter { !$0.passed }.count
                            outcome.checkSignature = SHA256.hash(
                                data: Data(
                                    outcome.checks.map { $0.passed ? "1" : "0" }.joined().utf8)
                            ).map { String(format: "%02x", $0) }.joined()
                            if outcome.checks.count <= 100_000 - retainedChecks {
                                retainedChecks += outcome.checks.count
                                outcome.checks = outcome.checks.enumerated().map { index, check in
                                    CheckResult(title: "Check \(index + 1)", passed: check.passed)
                                }
                                outcome.checksOmitted = false
                            } else {
                                outcome.checks = []
                                outcome.checksOmitted = true
                            }
                            finalPassed = outcome.state == .passed || outcome.state == .skipped
                            if finalPassed
                                || (result.commitVariablesOnFailure && outcome.failure == nil)
                            {
                                do {
                                    try WorkflowEngine.validateVariables(result.variables)
                                    variables = result.variables
                                    stop = result.stop
                                } catch {
                                    finalPassed = false
                                    outcome.state = .failed
                                    outcome.failure = WorkflowError.limit.rawValue
                                    outcome.failureKind = .configuration
                                    next = nil
                                }
                            }
                            report.outcomes.append(outcome)
                            if let progress {
                                await progress(
                                    RunProgress(
                                        completed: report.outcomes.count, requestID: request.id,
                                        state: outcome.state))
                            }
                        } catch is CancellationError { throw CancellationError() } catch let error
                            as URLError where error.code == .cancelled
                        { throw CancellationError() } catch {
                            if error is RunDeadlineError { report.timedOut = true }
                            var outcome = RunAttempt(
                                requestID: request.id, started: attemptStarted,
                                iteration: iteration, attempt: attempt, state: .failed,
                                duration: ProcessInfo.processInfo.systemUptime - before, checks: [],
                                failure: error is RunDeadlineError
                                    ? "totalDeadline"
                                    : (error as? WorkflowError)?.rawValue
                                        ?? DiagnosticFailure.classify(error).rawValue,
                                bodyBytes: 0, bodyOmitted: true)
                            outcome.failureKind = RunFailureKind.classify(error)
                            report.outcomes.append(outcome)
                            if let progress {
                                await progress(
                                    RunProgress(
                                        completed: report.outcomes.count, requestID: request.id,
                                        state: .failed))
                            }
                        }
                    } catch is RunDeadlineError {
                        report.timedOut = true
                        report.stopped = true
                        report.outcomes.append(
                            RunAttempt(
                                requestID: request.id, iteration: iteration,
                                attempt: attempt, state: .failed, duration: 0, checks: [],
                                failure: "totalDeadline", bodyBytes: 0, bodyOmitted: true))
                        break loop
                    } catch {
                        report.cancelled = true
                        report.outcomes.append(
                            RunAttempt(
                                requestID: request.id, iteration: iteration, attempt: attempt,
                                state: .cancelled, duration: 0, checks: [], failure: "cancelled",
                                bodyBytes: 0, bodyOmitted: true))
                        break loop
                    }
                    if report.timedOut == true {
                        report.stopped = true
                        break loop
                    }
                    if finalPassed { break }
                }
                if stop {
                    report.stopped = true
                    break loop
                }
                if !finalPassed && configuration.stopOnFailure {
                    report.stopped = true
                    break loop
                }
                index = next ?? index + 1
            }
        }
        let visited = Set(report.outcomes.map { "\($0.iteration)/\($0.requestID)" })
        for iteration in 1...configuration.iterations {
            for request in requests where !visited.contains("\(iteration)/\(request.id)") {
                report.outcomes.append(
                    RunAttempt(
                        requestID: request.id, iteration: iteration, attempt: 0, state: .notRun,
                        duration: 0, checks: [],
                        failure: report.cancelled
                            ? "cancelled"
                            : report.timedOut == true
                                ? "totalDeadline"
                                : report.exhausted ? "executionLimit" : "branchOrStop",
                        bodyBytes: 0, bodyOmitted: true))
            }
        }
        for index in report.outcomes.indices where report.outcomes[index].failureKind == nil {
            if report.outcomes[index].state == .cancelled {
                report.outcomes[index].failureKind = .cancelled
            } else if report.outcomes[index].failure == "totalDeadline" {
                report.outcomes[index].failureKind = .deadline
            } else if report.outcomes[index].failure == "executionLimit" {
                report.outcomes[index].failureKind = .resourceLimit
            }
        }
        report.duration = ProcessInfo.processInfo.systemUptime - started
        if !report.cancelled {
            try Task.checkCancellation()
            try await exportEnvironment?(variables)
        }
        return report
    }
}
