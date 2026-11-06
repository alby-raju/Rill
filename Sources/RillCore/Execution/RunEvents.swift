import Foundation

public enum RunFailureKind: String, Codable, Sendable {
    case assertion, configuration, authentication, tls, contract, transport, timeout, deadline,
        cancelled, resourceLimit, unknown
    static func classify(_ error: Error) -> Self {
        if error is RunDeadlineError { return .deadline }
        if error is AuthenticationError { return .authentication }
        if error is TLSError || error is FileTLSError { return .tls }
        if error is ContractError { return .contract }
        if let error = error as? WorkflowError {
            return error == .limit ? .resourceLimit : .configuration
        }
        switch DiagnosticFailure.classify(error) {
        case .timeout: return .timeout
        case .cancelled: return .cancelled
        case .transport: return .transport
        case .responseLimit: return .resourceLimit
        case .invalidRequest, .workspaceInvalid: return .configuration
        default: return .unknown
        }
    }
}

extension RunReportExporter {
    /// Atomic end-of-run event export, not a live event stream. Same allowlist as JSON/HTML.
    static func ndjson(_ safe: RunReport) throws -> Data {
        struct Event: Encodable {
            let schemaVersion = 1
            let kind = "rill.run-event"
            let type: String
            let runID: UUID
            let sequence: Int
            var attempt: RunAttempt?
            var passed: Bool?
            var cancelled: Bool?
            var timedOut: Bool?
            var exhausted: Bool?
            var stopped: Bool?
            var started: Date?
            var requestedSteps: Int?
            var sourceLocation: String?
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        var result = Data()
        func append(_ event: Event) throws {
            try Task.checkCancellation()
            let data = try encoder.encode(event)
            guard result.count + data.count + 1 <= 32 * 1024 * 1024 else {
                throw WorkflowError.limit
            }
            result.append(data)
            result.append(10)
        }
        try append(
            Event(
                type: "started", runID: safe.id, sequence: 0, started: safe.started,
                requestedSteps: safe.requestedSteps))
        for (index, attempt) in safe.outcomes.enumerated() {
            try append(
                Event(
                    type: "attempt", runID: safe.id, sequence: index + 1, attempt: attempt,
                    sourceLocation: safe.sources?[attempt.requestID.uuidString]))
        }
        try append(
            Event(
                type: "finished", runID: safe.id, sequence: safe.outcomes.count + 1,
                passed: safe.passed, cancelled: safe.cancelled, timedOut: safe.timedOut ?? false,
                exhausted: safe.exhausted, stopped: safe.stopped))
        return result
    }
}
