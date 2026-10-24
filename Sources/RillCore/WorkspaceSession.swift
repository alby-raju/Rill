import Foundation
import Security

/// All workspace and Keychain I/O runs on this actor, away from the UI executor.
public actor WorkspaceSession {
    private let repository: WorkspaceRepository
    private var revision: WorkspaceRevision?
    private var credentials: [UUID: String] = [:]
    private let credentialStore: any CredentialStore

    public init(url: URL, credentials: any CredentialStore = KeychainCredentialStore()) {
        repository = WorkspaceRepository(url: url)
        credentialStore = credentials
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
}

public protocol CredentialStore: Sendable {
    func read(_ id: UUID) throws -> String
    func write(_ value: String, id: UUID) throws
}

public struct KeychainCredentialStore: CredentialStore {
    public init() {}
    private func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "app.rill.credentials",
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
