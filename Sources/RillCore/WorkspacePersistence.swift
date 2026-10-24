import Foundation
import CryptoKit
import Darwin

public enum WorkspaceError: LocalizedError, Equatable {
    case unsupportedVersion(Int)
    case invalidStructure
    case tooLarge
    case tooDeep
    case conflict
    case unavailable

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion: "This workspace was written by an unsupported version. The original file has been preserved."
        case .invalidStructure: "The workspace has duplicate identities, invalid references or invalid values. The original file has been preserved."
        case .tooLarge: "The workspace exceeds the 32 MiB file limit."
        case .tooDeep: "The workspace exceeds the supported JSON nesting depth."
        case .conflict: "The workspace changed in another process. Saving has paused to protect both versions. Export your current edits before reopening the app."
        case .unavailable: "The workspace could not be accessed. Check its permissions and available storage, then retry."
        }
    }
}

public enum ResourceLimits {
    public static let workspaceBytes = 32 * 1024 * 1024
    public static let jsonDepth = 128
    public static let responseBytes = 16 * 1024 * 1024
    public static let previewBytes = 512 * 1024
    public static let historyBytes = 32 * 1024 * 1024
    public static let historyCount = 50
}

public enum WorkspaceFile {
    public static func validate(_ workspace: Workspace) throws {
        guard workspace.version == 1 else { throw WorkspaceError.unsupportedVersion(workspace.version) }
        func unique(_ values: [UUID]) -> Bool { Set(values).count == values.count }
        func fieldsValid(_ fields: [Field]) -> Bool { unique(fields.map(\.id)) }
        guard unique((workspace.tlsProfiles ?? []).map(\.id)) else { throw WorkspaceError.invalidStructure }
        for profile in workspace.tlsProfiles ?? [] { try TLSProfiles.validate(profile) }
        let profiles = workspace.authProfiles ?? [], secrets = workspace.namedSecrets ?? []
        guard unique(profiles.map(\.id)), unique(secrets.map(\.id)),
              profiles.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              Set(try secrets.map { try NamedSecretResolver.environmentKey(for: $0.name) }).count == secrets.count else { throw WorkspaceError.invalidStructure }
        for secret in secrets { try NamedSecretResolver.validateName(secret.name) }
        let collections = Set(workspace.collections.map(\.id))
        let environments = Set(workspace.environments.map(\.id))
        guard unique(workspace.collections.map(\.id)), unique(workspace.requests.map(\.id)),
              unique(workspace.environments.map(\.id)), unique(workspace.history.map(\.id)),
              workspace.selectedEnvironmentID.map({ environments.contains($0) }) ?? true else {
            throw WorkspaceError.invalidStructure
        }
        for request in workspace.requests {
            guard request.collectionID.map({ collections.contains($0) }) ?? true,
                  fieldsValid(request.headers), fieldsValid(request.parameters), fieldsValid(request.formFields ?? []), unique((request.multipartParts ?? []).map(\.id)),
                  request.timeout.isFinite, request.timeout > 0 else { throw WorkspaceError.invalidStructure }
        }
        for environment in workspace.environments {
            _ = try EnvironmentResolver.resolve(environment.id, in: workspace.environments)
            guard fieldsValid(environment.variables) else { throw WorkspaceError.invalidStructure }
        }
        // History may intentionally outlive a deleted request.
        for exchange in workspace.history {
            guard unique(exchange.checks.map(\.id)), fieldsValid(exchange.headers),
                  exchange.duration.isFinite, exchange.duration >= 0,
                  (100...599).contains(exchange.status) else { throw WorkspaceError.invalidStructure }
        }
    }

    static func checkJSONBounds(_ data: Data) throws {
        guard data.count <= ResourceLimits.workspaceBytes else { throw WorkspaceError.tooLarge }
        // Bound nesting before asking the JSON decoder to allocate its tree.
        var depth = 0, inString = false, escaped = false
        for byte in data {
            if inString {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { inString = false }
            } else if byte == 34 { inString = true }
            else if byte == 123 || byte == 91 {
                depth += 1
                if depth > ResourceLimits.jsonDepth { throw WorkspaceError.tooDeep }
            } else if byte == 125 || byte == 93 { depth -= 1 }
        }
    }

    public static func decode(_ data: Data) throws -> Workspace {
        try checkJSONBounds(data)
        // Version 1 is the initial supported schema. Future migrations must be
        // explicit; unknown schemas are never normalized and overwritten.
        let workspace: Workspace
        do { workspace = try JSONDecoder().decode(Workspace.self, from: data) }
        catch { throw WorkspaceError.invalidStructure }
        try validate(workspace)
        return workspace
    }

    public static func encode(_ workspace: Workspace) throws -> Data {
        try validate(workspace)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(workspace)
        guard data.count <= ResourceLimits.workspaceBytes else { throw WorkspaceError.tooLarge }
        return data
    }

    public static func load(from url: URL) throws -> Workspace {
        try decode(readBounded(from: url))
    }

    static func readBounded(from url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while let chunk = try handle.read(upToCount: min(65536, ResourceLimits.workspaceBytes + 1 - data.count)), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= ResourceLimits.workspaceBytes else { throw WorkspaceError.tooLarge }
        }
        return data
    }

    public static func save(_ workspace: Workspace, to url: URL) throws {
        let data = try encode(workspace)
        try atomicWrite(data, to: url)
    }

    static func createNew(_ data: Data, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw WorkspaceError.unavailable }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var complete = false
        defer { try? handle.close(); if !complete { try? FileManager.default.removeItem(at: url) } }
        try handle.write(contentsOf: data); try handle.synchronize(); try handle.close()
        complete = true
    }

    static func atomicWrite(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".rill-\(UUID().uuidString).tmp")
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw WorkspaceError.unavailable }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: temporary) }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        guard Darwin.rename(temporary.path, url.path) == 0 else { throw WorkspaceError.unavailable }
    }
}

/// A content revision prevents stale application instances from replacing a
/// newer file. The lock covers read/compare/rename across cooperating processes.
public struct WorkspaceRevision: Codable, Equatable, Sendable {
    let digest: String?
    public static let absent = WorkspaceRevision(digest: nil)
    init(data: Data) { digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private init(digest: String?) { self.digest = digest }
}

public struct WorkspaceSnapshot: Sendable {
    public let workspace: Workspace
    public let revision: WorkspaceRevision
}

public struct WorkspaceRepository: Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }

    public func load() throws -> WorkspaceSnapshot { try withSnapshot { $0 } }

    /// Allows companion stores to be read under the same cooperative lock.
    public func withSnapshot<T>(_ body: (WorkspaceSnapshot) throws -> T) throws -> T {
        try locked {
            guard FileManager.default.fileExists(atPath: url.path) else {
                return try body(WorkspaceSnapshot(workspace: .starter, revision: .absent))
            }
            let data = try WorkspaceFile.readBounded(from: url)
            return try body(WorkspaceSnapshot(workspace: try WorkspaceFile.decode(data), revision: WorkspaceRevision(data: data)))
        }
    }

    /// The callback runs after atomic replacement but before releasing the lock.
    /// It receives the committed revision even if a companion-store write fails.
    public func commit(_ workspace: Workspace, expecting revision: WorkspaceRevision,
                       onCommit: (WorkspaceRevision) throws -> Void = { _ in }) throws -> WorkspaceRevision {
        var persisted = workspace
        // Even credential-only or otherwise identical saves advance the token.
        persisted.storageRevision = UUID()
        let data = try WorkspaceFile.encode(persisted)
        return try locked {
            let existing: Data?
            if FileManager.default.fileExists(atPath: url.path) { existing = try WorkspaceFile.readBounded(from: url) }
            else { existing = nil }
            let actual = existing.map(WorkspaceRevision.init(data:)) ?? .absent
            guard actual == revision else { throw WorkspaceError.conflict }
            if let existing { _ = try WorkspaceFile.decode(existing) }
            try Task.checkCancellation()
            try WorkspaceFile.atomicWrite(data, to: url)
            let next = WorkspaceRevision(data: data)
            try onCommit(next)
            return next
        }
    }

    private func locked<T>(_ operation: () throws -> T) throws -> T {
        try WorkspaceFileLock.withLock(at: url, operation)
    }
}

internal enum WorkspaceFileLock {
    static func withLock<T>(at url: URL, _ operation: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = Darwin.open(url.appendingPathExtension("lock").path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw WorkspaceError.unavailable }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw WorkspaceError.unavailable }
        defer { flock(descriptor, LOCK_UN) }
        return try operation()
    }
}
