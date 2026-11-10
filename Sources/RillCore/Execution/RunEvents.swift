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
    /// Encode the completed run in bounded chunks, publishing only a complete report.
    public static func writeNDJSON(_ report: RunReport, to url: URL, overwrite: Bool = false)
        throws
    {
        try validate(report)
        try Task.checkCancellation()
        try WorkspaceFile.atomicWrite(to: url, replaceExisting: overwrite) { handle in
            try encodeNDJSON(report) { try handle.write(contentsOf: $0) }
            try Task.checkCancellation()
        }
    }

    static func encodeNDJSON(_ report: RunReport, write: (Data) throws -> Void) throws {
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
        let chunkBytes = 64 * 1024
        var buffer = Data()
        var writtenBytes = 0
        func append(_ event: Event) throws {
            try Task.checkCancellation()
            var line = try encoder.encode(event)
            line.append(10)
            guard writtenBytes + line.count <= 32 * 1024 * 1024 else {
                throw WorkflowError.limit
            }
            writtenBytes += line.count
            if buffer.count + line.count > chunkBytes, !buffer.isEmpty {
                try write(buffer)
                buffer.removeAll(keepingCapacity: true)
            }
            if line.count > chunkBytes {
                try write(line)
            } else {
                buffer.append(line)
            }
        }
        try append(
            Event(
                type: "started", runID: report.id, sequence: 0, started: report.started,
                requestedSteps: report.requestedSteps))
        for (index, attempt) in report.outcomes.enumerated() {
            let source = (report.sources?[attempt.requestID.uuidString]).flatMap {
                RunSources.valid($0) ? $0 : nil
            }
            try append(
                Event(
                    type: "attempt", runID: report.id, sequence: index + 1,
                    attempt: sanitizedAttempt(attempt), sourceLocation: source))
        }
        try append(
            Event(
                type: "finished", runID: report.id, sequence: report.outcomes.count + 1,
                passed: report.passed, cancelled: report.cancelled,
                timedOut: report.timedOut ?? false,
                exhausted: report.exhausted, stopped: report.stopped))
        if !buffer.isEmpty { try write(buffer) }
    }
}
