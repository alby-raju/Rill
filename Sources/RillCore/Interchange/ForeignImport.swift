import Foundation

/// Values exist only in memory until an explicitly reviewed Apply.
public struct ForeignWorkspaceImport: Sendable {
    public var workspace: Workspace
    public var warnings: [String]
    public var secretValues: [UUID: String]
    public init(workspace: Workspace, warnings: [String], secretValues: [UUID: String] = [:]) {
        self.workspace = workspace
        self.warnings = warnings
        self.secretValues = secretValues
    }
}
public struct ForeignImportPlan: Sendable {
    private let native: WorkspaceImportPlan
    private let merged: Workspace
    public let preview: WorkspaceImportPreview
    let requestIDs: Set<UUID>
    let secretValues: [UUID: String]
    public init(_ incoming: ForeignWorkspaceImport, current: Workspace) throws {
        let source = incoming.workspace
        guard source.requests.count <= 10_000, incoming.warnings.count <= 100,
            Set(incoming.secretValues.keys).isSubset(
                of: Set((source.namedSecrets ?? []).map(\.id))),
            incoming.warnings.reduce(0, { $0 + $1.utf8.count }) <= 128 * 1024,
            source.requests.allSatisfy({ $0.credential.utf8.count <= 1024 * 1024 }),
            source.requests.reduce(0, { $0 + $1.credential.utf8.count })
                <= ResourceLimits.workspaceBytes,
            incoming.secretValues.values.reduce(0, { $0 + $1.utf8.count })
                <= ResourceLimits.workspaceBytes,
            incoming.secretValues.values.allSatisfy({ $0.utf8.count <= 1024 * 1024 })
        else { throw WorkspaceError.invalidStructure }
        var sanitized = source
        for i in sanitized.requests.indices { sanitized.requests[i].credential = "" }
        native = try WorkspaceImportPlan(incoming: sanitized, current: current)
        var result = try native.applying(to: current)
        var values: [UUID: String] = [:]
        var names: [String: String] = [:]
        let offset = current.namedSecrets?.count ?? 0
        for (i, secret) in (source.namedSecrets ?? []).enumerated() {
            let destination = result.namedSecrets![offset + i]
            names[secret.name] = destination.name
            if let value = incoming.secretValues[secret.id] { values[destination.id] = value }
        }
        let pattern = try NSRegularExpression(pattern: #"\{\{\s*secret:([A-Za-z0-9_.-]+)\s*\}\}"#)
        for i in source.requests.indices {
            let original = source.requests[i].credential
            var credential = original
            for match in pattern.matches(
                in: original, range: NSRange(original.startIndex..., in: original)
            ).reversed() {
                guard let key = Range(match.range(at: 1), in: original),
                    let range = Range(match.range, in: credential),
                    let name = names[String(original[key])]
                else { continue }
                credential.replaceSubrange(range, with: "{{secret:" + name + "}}")
            }
            result.requests[current.requests.count + i].credential = credential
        }
        secretValues = values
        merged = result
        requestIDs = native.addedRequestIDs
        let p = native.preview
        preview = WorkspaceImportPreview(
            collections: p.collections, requests: p.requests, environments: p.environments,
            profiles: p.profiles, tlsProfiles: p.tlsProfiles,
            secretDescriptors: p.secretDescriptors, requestNames: p.requestNames,
            warnings: incoming.warnings + [
                "Fresh identities are created. Recognized auth and marked secret values are staged in Keychain only on Apply; no traffic or referenced file reads occur.",
                "URLs, bodies, headers and unmarked variables remain plain text. Review before sharing.",
            ])
    }
    public func applying(to current: Workspace) throws -> Workspace {
        _ = try native.applying(to: current)
        var result = merged
        result.history = current.history
        return result
    }
}

/// The repository invokes synchronous callbacks under its file lock. Keep compensation
/// state independently synchronized rather than capturing mutable actor-local state.
final class ImportCredentialStaging: @unchecked Sendable {
    private let lock = NSLock()
    private var staged: [(any CredentialStore, UUID)] = []
    func write(_ value: String, id: UUID, store: any CredentialStore) throws {
        try lock.withLock {
            try store.write(value, id: id)
            staged.append((store, id))
        }
    }
    func rollback() throws {
        try lock.withLock {
            var failed = false
            for (store, id) in staged.reversed() {
                do { try store.write("", id: id) } catch { failed = true }
            }
            staged = []
            if failed { throw WorkspaceError.companionRollback }
        }
    }
}

public enum ForeignImportFormat: String, Sendable {
    case postman = "Postman JSON", httpieDesktop = "HTTPie Desktop JSON", insomnia =
        "Insomnia JSON / YAML", bruno = "Bruno file / folder / ZIP"
    public func load(from url: URL) throws -> ForeignWorkspaceImport {
        switch self {
        case .postman: try PostmanImporter.load(from: url)
        case .httpieDesktop: try HTTPieDesktopImporter.load(from: url)
        case .insomnia: try InsomniaImporter.load(from: url)
        case .bruno: try BrunoImporter.load(from: url)
        }
    }
}
