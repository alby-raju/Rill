import Foundation
import Security

/// All workspace and Keychain I/O runs on this actor, away from the UI executor.
public actor WorkspaceSession {
    private let repository: WorkspaceRepository
    private var revision: WorkspaceRevision?
    private var credentials: [UUID: String] = [:]
    private let credentialStore: any CredentialStore
    private let namedCredentialStore: any CredentialStore

    public init(url: URL, credentials: any CredentialStore = KeychainCredentialStore(), namedCredentials: any CredentialStore = KeychainCredentialStore(service: "app.rill.namedsecrets")) {
        repository = WorkspaceRepository(url: url)
        credentialStore = credentials
        namedCredentialStore = namedCredentials
    }

    public func open() throws -> Workspace {
        try repository.withSnapshot { snapshot in
            var workspace = snapshot.workspace
            var loaded: [UUID: String] = [:]
            for index in workspace.requests.indices {
                let id = workspace.requests[index].id
                let credential = try credentialStore.read(id)
                workspace.requests[index].credential = credential
                loaded[id] = credential
            }
            credentials = loaded
            revision = snapshot.revision
            return workspace
        }
    }

    public func save(_ workspace: Workspace) throws {
        try Task.checkCancellation()
        guard let revision else { throw WorkspaceError.unavailable }
        var disk = workspace
        disk.history = []
        for index in disk.requests.indices { disk.requests[index].credential = "" }
        self.revision = try repository.commit(disk, expecting: revision) { committed in
            // Record the accepted revision even if a later Keychain operation fails.
            self.revision = committed
            // Keep companion-store reads/writes within the same cooperative lock.
            for request in workspace.requests where credentials[request.id] != request.credential {
                try credentialStore.write(request.credential, id: request.id)
                credentials[request.id] = request.credential
            }
            let retained = Set(workspace.requests.map(\.id))
            for id in Array(credentials.keys) where !retained.contains(id) {
                try credentialStore.write("", id: id)
                credentials.removeValue(forKey: id)
            }
        }
    }
    /// Native import adds fresh identities with no credentials. Commit metadata
    /// without unnecessary companion-store writes, then publish the accepted value.
    public func applyImport(_ plan: WorkspaceImportPlan, current: Workspace) throws -> Workspace {
        try Task.checkCancellation()
        guard let revision else { throw WorkspaceError.unavailable }
        let updated = try plan.applying(to: current)
        for request in updated.requests {
            if plan.addedRequestIDs.contains(request.id) {
                guard request.credential.isEmpty else { throw WorkspaceError.invalidStructure }
            } else { guard credentials[request.id] == request.credential else { throw WorkspaceError.conflict } }
        }
        var disk = updated; disk.history = []
        for index in disk.requests.indices { disk.requests[index].credential = "" }
        self.revision = try repository.commit(disk, expecting: revision)
        for id in plan.addedRequestIDs { credentials[id] = "" }
        return updated
    }
    public func importRequest(_ incoming: RequestDraft, current: Workspace) throws -> (workspace: Workspace, requestID: UUID) {
        try Task.checkCancellation()
        guard let revision else { throw WorkspaceError.unavailable }
        for request in current.requests { guard credentials[request.id] == request.credential else { throw WorkspaceError.conflict } }
        var request = incoming; request.id = UUID()
        var updated = current; updated.requests.append(request)
        var disk = updated; disk.history = []
        for index in disk.requests.indices { disk.requests[index].credential = "" }
        self.revision = try repository.commitWithCompanion(disk, expecting: revision, beforeWrite: {
            if !request.credential.isEmpty { try credentialStore.write(request.credential, id: request.id) }
        }, onWriteFailure: {
            if !request.credential.isEmpty { try credentialStore.write("", id: request.id) }
        })
        credentials[request.id] = request.credential
        return (updated, request.id)
    }
    public func applyForeignImport(_ plan: ForeignImportPlan, current: Workspace) throws -> Workspace {
        try Task.checkCancellation()
        guard let revision else { throw WorkspaceError.unavailable }
        for request in current.requests { guard credentials[request.id] == request.credential else { throw WorkspaceError.conflict } }
        let updated = try plan.applying(to: current)
        var disk = updated; disk.history = []
        for i in disk.requests.indices { disk.requests[i].credential = "" }
        let staging = ImportCredentialStaging()
        self.revision = try repository.commitWithCompanion(disk, expecting: revision, beforeWrite: {
            do {
                for request in updated.requests where plan.requestIDs.contains(request.id) && !request.credential.isEmpty {
                    try Task.checkCancellation()
                    try staging.write(request.credential, id: request.id, store: credentialStore)
                }
                for (id, value) in plan.secretValues.sorted(by: { $0.key.uuidString < $1.key.uuidString }) where !value.isEmpty {
                    try Task.checkCancellation()
                    try staging.write(value, id: id, store: namedCredentialStore)
                }
                try Task.checkCancellation()
            } catch { let original = error; try staging.rollback(); throw original }
        }, onWriteFailure: { try staging.rollback() })
        for request in updated.requests where plan.requestIDs.contains(request.id) { credentials[request.id] = request.credential }
        return updated
    }
    public func applyAPIPlan(_ plan: APIImportPlan, current: Workspace) throws -> Workspace {
        try Task.checkCancellation()
        guard let revision else { throw WorkspaceError.unavailable }
        let updated = try plan.applying(to: current)
        for request in updated.requests {
            guard request.credential == (credentials[request.id] ?? "") else { throw WorkspaceError.conflict }
        }
        let retained = Set(updated.requests.map(\.id))
        for (id, value) in credentials where !retained.contains(id) { guard value.isEmpty else { throw WorkspaceError.conflict } }
        var disk = updated; disk.history = []
        for index in disk.requests.indices { disk.requests[index].credential = "" }
        self.revision = try repository.commit(disk, expecting: revision)
        credentials = Dictionary(uniqueKeysWithValues: updated.requests.map { ($0.id, $0.credential) })
        return updated
    }
    public func currentRevision() -> WorkspaceRevision? { revision }

    public func restore(_ contents: BackupContents, retainingPreviousAt previous: URL, editor: EditorSessionState?) throws -> Workspace {
        try contents.validate()
        guard previous.standardizedFileURL.resolvingSymlinksInPath() != repository.url.standardizedFileURL.resolvingSymlinksInPath() else { throw BackupError.invalid }
        guard let revision else { throw WorkspaceError.unavailable }
        try repository.withSnapshot { snapshot in
            guard snapshot.revision == revision else { throw WorkspaceError.conflict }
            try WorkspaceFile.createNew(WorkspaceBackup.encode(workspace: snapshot.workspace, editor: editor), at: previous)
        }
        var restored = contents.workspace
        restored.history = []
        self.revision = try repository.commit(restored, expecting: revision) { committed in
            self.revision = committed
            var loaded: [UUID: String] = [:]
            for index in restored.requests.indices {
                let id = restored.requests[index].id
                restored.requests[index].credential = try credentialStore.read(id)
                loaded[id] = restored.requests[index].credential
            }
            // Retain other local keys so the pre-restore workspace remains usable.
            credentials = loaded
        }
        return restored
    }

}

public protocol CredentialStore: Sendable {
    func read(_ id: UUID) throws -> String
    func write(_ value: String, id: UUID) throws
}

public struct KeychainCredentialStore: CredentialStore {
    private let service: String
    public init(service: String = "app.rill.credentials") { self.service = service }
    private func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: id.uuidString]
    }
    public func read(_ id: UUID) throws -> String {
        var parameters = query(id)
        parameters[kSecReturnData as String] = true
        parameters[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(parameters as CFDictionary, &item)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else { throw keychainError(status) }
        return value
    }
    public func write(_ value: String, id: UUID) throws {
        let parameters = query(id)
        if value.isEmpty {
            let status = SecItemDelete(parameters as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw keychainError(status) }
            return
        }
        let data = Data(value.utf8)
        var status = SecItemUpdate(parameters as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var entry = parameters
            entry[kSecValueData as String] = data
            entry[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(entry as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw keychainError(status) }
    }
    private func keychainError(_ status: OSStatus) -> NSError {
        NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Keychain access failed (\(status)). Saving credentials has paused; your in-memory edits are retained."])
    }
}
