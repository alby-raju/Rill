import SwiftUI
import RillCore
import Security
import UniformTypeIdentifiers

@MainActor final class WorkbenchStore: ObservableObject {
    @Published var workspace = Workspace.starter
    @Published var selection: UUID? { didSet { if oldValue != selection { response = nil } } }
    @Published var response: Exchange?
    @Published var error: String?
    @Published var running = false
    @Published var search = ""
    @Published var showEnvironments = false
    @Published var showHistory = false
    @Published var showPalette = false
    @Published var persistenceAvailable = true
    private var task: Task<Void, Never>?
    private let file: URL
    init() {
        file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Rill/workspace.json")
        if FileManager.default.fileExists(atPath: file.path) {
            do { workspace = try WorkspaceFile.load(from: file) }
            catch { persistenceAvailable = false; self.error = "Could not open the workspace. The existing file has been preserved. \(error.localizedDescription)" }
        }
        for index in workspace.requests.indices { workspace.requests[index].credential = Vault.read(workspace.requests[index].id) }
        selection = workspace.requests.first?.id
    }
    var selected: RequestDraft? { workspace.requests.first { $0.id == selection } }
    var environment: RillCore.Environment? { workspace.environments.first { $0.id == workspace.selectedEnvironmentID } }
    func update(_ request: RequestDraft) {
        guard let index = workspace.requests.firstIndex(where: { $0.id == request.id }) else { return }
        workspace.requests[index] = request
        persist()
    }
    func persist() {
        guard persistenceAvailable else { return }
        do {
            var disk = workspace
            disk.history = [] // Response payloads stay in this session only.
            for index in disk.requests.indices {
                let request = disk.requests[index]
                try Vault.write(request.credential, id: request.id)
                disk.requests[index].credential = ""
            }
            try WorkspaceFile.save(disk, to: file)
        } catch { self.error = "Could not save: \(error.localizedDescription)" }
    }
    func newRequest(in collection: UUID? = nil) {
        let request = RequestDraft(collectionID: collection ?? workspace.collections.first?.id)
        workspace.requests.append(request); selection = request.id; response = nil; persist()
    }
    func newCollection() {
        let collection = RequestCollection(name: "New collection")
        workspace.collections.append(collection); newRequest(in: collection.id)
    }
    func duplicate(_ request: RequestDraft) {
        var copy = request; copy.id = UUID(); copy.name += " copy"
        workspace.requests.append(copy); selection = copy.id; persist()
    }
    func delete(_ request: RequestDraft) {
        workspace.requests.removeAll { $0.id == request.id }
        try? Vault.write("", id: request.id)
        if selection == request.id { selection = workspace.requests.first?.id; response = nil }
        persist()
    }
    func send() {
        guard !running, let draft = selected else { return }
        let environment = environment
        running = true; response = nil
        task = Task {
            defer { running = false; task = nil }
            do {
                let exchange = try await RequestEngine.execute(draft, environment: environment)
                try Task.checkCancellation()
                if selection == draft.id { response = exchange }
                workspace.history.insert(exchange, at: 0)
                // Bound both payload memory and exchange count.
                while workspace.history.count > 50 || workspace.history.reduce(0, { $0 + $1.body.count }) > 32 * 1024 * 1024 { workspace.history.removeLast() }
            } catch is CancellationError { }
            catch let failure as URLError where failure.code == .cancelled { }
            catch { self.error = error.localizedDescription }
        }
    }
    func cancel() { task?.cancel() }
    func exportWorkspace() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Rill-workspace.json"; panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            var exported = workspace; exported.history = []
            for index in exported.requests.indices { exported.requests[index].credential = "" }
            try WorkspaceFile.save(exported, to: url)
        } catch { self.error = error.localizedDescription }
    }
    func importWorkspace() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let incoming = try WorkspaceFile.load(from: url)
            // Remap identities so repeated imports never alias existing items.
            var collectionMap: [UUID: UUID] = [:]
            for var collection in incoming.collections { let old = collection.id; collection.id = UUID(); collectionMap[old] = collection.id; workspace.collections.append(collection) }
            for var request in incoming.requests { request.id = UUID(); request.collectionID = request.collectionID.flatMap { collectionMap[$0] }; request.credential = ""; workspace.requests.append(request) }
            for var environment in incoming.environments { environment.id = UUID(); workspace.environments.append(environment) }
            persist()
        } catch { self.error = "Import failed: \(error.localizedDescription)" }
    }
}
private enum Vault {
    static func query(_ id: UUID) -> [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "app.rill.credentials", kSecAttrAccount as String: id.uuidString] }
    static func read(_ id: UUID) -> String {
        var parameters = query(id); parameters[kSecReturnData as String] = true; parameters[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(parameters as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
    static func write(_ value: String, id: UUID) throws {
        let parameters = query(id)
        if value.isEmpty { SecItemDelete(parameters as CFDictionary); return }
        let data = Data(value.utf8)
        var status = SecItemUpdate(parameters as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var entry = parameters; entry[kSecValueData as String] = data; entry[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(entry as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Keychain could not save a credential (\(status))."]) }
    }
}
