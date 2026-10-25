import Foundation

public enum TabCloseScope: Sendable { case all, left, right }

public struct EditorSessionState: Codable, Equatable, Sendable {
    public var version = 1
    public var checkpointID = UUID()
    public var baseRevision: WorkspaceRevision?
    public var openTabs: [UUID] = []
    public var pinnedTabs: Set<UUID> = []
    public var activeID: UUID?
    public var closedTabs: [UUID] = []
    public var drafts: [RequestDraft] = []
    public init() {}
    public func request(_ id: UUID?, in workspace: Workspace) -> RequestDraft? {
        guard let id else { return nil }
        return drafts.first { $0.id == id } ?? workspace.requests.first { $0.id == id }
    }
    public func isDirty(_ id: UUID, in workspace: Workspace) -> Bool {
        guard let draft = drafts.first(where: { $0.id == id }) else { return false }
        return draft != workspace.requests.first { $0.id == id }
    }
    public mutating func open(_ id: UUID) throws {
        if !openTabs.contains(id) {
            guard openTabs.count < 100 else { throw EditingError.invalidSession }
            openTabs.append(id)
        }
        activeID = id
    }
    public mutating func update(_ request: RequestDraft, savedIn workspace: Workspace) throws {
        try open(request.id)
        drafts.removeAll { $0.id == request.id }
        if workspace.requests.first(where: { $0.id == request.id }) != request { drafts.append(request) }
    }
    public mutating func discard(_ id: UUID) { drafts.removeAll { $0.id == id } }
    public mutating func close(_ id: UUID, in workspace: Workspace, force: Bool = false) throws {
        guard !isDirty(id, in: workspace) else { throw EditingError.unsavedChanges }
        guard force || !pinnedTabs.contains(id) else { return }
        guard let index = openTabs.firstIndex(of: id) else { return }
        openTabs.remove(at: index); pinnedTabs.remove(id)
        closedTabs.removeAll { $0 == id }; closedTabs.append(id)
        closedTabs = Array(closedTabs.suffix(20))
        if activeID == id { activeID = openTabs.isEmpty ? nil : openTabs[min(index, openTabs.count - 1)] }
    }
    public func tabsToClose(_ scope: TabCloseScope, relativeTo anchor: UUID? = nil) -> [UUID] {
        switch scope {
        case .all: return openTabs
        case .left:
            guard let anchor, let index = openTabs.firstIndex(of: anchor) else { return [] }
            return Array(openTabs[..<index])
        case .right:
            guard let anchor, let index = openTabs.firstIndex(of: anchor) else { return [] }
            return Array(openTabs.dropFirst(index + 1))
        }
    }
    /// Explicit bulk commands include pinned tabs. Validate all drafts before mutating any tab.
    public mutating func closeTabs(_ ids: [UUID], in workspace: Workspace, discardChanges: Bool = false) throws {
        let targets = Set(ids).intersection(openTabs)
        if !discardChanges && targets.contains(where: { isDirty($0, in: workspace) }) { throw EditingError.unsavedChanges }
        var updated = self
        for id in openTabs where targets.contains(id) {
            if discardChanges { updated.discard(id) }
            try updated.close(id, in: workspace, force: true)
        }
        self = updated
    }
    public mutating func reopen(in workspace: Workspace) throws {
        while let id = closedTabs.popLast() {
            if request(id, in: workspace) != nil { try open(id); return }
        }
    }
    public mutating func remove(_ ids: Set<UUID>) {
        openTabs.removeAll { ids.contains($0) }; closedTabs.removeAll { ids.contains($0) }
        pinnedTabs.subtract(ids); drafts.removeAll { ids.contains($0.id) }
        if activeID.map({ ids.contains($0) }) ?? false { activeID = openTabs.first }
    }
    public mutating func reconcile(with workspace: Workspace) throws {
        let collections = Set(workspace.collections.map(\.id))
        for index in drafts.indices {
            if drafts[index].collectionID.map({ !collections.contains($0) }) ?? false { drafts[index].collectionID = nil }
        }
        let known = Set(workspace.requests.map(\.id) + drafts.map(\.id))
        openTabs.removeAll { !known.contains($0) }; closedTabs.removeAll { !known.contains($0) }
        pinnedTabs.formIntersection(openTabs)
        for draft in drafts where !openTabs.contains(draft.id) { try open(draft.id) }
        if activeID.map({ !openTabs.contains($0) }) ?? true { activeID = openTabs.first }
        try validate(in: workspace)
    }
    public func validate(in workspace: Workspace) throws {
        guard version == 1, openTabs.count <= 100, closedTabs.count <= 20, drafts.count <= 100,
              Set(openTabs).count == openTabs.count, Set(closedTabs).count == closedTabs.count,
              Set(drafts.map(\.id)).count == drafts.count, pinnedTabs.isSubset(of: Set(openTabs)),
              activeID.map({ openTabs.contains($0) }) ?? true else { throw EditingError.invalidSession }
        var combined = workspace
        for draft in drafts {
            if let index = combined.requests.firstIndex(where: { $0.id == draft.id }) { combined.requests[index] = draft }
            else { combined.requests.append(draft) }
        }
        try WorkspaceFile.validate(combined)
    }
}

public actor EditorSessionPersistence {
    private let url: URL
    private let credentials: any CredentialStore
    private var revision: WorkspaceRevision?
    private var credentialCache: [UUID: String] = [:]
    public init(url: URL, credentials: any CredentialStore = KeychainCredentialStore(service: "app.rill.drafts")) {
        self.url = url; self.credentials = credentials
    }
    public func open(in workspace: Workspace) throws -> EditorSessionState {
        try WorkspaceFileLock.withLock(at: url) {
            guard FileManager.default.fileExists(atPath: url.path) else {
                revision = .absent
                var fresh = EditorSessionState()
                if let id = workspace.requests.first?.id { try fresh.open(id) }
                return fresh
            }
            let data = try WorkspaceFile.readBounded(from: url)
            try WorkspaceFile.checkJSONBounds(data)
            var state = try JSONDecoder().decode(EditorSessionState.self, from: data)
            try state.reconcile(with: workspace)
            for index in state.drafts.indices {
                let id = state.drafts[index].id
                state.drafts[index].credential = try credentials.read(id)
                credentialCache[id] = state.drafts[index].credential
            }
            revision = WorkspaceRevision(data: data)
            return state
        }
    }
    public func checkpoint(_ state: EditorSessionState, workspace: Workspace, pruneCredentials: Bool = true) throws {
        try Task.checkCancellation()
        try state.validate(in: workspace)
        guard let revision else { throw WorkspaceError.unavailable }
        try WorkspaceFileLock.withLock(at: url) {
            let previous = FileManager.default.fileExists(atPath: url.path) ? try WorkspaceFile.readBounded(from: url) : nil
            guard (previous.map(WorkspaceRevision.init(data:)) ?? .absent) == revision else { throw WorkspaceError.conflict }
            var disk = state; disk.checkpointID = UUID()
            for index in disk.drafts.indices { disk.drafts[index].credential = "" }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(disk)
            guard data.count <= ResourceLimits.workspaceBytes else { throw WorkspaceError.tooLarge }
            try WorkspaceFile.atomicWrite(data, to: url)
            self.revision = WorkspaceRevision(data: data)
            for draft in state.drafts where credentialCache[draft.id] != draft.credential {
                try credentials.write(draft.credential, id: draft.id); credentialCache[draft.id] = draft.credential
            }
            let kept = Set(state.drafts.map(\.id))
            for id in Array(credentialCache.keys) where pruneCredentials && !kept.contains(id) {
                try credentials.write("", id: id); credentialCache.removeValue(forKey: id)
            }
        }
    }
    public func restore(_ state: EditorSessionState, workspace: Workspace) throws -> EditorSessionState {
        var restored = state
        try restored.reconcile(with: workspace)
        var retained: [UUID: String] = [:]
        for index in restored.drafts.indices {
            let id = restored.drafts[index].id
            restored.drafts[index].credential = try credentials.read(id)
            retained[id] = restored.drafts[index].credential
        }
        // Retire old entries from this session's cache without deleting them:
        // they may still be referenced by the pre-restore recovery backup.
        credentialCache = retained
        try checkpoint(restored, workspace: workspace, pruneCredentials: false)
        return restored
    }

}
