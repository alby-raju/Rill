import Foundation

public struct WorkspaceImportPreview: Sendable {
    public let collections: Int
    public let requests: Int
    public let environments: Int
    public let profiles: Int
    public let tlsProfiles: Int
    public let secretDescriptors: Int
    public let requestNames: [String]
    public let warnings: [String]
}
public struct WorkspaceImportPlan: Sendable {
    private let baseline: Workspace
    private let merged: Workspace
    public let preview: WorkspaceImportPreview
    let addedRequestIDs: Set<UUID>
    public init(incoming: Workspace, current: Workspace) throws {
        baseline = current
        merged = try WorkspaceImport.merging(incoming, into: current)
        addedRequestIDs = Set(merged.requests.map(\.id)).subtracting(current.requests.map(\.id))
        var disk = merged; disk.history = []
        for index in disk.requests.indices { disk.requests[index].credential = "" }
        _ = try WorkspaceFile.encode(disk)
        var warnings = ["Imported identities are regenerated. Existing requests and drafts are retained.", "Headers, URLs, bodies and environment values remain plain text and may contain secrets."]
        if !(incoming.authProfiles ?? []).isEmpty { warnings.append("Auth references may use configured local/process providers. No requests are sent until you choose Send.") }
        if incoming.requests.contains(where: { !$0.credential.isEmpty }) { warnings.append("Incoming request passwords/tokens are discarded; configure auth locally after import.") }
        if !(incoming.namedSecrets ?? []).isEmpty { warnings.append("Named-secret descriptors get fresh Keychain identities; configure their values locally. Colliding names and references are renamed.") }
        if (incoming.tlsProfiles ?? []).contains(where: { $0.requiresClientIdentity || $0.identityReference != nil }) { warnings.append("Client identities must be selected locally; foreign Keychain references are removed.") }
        if (incoming.tlsProfiles ?? []).contains(where: { $0.mode == .insecure }) { warnings.append("The import includes insecure TLS profiles. They remain visibly marked and desktop Send requires confirmation.") }
        if incoming.requests.contains(where: { $0.binaryFile != nil || ($0.multipartParts ?? []).contains(where: { $0.file != nil }) }) { warnings.append("File references are retained, not read or attached. Send verifies local file identity/size/time before reading.") }
        if !incoming.history.isEmpty { warnings.append("Incoming response history is not imported.") }
        preview = WorkspaceImportPreview(collections: incoming.collections.count, requests: incoming.requests.count, environments: incoming.environments.count, profiles: incoming.authProfiles?.count ?? 0, tlsProfiles: incoming.tlsProfiles?.count ?? 0, secretDescriptors: incoming.namedSecrets?.count ?? 0, requestNames: incoming.requests.prefix(30).map { $0.name.utf8.count > 512 ? String(decoding: $0.name.utf8.prefix(512), as: UTF8.self) + "…" : $0.name }, warnings: warnings)
    }
    public func applying(to current: Workspace) throws -> Workspace {
        guard !current.needsSave(comparedTo: baseline) else { throw WorkspaceError.conflict }
        var applied = merged
        // Responses can arrive during preview without becoming workspace edits.
        applied.history = current.history
        return applied
    }
}
