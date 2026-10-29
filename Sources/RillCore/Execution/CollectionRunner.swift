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
    public init() {}
    public func validate() throws {
        guard (1...10_000).contains(iterations), (1...10_000).contains(executionLimit),
            (0...5).contains(retries),
            (0...60_000).contains(delayMilliseconds), (0...60_000).contains(retryDelayMilliseconds),
            (0...(32 * 1024 * 1024)).contains(retentionBytes)
        else { throw WorkflowError.invalidConfiguration }
    }
}
public enum RunState: String, Codable, Sendable { case passed, failed, cancelled, notRun }
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
    public var fingerprint: String?
    public var retainedBody: Data?
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
    public var requestedSteps: Int
    /// A failed attempt recovered by an explicit retry does not fail the whole run.
    public var passed: Bool {
        guard !outcomes.isEmpty, !cancelled, !exhausted else { return false }
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
            return outcome.state == .passed
        }
    }
}
public struct RunProgress: Sendable {
    public let completed: Int
    public let requestID: UUID
    public let state: RunState
}
public enum CollectionRunner {
    public typealias Executor =
        @Sendable (RequestDraft, [String: String]) async throws -> WorkflowStepResult
    public static func run(
        requests: [RequestDraft], environment: Environment?, configuration: RunConfiguration,
        profiles: [AuthenticationProfile] = [], secrets: NamedSecretResolver? = nil,
        tlsProfiles: [TLSProfile] = [], definitions: [APIDefinitionSource] = [],
        progress: (@Sendable (RunProgress) async -> Void)? = nil, executor: Executor? = nil
    ) async throws -> RunReport {
        try configuration.validate()
        guard requests.count <= 10_000, requests.count * configuration.iterations <= 10_000,
            Set(requests.map(\.id)).count == requests.count
        else { throw WorkflowError.invalidConfiguration }
        let started = ProcessInfo.processInfo.systemUptime
        var report = RunReport(requestedSteps: requests.count * configuration.iterations)
        report.cancelled = Task.isCancelled
        var variables = WorkflowEngine.variables(in: environment)
        var retained = 0
        var retainedChecks = 0
        try WorkflowEngine.validateVariables(variables)
        let execute: Executor =
            executor ?? { request, values in
                try await WorkflowEngine.execute(
                    request, variables: values, profiles: profiles, secrets: secrets,
                    tlsProfiles: tlsProfiles, definitions: definitions)
            }
        func pause(_ milliseconds: Int) async throws {
            try Task.checkCancellation()
            if milliseconds > 0 { try await Task.sleep(for: .milliseconds(milliseconds)) }
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
                            let result = try await execute(request, variables)
                            try Task.checkCancellation()
                            var outcome = RunAttempt(
                                requestID: request.id, started: attemptStarted,
                                iteration: iteration, attempt: attempt,
                                state: result.passed ? .passed : .failed,
                                status: result.exchange.status, duration: result.exchange.duration,
                                checks: result.exchange.checks,
                                fingerprint: SHA256.hash(data: result.exchange.body).map {
                                    String(format: "%02x", $0)
                                }.joined(), bodyBytes: result.exchange.body.count,
                                bodyOmitted: false)
                            if result.passed {
                                do {
                                    if let target = result.next {
                                        next = try branch(target, from: request)
                                    }
                                } catch {
                                    outcome.state = .failed
                                    outcome.failure = WorkflowError.invalidBranch.rawValue
                                }
                            }
                            if result.exchange.body.count <= configuration.retentionBytes - retained
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
                            finalPassed = outcome.state == .passed
                            if finalPassed {
                                do {
                                    try WorkflowEngine.validateVariables(result.variables)
                                    variables = result.variables
                                    stop = result.stop
                                } catch {
                                    finalPassed = false
                                    outcome.state = .failed
                                    outcome.failure = WorkflowError.limit.rawValue
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
                            let outcome = RunAttempt(
                                requestID: request.id, started: attemptStarted,
                                iteration: iteration, attempt: attempt, state: .failed,
                                duration: ProcessInfo.processInfo.systemUptime - before, checks: [],
                                failure: (error as? WorkflowError)?.rawValue
                                    ?? DiagnosticFailure.classify(error).rawValue,
                                bodyBytes: 0, bodyOmitted: true)
                            report.outcomes.append(outcome)
                            if let progress {
                                await progress(
                                    RunProgress(
                                        completed: report.outcomes.count, requestID: request.id,
                                        state: .failed))
                            }
                        }
                    } catch {
                        report.cancelled = true
                        report.outcomes.append(
                            RunAttempt(
                                requestID: request.id, iteration: iteration, attempt: attempt,
                                state: .cancelled, duration: 0, checks: [], failure: "cancelled",
                                bodyBytes: 0, bodyOmitted: true))
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
                            ? "cancelled" : report.exhausted ? "executionLimit" : "branchOrStop",
                        bodyBytes: 0, bodyOmitted: true))
            }
        }
        report.duration = ProcessInfo.processInfo.systemUptime - started
        return report
    }
}
