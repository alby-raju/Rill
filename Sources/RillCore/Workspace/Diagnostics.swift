import Foundation

public enum PersistenceHealth: String, Codable, Sendable {
    case loading, saved, pending, saving, failed, conflict
}
public enum DiagnosticFailure: String, Codable, Sendable {
    case workspaceConflict, workspaceInvalid, storageUnavailable, keychainUnavailable
    case invalidRequest, responseLimit, timeout, cancelled, transport, unknown

    public static func classify(_ error: Error) -> DiagnosticFailure {
        if let error = error as? WorkspaceError {
            switch error {
            case .conflict: return .workspaceConflict
            case .unavailable: return .storageUnavailable
            default: return .workspaceInvalid
            }
        }
        if let error = error as? URLError {
            switch error.code {
            case .timedOut: return .timeout
            case .cancelled: return .cancelled
            default: return .transport
            }
        }
        if error is CancellationError { return .cancelled }
        if let error = error as? RillError {
            switch error {
            case .responseTooLarge: return .responseLimit
            default: return .invalidRequest
            }
        }
        if (error as NSError).domain == NSOSStatusErrorDomain { return .keychainUnavailable }
        return .unknown
    }
}

/// An allowlist, never a dump of a workspace, NSError, URLRequest or log buffer.
public struct SupportDiagnostics: Codable, Sendable {
    public let applicationVersion: String
    public let schemaVersion: Int
    public let generatedAt: Date
    public let operatingSystem: String
    public let architecture: String
    public let workspaceVersion: Int
    public let requestCount: Int
    public let collectionCount: Int
    public let environmentCount: Int
    public let sessionExchangeCount: Int
    public let persistence: PersistenceHealth
    public let lastFailure: DiagnosticFailure?
    public let responseLimitBytes: Int
    public let previewLimitBytes: Int

    public init(
        workspace: Workspace, persistence: PersistenceHealth, lastFailure: DiagnosticFailure?
    ) {
        applicationVersion = RillVersion.number
        schemaVersion = 1
        generatedAt = Date()
        let version = ProcessInfo.processInfo.operatingSystemVersion
        operatingSystem =
            "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        #if arch(arm64)
            architecture = "arm64"
        #elseif arch(x86_64)
            architecture = "x86_64"
        #else
            architecture = "unknown"
        #endif
        workspaceVersion = workspace.version
        requestCount = workspace.requests.count
        collectionCount = workspace.collections.count
        environmentCount = workspace.environments.count
        sessionExchangeCount = workspace.history.count
        self.persistence = persistence
        self.lastFailure = lastFailure
        responseLimitBytes = ResourceLimits.responseBytes
        previewLimitBytes = ResourceLimits.previewBytes
    }
    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try WorkspaceFile.atomicWrite(encoder.encode(self), to: url)
    }
}

/// A response may finish after the user navigates, edits or changes environment.
/// Only the original unchanged context can present it as the current response.
public struct ExecutionContext: Sendable {
    public let id = UUID()
    public let request: RequestDraft
    public let environment: Environment?
    public init(request: RequestDraft, environment: Environment?) {
        self.request = request
        self.environment = environment
    }
    public func matches(request: RequestDraft?, environment: Environment?) -> Bool {
        request == self.request && environment == self.environment
    }
}
