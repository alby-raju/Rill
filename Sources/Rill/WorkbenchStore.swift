import SwiftUI
import RillCore
import UniformTypeIdentifiers

@MainActor final class WorkbenchStore: ObservableObject {
    @Published var workspace = Workspace.starter {
        didSet {
            guard !loading, workspace.needsSave(comparedTo: oldValue) else { return }
            let previousRequest = oldValue.requests.first { $0.id == selection }
            let previousEnvironment = oldValue.environments.first { $0.id == oldValue.selectedEnvironmentID }
            if previousRequest != selected || previousEnvironment != environment {
                response = nil
                cancel()
            }
            hasUnsavedChanges = true
            persist()
        }
    }
    @Published var selection: UUID? { didSet { if oldValue != selection { response = nil; cancel() } } }
    @Published var response: Exchange?
    @Published var error: String?
    @Published var running = false
    @Published var search = ""
    @Published var showEnvironments = false
    @Published var showHistory = false
    @Published var showPalette = false
    @Published var persistenceAvailable = true
    private var task: Task<Void, Never>?
    @Published var persistenceHealth: PersistenceHealth = .loading
    @Published var loading = true
    @Published var importing = false
    @Published var closing = false
    @Published private(set) var hasUnsavedChanges = false
    private var lastFailure: DiagnosticFailure?
    private var saveTask: Task<Void, Never>?
    private var saveGeneration = UUID()
    private var activeContext: UUID?
    private let persistence: WorkspaceSession
    init() {
        let file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Rill/workspace.json")
        persistence = WorkspaceSession(url: file)
        Task {
            defer { loading = false }
            do {
                workspace = try await persistence.open()
                selection = workspace.requests.first?.id
                persistenceHealth = .saved
            } catch {
                persistenceAvailable = false
                persistenceHealth = .failed
                lastFailure = DiagnosticFailure.classify(error)
                self.error = "Could not open the workspace. Saving is paused and the existing file is preserved. \(error.localizedDescription)"
            }
        }
    }
    var saveStatus: String {
        switch persistenceHealth {
        case .loading: "Opening workspace…"
        case .saved: "All changes saved"
        case .pending: "Unsaved changes"
        case .saving: "Saving…"
        case .failed: "Save failed · edits retained in memory"
        case .conflict: "Workspace conflict · saving paused"
        }
    }
    var selected: RequestDraft? { workspace.requests.first { $0.id == selection } }
    var environment: RillCore.Environment? { workspace.environments.first { $0.id == workspace.selectedEnvironmentID } }
    func update(_ request: RequestDraft) {
        guard let index = workspace.requests.firstIndex(where: { $0.id == request.id }) else { return }
        workspace.requests[index] = request
        persist()
    }
    func persist() {
        guard !loading, persistenceAvailable, hasUnsavedChanges else { return }
        saveTask?.cancel()
        let generation = UUID()
        saveGeneration = generation
        let snapshot = workspace
        persistenceHealth = .pending
        saveTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(250))
                persistenceHealth = .saving
                try await persistence.save(snapshot)
                if saveGeneration == generation { persistenceHealth = .saved; hasUnsavedChanges = false }
            } catch is CancellationError { }
            catch {
                guard saveGeneration == generation else { return }
                lastFailure = DiagnosticFailure.classify(error)
                if (error as? WorkspaceError) == .conflict {
                    persistenceAvailable = false
                    persistenceHealth = .conflict
                } else { persistenceHealth = .failed }
                self.error = "Could not save. Your edits are retained in memory. \(error.localizedDescription)"
            }
        }
    }
    func newRequest(in collection: UUID? = nil) {
        guard !loading, !importing, !closing else { return }
        let request = RequestDraft(collectionID: collection ?? workspace.collections.first?.id)
        workspace.requests.append(request); selection = request.id; response = nil; persist()
    }
    func newCollection() {
        guard !loading, !importing, !closing else { return }
        let collection = RequestCollection(name: "New collection")
        workspace.collections.append(collection); newRequest(in: collection.id)
    }
    func duplicate(_ request: RequestDraft) {
        var copy = request; copy.id = UUID(); copy.name += " copy"
        workspace.requests.append(copy); selection = copy.id; persist()
    }
    func delete(_ request: RequestDraft) {
        workspace.requests.removeAll { $0.id == request.id }
        if selection == request.id { selection = workspace.requests.first?.id; response = nil }
        persist()
    }
    func send() {
        guard !loading, !importing, !closing, !running, let draft = selected else { return }
        let environment = environment
        let context = ExecutionContext(request: draft, environment: environment)
        activeContext = context.id
        running = true; response = nil
        task = Task {
            defer { if activeContext == context.id { running = false; task = nil; activeContext = nil } }
            do {
                let exchange = try await RequestEngine.execute(draft, environment: environment)
                try Task.checkCancellation()
                guard activeContext == context.id else { return }
                if context.matches(request: selected, environment: self.environment) { response = exchange }
                workspace.history.insert(exchange, at: 0)
                // Bound both payload memory and exchange count.
                while workspace.history.count > ResourceLimits.historyCount || workspace.history.reduce(0, { $0 + $1.body.count }) > ResourceLimits.historyBytes { workspace.history.removeLast() }
            } catch is CancellationError { }
            catch let failure as URLError where failure.code == .cancelled { }
            catch {
                guard activeContext == context.id else { return }
                lastFailure = DiagnosticFailure.classify(error)
                if context.matches(request: selected, environment: self.environment) { self.error = error.localizedDescription }
            }
        }
    }
    func cancel() {
        let wasRunning = running
        task?.cancel(); task = nil; activeContext = nil; running = false
        if wasRunning { lastFailure = .cancelled }
    }
    func flushPendingChanges() async -> Bool {
        if loading || !hasUnsavedChanges { return true }
        guard persistenceAvailable else { return false }
        saveTask?.cancel()
        saveGeneration = UUID()
        persistenceHealth = .saving
        do {
            try await persistence.save(workspace)
            persistenceHealth = .saved
            hasUnsavedChanges = false
            return true
        } catch {
            lastFailure = DiagnosticFailure.classify(error)
            persistenceHealth = (error as? WorkspaceError) == .conflict ? .conflict : .failed
            return false
        }
    }
    func exportDiagnostics() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Rill-diagnostics.json"; panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let diagnostics = SupportDiagnostics(workspace: workspace, persistence: persistenceHealth, lastFailure: lastFailure)
        Task {
            do { try await Task.detached { try diagnostics.write(to: url) }.value }
            catch { self.error = "Could not export diagnostics." }
        }
    }
    func exportWorkspace() {
        guard !loading, !importing, !closing else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Rill-workspace.json"; panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var exported = workspace; exported.history = []
        for index in exported.requests.indices { exported.requests[index].credential = "" }
        let snapshot = exported
        Task {
            do { try await Task.detached { try WorkspaceFile.save(snapshot, to: url) }.value }
            catch { lastFailure = DiagnosticFailure.classify(error); self.error = error.localizedDescription }
        }
    }
    func importWorkspace() {
        guard !loading, !importing, !closing else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importing = true
        cancel()
        Task {
            defer { importing = false }
            do {
                let incoming = try await Task.detached { try WorkspaceFile.load(from: url) }.value
                let current = workspace
                let merged = try await Task.detached { try WorkspaceImport.merging(incoming, into: current) }.value
                guard workspace == current else {
                    self.error = "The workspace changed during import. Nothing was imported; try again."
                    return
                }
                workspace = merged
            } catch {
                lastFailure = DiagnosticFailure.classify(error)
                self.error = "Import failed. The workspace has not been changed. \(error.localizedDescription)"
            }
        }
    }

}
