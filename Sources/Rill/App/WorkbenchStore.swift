import RillCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor final class WorkbenchStore: ObservableObject {
    @Published var workspace = Workspace.starter {
        didSet {
            guard !loading, !applyingWorkspace, workspace.needsSave(comparedTo: oldValue) else {
                return
            }
            let previous = editor.request(selection, in: oldValue)
            let oldEnvironment = try? resolvedEnvironment(in: oldValue)
            if previous != selected || oldEnvironment != environment
                || workspace.authProfiles != oldValue.authProfiles
                || workspace.namedSecrets != oldValue.namedSecrets
                || workspace.tlsProfiles != oldValue.tlsProfiles
            {
                response = nil
                cancel()
            }
            hasUnsavedChanges = true
            persist()
        }
    }
    @Published var editor = EditorSessionState() {
        didSet {
            if !loading {
                checkpointNeeded = true
                checkpointGeneration = UUID()
            }
        }
    }
    @Published var selection: UUID? {
        didSet {
            guard oldValue != selection else { return }
            response = nil
            cancel()
            if !loading {
                if let selection {
                    attempt { try editor.open(selection) }
                } else {
                    editor.activeID = nil
                }
            }
        }
    }
    @Published var response: Exchange?
    @Published var error: String?
    @Published var running = false
    @Published var search = ""
    @Published var focusedCollectionID: UUID?
    @Published var inspectedHistoryID: UUID?
    @Published var responseSettings = ResponseSettings() {
        didSet {
            do { try responseSettings.validate() } catch {
                responseSettings = oldValue
                self.error = error.localizedDescription
                return
            }
            if let data = try? JSONEncoder().encode(responseSettings) {
                UserDefaults.standard.set(data, forKey: "responseSettings")
            }
            trimSessionHistory()
            if responseSettings.recordSnapshots && !oldValue.recordSnapshots {
                Task { await loadDurableHistory() }
            }
            if historyAvailable && (responseSettings.recordSnapshots || oldValue.recordSnapshots) {
                let settings = responseSettings
                Task {
                    do { try await historyArchive.apply(settings: settings) } catch {
                        historyAvailable = false
                        historyStatus = "Snapshot retention update failed; archive preserved"
                        self.error = error.localizedDescription
                    }
                }
            }
            if !responseSettings.recordSnapshots {
                historyStatus = "Durable snapshots disabled; existing archive retained"
            }
        }
    }
    @Published var historyStatus = "Durable snapshots disabled"
    private var historyAvailable = true
    @Published var oauthRunning = false
    @Published var oauthStatus = ""
    private var oauthTask: Task<Void, Never>?
    private var oauthGeneration: UUID?
    @Published var showForeignScripts = false
    @Published var showCommandImport = false
    @Published var showCommandExport = false
    @Published var showRunner = false
    @Published var showAPITools = false
    @Published var showLiveStreams = false
    @Published var showBrokers = false
    @Published var showGRPC = false
    @Published var showWorkspaceTools = false
    @Published var showHelp = false
    @Published var showTLS = false
    @Published var showAuthentication = false
    @Published var showEnvironments = false
    @Published var showHistory = false
    @Published var showPalette = false
    @Published var persistenceAvailable = true
    @Published var persistenceHealth: PersistenceHealth = .loading
    @Published var startupStatus = "Opening your workspace…"
    @Published var loading = true
    @Published var importing = false
    @Published var closing = false
    @Published private(set) var hasUnsavedChanges = false
    @Published private(set) var checkpointFailed = false
    private(set) var quitCancelled = false
    private var task: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var saveGeneration = UUID()
    private var activeContext: UUID?
    private var lastFailure: DiagnosticFailure?
    private var applyingWorkspace = false
    private var checkpointNeeded = false
    private var checkpointGeneration = UUID()
    private var checkpointAvailable = true
    private let historyArchive: ExchangeHistory
    private let secretVault = NamedSecretVault()
    private let persistence: WorkspaceSession
    private let editorPersistence: EditorSessionPersistence
    private let directory: URL
    private let visualPreview: Bool

    init(
        preview: String? = nil, storageDirectory: URL? = nil, preferences: UserDefaults = .standard
    ) {
        visualPreview = preview != nil
        directory =
            storageDirectory
            ?? (preview != nil
                ? FileManager.default.temporaryDirectory.appendingPathComponent(
                    "Rill-Preview-" + UUID().uuidString)
                : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[
                    0
                ]
                .appendingPathComponent("Rill"))
        historyArchive = ExchangeHistory(
            url: directory.appendingPathComponent("exchange-history.json"))
        if let data = preferences.data(forKey: "responseSettings"),
            let settings = try? JSONDecoder().decode(ResponseSettings.self, from: data),
            (try? settings.validate()) != nil
        {
            responseSettings = settings
        }
        persistence = WorkspaceSession(url: directory.appendingPathComponent("workspace.json"))
        editorPersistence = EditorSessionPersistence(
            url: directory.appendingPathComponent("editor-session.json"))
        #if DEBUG
            if let preview {
                workspace = Workspace()
                if preview != "empty" && preview != "loading" {
                    var request = RequestDraft()
                    request.name = "Create a customer"
                    request.method = .POST
                    request.url = "https://api.example.test/v1/customers"
                    request.bodyMode = .text
                    request.body = #"{"name":"Alex Morgan","email":"alex@example.test"}"#
                    request.auth = preview == "auth" ? .bearer : .none
                    if preview.hasPrefix("response-") {
                        request.name =
                            preview == "response-failed"
                            ? "Intentional assertion failure" : "Inspect a response"
                        request.method = .GET
                        request.bodyMode = RequestBodyMode.none
                        request.body = ""
                        request.expectedStatus =
                            preview == "response-failed"
                            ? "201" : preview == "response-passed" ? "200" : ""
                    }
                    workspace.requests = [request]
                    try? editor.open(request.id)
                    selection = request.id
                    if preview.hasPrefix("response-") {
                        response = RillPreview.response(for: request, state: preview)
                    }
                }
                if ["tabs-close", "tabs-menu-close"].contains(preview) {
                    workspace = Workspace()
                    editor = EditorSessionState()
                    for index in 1...100 {
                        var request = RequestDraft()
                        request.name = "Request \(index)"
                        request.url = "http://127.0.0.1:18990/json"
                        request.bodyMode = RequestBodyMode.none
                        workspace.requests.append(request)
                        try! editor.open(request.id)
                    }
                    selection = editor.activeID
                }
                persistenceHealth = .saved
                loading = preview == "loading"
                return
            }
        #endif
        Task {
            defer { loading = false }
            do {
                workspace = try await persistence.open()
                startupStatus = "Restoring your workspace…"
                persistenceHealth = .saved
                if responseSettings.recordSnapshots { await loadDurableHistory() }
                do {
                    startupStatus = "Restoring tabs and draft recovery…"
                    editor = try await editorPersistence.open(in: workspace)
                    if editor.drafts.contains(where: { editor.isDirty($0.id, in: workspace) }) {
                        let alert = NSAlert()
                        alert.messageText = "Recover unsaved requests?"
                        alert.informativeText =
                            "Draft checkpoints are separate from saved requests. Review recovered edits before saving, especially if another instance changed the workspace."
                        alert.addButton(withTitle: "Recover Drafts")
                        alert.addButton(withTitle: "Discard Recovered Drafts")
                        if alert.runModal() == .alertSecondButtonReturn {
                            editor.drafts.removeAll()
                            try await editorPersistence.checkpoint(editor, workspace: workspace)
                        }
                    }
                    selection = editor.activeID
                } catch {
                    checkpointAvailable = false
                    checkpointFailed = true
                    editor = EditorSessionState()
                    if let id = workspace.requests.first?.id {
                        try editor.open(id)
                        selection = id
                    }
                    self.error =
                        "The saved workspace opened, but draft recovery is unavailable. The original checkpoint is preserved. \(error.localizedDescription)"
                }
            } catch {
                persistenceAvailable = false
                persistenceHealth = .failed
                lastFailure = DiagnosticFailure.classify(error)
                self.error =
                    "Could not open the workspace. Saving is paused and the original file is preserved. \(error.localizedDescription)"
            }
        }
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                if !self.importing && !self.closing { _ = await self.checkpoint() }
            }
        }
    }
    var selected: RequestDraft? { editor.request(selection, in: workspace) }
    var environment: RillCore.Environment? { try? resolvedEnvironment(in: workspace) }
    var dirtyCount: Int { editor.drafts.filter { editor.isDirty($0.id, in: workspace) }.count }
    var canEdit: Bool { !loading && !importing && !closing && !oauthRunning }
    var saveStatus: String {
        if checkpointFailed { return "Draft checkpoint failed · edits retained in memory" }
        if dirtyCount > 0 {
            return
                "\(dirtyCount) unsaved draft\(dirtyCount == 1 ? "" : "s") · recovery checkpoints every 2s"
        }
        switch persistenceHealth {
        case .loading: return "Opening workspace…"
        case .saved: return "All changes saved"
        case .pending: return "Unsaved workspace changes"
        case .saving: return "Saving…"
        case .failed: return "Save failed · edits retained in memory"
        case .conflict: return "Workspace conflict · saving paused"
        }
    }
    private func resolvedEnvironment(in workspace: Workspace) throws -> RillCore.Environment? {
        guard let id = workspace.selectedEnvironmentID else { return nil }
        return try EnvironmentResolver.resolve(id, in: workspace.environments)
    }
    func attempt(_ operation: () throws -> Void) {
        do { try operation() } catch { self.error = error.localizedDescription }
    }
    func update(_ request: RequestDraft) {
        guard canEdit else { return }
        cancel()
        response = nil
        attempt { try editor.update(request, savedIn: workspace) }
    }
    func persist() {
        #if DEBUG
            if visualPreview {
                persistenceHealth = .saved
                hasUnsavedChanges = false
                return
            }
        #endif
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
                if saveGeneration == generation {
                    persistenceHealth = .saved
                    hasUnsavedChanges = false
                }
            } catch is CancellationError {} catch {
                guard saveGeneration == generation else { return }
                persistenceFailure(error)
            }
        }
    }
    private func persistenceFailure(_ failure: Error) {
        lastFailure = DiagnosticFailure.classify(failure)
        if (failure as? WorkspaceError) == .conflict {
            persistenceAvailable = false
            persistenceHealth = .conflict
        } else {
            persistenceHealth = .failed
        }
        error = "Could not save. In-memory edits are retained. \(failure.localizedDescription)"
    }
    private func saveWorkspaceNow() async -> Bool {
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
            persistenceFailure(error)
            return false
        }
    }
    @discardableResult func checkpoint() async -> Bool {
        guard !loading, checkpointNeeded else { return true }
        guard checkpointAvailable else { return false }
        let generation = checkpointGeneration
        var snapshot = editor
        snapshot.baseRevision = await persistence.currentRevision()
        let workspace = workspace
        do {
            try await editorPersistence.checkpoint(snapshot, workspace: workspace)
            if generation == checkpointGeneration { checkpointNeeded = false }
            checkpointFailed = false
            return true
        } catch {
            if !checkpointFailed {
                self.error =
                    "Could not checkpoint drafts. In-memory edits are retained. \(error.localizedDescription)"
            }
            checkpointFailed = true
            if (error as? WorkspaceError) == .conflict { checkpointAvailable = false }
            return false
        }
    }
    func newRequest(in collection: UUID? = nil, template: RequestTemplate? = nil) {
        guard canEdit else { return }
        let id = collection ?? focusedCollectionID ?? workspace.collections.first?.id
        var request = template?.make(in: id) ?? RequestDraft(collectionID: id)
        if template == nil { request.bodyMode = RequestBodyMode.none }
        workspace.requests.append(request)
        selection = request.id
    }
    func newCollection() {
        guard canEdit else { return }
        workspace.collections.append(RequestCollection(name: "New collection"))
    }
    func renameCollection(_ collection: RequestCollection) {
        let alert = NSAlert()
        alert.messageText = "Rename collection"
        let field = NSTextField(string: collection.name)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        attempt {
            try WorkspaceOperations.renameCollection(
                collection.id, to: field.stringValue, in: &workspace)
        }
    }
    func deleteCollection(_ collection: RequestCollection) {
        let associated = Set(
            (workspace.requests + editor.drafts).filter { $0.collectionID == collection.id }.map(
                \.id))
        let count = associated.count
        let alert = NSAlert()
        alert.messageText = "Delete \(collection.name)?"
        alert.informativeText =
            "This removes \(count) request(s), their open tabs and any associated unsaved drafts."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Delete Collection")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        attempt {
            let removed = try WorkspaceOperations.deleteCollection(collection.id, in: &workspace)
            editor.remove(removed.union(associated))
            selection = editor.activeID
        }
    }
    func duplicate(_ request: RequestDraft) {
        guard canEdit else { return }
        attempt {
            let copy = try WorkspaceOperations.copy(
                request, to: request.collectionID, in: &workspace)
            selection = copy.id
        }
    }
    func transferRequest(_ id: UUID, to collectionID: UUID?, copy: Bool) throws {
        guard canEdit, let request = editor.request(id, in: workspace) else {
            throw EditingError.missingItem
        }
        if copy {
            let duplicate = try WorkspaceOperations.copy(request, to: collectionID, in: &workspace)
            selection = duplicate.id
        } else {
            if workspace.requests.contains(where: { $0.id == id }) {
                try WorkspaceOperations.relocate(id, to: collectionID, in: &workspace)
            }
            if let index = editor.drafts.firstIndex(where: { $0.id == id }) {
                editor.drafts[index].collectionID = collectionID
            }
        }
        focusedCollectionID = collectionID
        persist()
    }
    func delete(_ request: RequestDraft) {
        let alert = NSAlert()
        alert.messageText = "Delete \(request.name)?"
        alert.informativeText = "The saved request and its unsaved draft will be removed."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Delete Request")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        workspace.requests.removeAll { $0.id == request.id }
        editor.remove([request.id])
        selection = editor.activeID
    }
    func reorder(_ id: UUID, target: UUID, after: Bool) {
        guard canEdit else { return }
        attempt {
            try WorkspaceOperations.place(id, before: target, after: after, in: &workspace)
            if let index = editor.drafts.firstIndex(where: { $0.id == id }) {
                editor.drafts[index].collectionID =
                    workspace.requests.first(where: { $0.id == id })?.collectionID
            }
        }
    }
    func reorderSelected(_ offset: Int) {
        if let selection {
            attempt { try WorkspaceOperations.move(selection, offset: offset, in: &workspace) }
        }
    }
    func togglePin(_ id: UUID) {
        if editor.pinnedTabs.contains(id) {
            editor.pinnedTabs.remove(id)
        } else {
            editor.pinnedTabs.insert(id)
        }
    }
    func closeTab(_ id: UUID, force: Bool = false) {
        guard force || !editor.pinnedTabs.contains(id) else { return }
        if editor.isDirty(id, in: workspace) {
            let alert = NSAlert()
            alert.messageText = "Save changes before closing?"
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Discard")
            alert.addButton(withTitle: "Save")
            switch alert.runModal() {
            case .alertSecondButtonReturn: editor.discard(id)
            case .alertThirdButtonReturn:
                Task { if await saveDrafts([id]) { closeTab(id, force: force) } }
                return
            default: return
            }
        }
        attempt {
            try editor.close(id, in: workspace, force: force)
            selection = editor.activeID
        }
    }
    func closeTabs(_ scope: TabCloseScope, relativeTo anchor: UUID? = nil) {
        guard canEdit else { return }
        let targets = editor.tabsToClose(scope, relativeTo: anchor)
        guard !targets.isEmpty else { return }
        let dirty = targets.filter { editor.isDirty($0, in: workspace) }
        if !dirty.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Save changes before closing \(targets.count) tabs?"
            alert.informativeText =
                "\(dirty.count) tab(s) have unsaved changes. Cancel keeps every tab open. Saved requests remain in their collections."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Discard Changes")
            alert.addButton(withTitle: "Save All")
            switch alert.runModal() {
            case .alertSecondButtonReturn:
                attempt {
                    try editor.closeTabs(targets, in: workspace, discardChanges: true)
                    selection = editor.activeID
                }
            case .alertThirdButtonReturn:
                Task {
                    if await saveDrafts(Set(dirty)) {
                        attempt {
                            try editor.closeTabs(targets, in: workspace)
                            selection = editor.activeID
                        }
                    }
                }
            default: break
            }
            return
        }
        attempt {
            try editor.closeTabs(targets, in: workspace)
            selection = editor.activeID
        }
    }
    func reopenTab() {
        attempt {
            try editor.reopen(in: workspace)
            selection = editor.activeID
        }
    }
    func saveSelected() { if let selection, canEdit { Task { _ = await saveDrafts([selection]) } } }
    private func saveDrafts(_ ids: Set<UUID>) async -> Bool {
        guard persistenceAvailable else { return false }
        let drafts = editor.drafts.filter { ids.contains($0.id) }
        if drafts.isEmpty { return true }
        importing = true
        cancel()
        saveTask?.cancel()
        saveGeneration = UUID()
        defer { importing = false }
        var updated = workspace
        for draft in drafts {
            if let index = updated.requests.firstIndex(where: { $0.id == draft.id }) {
                updated.requests[index] = draft
            } else {
                updated.requests.append(draft)
            }
        }
        do {
            try await persistence.save(updated)
            applyingWorkspace = true
            workspace = updated
            applyingWorkspace = false
            persistenceHealth = .saved
            hasUnsavedChanges = false
            for id in ids { editor.discard(id) }
            _ = await checkpoint()
            return true
        } catch {
            persistenceFailure(error)
            return false
        }
    }
    func flushPendingChanges() async -> Bool {
        quitCancelled = false
        if loading { return true }
        if dirtyCount > 0 {
            let alert = NSAlert()
            alert.messageText = "Save unsaved request drafts?"
            alert.informativeText =
                "Recovery checkpoints do not replace explicitly saving requests."
            alert.addButton(withTitle: "Cancel Quit")
            alert.addButton(withTitle: "Discard Drafts")
            alert.addButton(withTitle: "Save All")
            switch alert.runModal() {
            case .alertSecondButtonReturn: editor.drafts.removeAll()
            case .alertThirdButtonReturn:
                if !(await saveDrafts(Set(editor.drafts.map(\.id)))) { return false }
            default:
                quitCancelled = true
                return false
            }
        }
        guard await saveWorkspaceNow() else { return false }
        return await checkpoint()
    }
    func send() {
        guard canEdit, !running, let draft = selected else { return }
        let environment: RillCore.Environment?
        do { environment = try resolvedEnvironment(in: workspace) } catch {
            self.error = error.localizedDescription
            return
        }
        let tlsProfiles = workspace.tlsProfiles ?? []
        do {
            if let profile = try TLSProfiles.selected(draft.tlsProfileID, from: tlsProfiles),
                profile.mode == .insecure
            {
                let alert = NSAlert()
                alert.messageText = "Send with insecure TLS?"
                alert.informativeText =
                    "Profile \(profile.name) disables certificate and hostname verification for this request."
                alert.addButton(withTitle: "Cancel")
                alert.addButton(withTitle: "Send with Insecure TLS")
                guard alert.runModal() == .alertSecondButtonReturn else { return }
            }
        } catch {
            self.error = error.localizedDescription
            return
        }
        let settings = responseSettings
        let profiles = workspace.authProfiles ?? []
        let definitions = workspace.apiDefinitions ?? []
        let secrets = NamedSecretResolver(catalog: workspace.namedSecrets ?? [])
        let context = ExecutionContext(request: draft, environment: environment)
        activeContext = context.id
        running = true
        response = nil
        task = Task {
            defer {
                if activeContext == context.id {
                    running = false
                    task = nil
                    activeContext = nil
                }
            }
            do {
                let result = try await WorkflowEngine.execute(
                    draft, variables: WorkflowEngine.variables(in: environment),
                    budget: try ResponseBudget(
                        downloadBytes: settings.downloadBytes, previewBytes: settings.previewBytes),
                    profiles: profiles, secrets: secrets, tlsProfiles: tlsProfiles,
                    definitions: definitions)
                let exchange = result.exchange
                try Task.checkCancellation()
                guard activeContext == context.id else { return }
                if context.matches(request: selected, environment: self.environment) {
                    response = exchange
                }
                workspace.history.insert(exchange, at: 0)
                trimSessionHistory()
                if responseSettings.recordSnapshots && historyAvailable {
                    do {
                        try await historyArchive.record(exchange, settings: responseSettings)
                        historyStatus = "Durable snapshots enabled"
                    } catch {
                        historyAvailable = false
                        historyStatus = "Snapshot save failed; archive preserved"
                        self.error =
                            "Could not save response snapshot. \(error.localizedDescription)"
                    }
                }
            } catch is CancellationError {} catch let failure as URLError
                where failure.code == .cancelled
            {} catch {
                guard activeContext == context.id else { return }
                lastFailure = DiagnosticFailure.classify(error)
                if context.matches(request: selected, environment: self.environment) {
                    self.error = error.localizedDescription
                }
            }
        }
    }
    func cancel() {
        let wasRunning = running
        task?.cancel()
        task = nil
        activeContext = nil
        running = false
        if wasRunning { lastFailure = .cancelled }
    }
    private func trimSessionHistory() {
        while workspace.history.count > responseSettings.sessionCount
            || workspace.history.reduce(0, { $0 + $1.body.count }) > responseSettings.sessionBytes
        { workspace.history.removeLast() }
    }
    private func loadDurableHistory() async {
        guard historyAvailable else { return }
        do {
            let saved = try await historyArchive.open()
            guard responseSettings.recordSnapshots else { return }
            let existing = Set(workspace.history.map(\.id))
            workspace.history += saved.filter { !existing.contains($0.id) }
            workspace.history.sort { $0.date > $1.date }
            trimSessionHistory()
            historyStatus = "Durable snapshots enabled"
        } catch {
            historyAvailable = false
            historyStatus = "Snapshot archive unavailable; original preserved"
            self.error = "Could not open response snapshots. \(error.localizedDescription)"
        }
    }
    func clearHistory() {
        let alert = NSAlert()
        alert.messageText = "Clear response history?"
        alert.informativeText =
            "This clears the session and persisted snapshot archive. Current response inspection remains available."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Clear History")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        Task {
            do {
                try await historyArchive.clear()
                workspace.history = []
                inspectedHistoryID = nil
                historyStatus =
                    responseSettings.recordSnapshots
                    ? "Durable snapshots enabled" : "Durable snapshots disabled"
            } catch {
                self.error =
                    "Could not clear snapshots; the original archive is preserved. \(error.localizedDescription)"
            }
        }
    }
    func cancelOAuth() {
        oauthTask?.cancel()
        oauthTask = nil
        oauthGeneration = nil
        oauthRunning = false
        oauthStatus = "Authorization cancelled"
    }
    func acquireOAuth(profileID: UUID, browser: Bool) {
        guard canEdit, persistenceAvailable,
            let profile = workspace.authProfiles?.first(where: { $0.id == profileID }),
            let configuration = profile.oauth
        else { return }
        do {
            let tokenKey = try NamedSecretResolver.environmentKey(for: profile.secretName)
            guard
                !(workspace.namedSecrets ?? []).contains(where: {
                    $0.name != profile.secretName
                        && (try? NamedSecretResolver.environmentKey(for: $0.name)) == tokenKey
                })
            else { throw OAuthError.invalidConfiguration }
            if configuration.clientAuthentication != .none,
                try NamedSecretResolver.environmentKey(for: configuration.clientSecretName)
                    == tokenKey
            {
                throw OAuthError.invalidConfiguration
            }
        } catch {
            self.error = error.localizedDescription
            return
        }
        let secrets = NamedSecretResolver(catalog: workspace.namedSecrets ?? [])
        let generation = UUID()
        oauthGeneration = generation
        oauthRunning = true
        cancel()
        oauthStatus =
            browser
            ? "Waiting for browser authorization (3 minute limit)…" : "Requesting access token…"
        oauthTask = Task {
            do {
                let token: OAuthToken
                if browser {
                    let pkce = try PKCEChallenge()
                    let callback = OAuthCallbackReceiver(expectedState: pkce.state)
                    do {
                        let redirect = try await callback.start()
                        let address = try OAuthClient.authorizationURL(
                            configuration: configuration, redirect: redirect, pkce: pkce)
                        try Task.checkCancellation()
                        guard NSWorkspace.shared.open(address) else {
                            throw OAuthError.invalidConfiguration
                        }
                        let code = try await callback.waitForCode()
                        token = try await OAuthClient.acquire(
                            configuration: configuration, secrets: secrets, code: code,
                            redirect: redirect, verifier: pkce.verifier)
                        await callback.stop()
                    } catch {
                        await callback.stop()
                        throw error
                    }
                } else {
                    token = try await OAuthClient.acquire(
                        configuration: configuration, secrets: secrets)
                }
                try Task.checkCancellation()
                guard oauthGeneration == generation,
                    let index = workspace.authProfiles?.firstIndex(where: { $0.id == profileID }),
                    workspace.authProfiles?[index] == profile
                else { throw OAuthError.invalidConfiguration }
                let secret =
                    (workspace.namedSecrets ?? []).first { $0.name == profile.secretName }
                    ?? NamedSecret(name: profile.secretName)
                // Persist the token only to Keychain; metadata below contains no token bytes.
                try await secretVault.set(token.accessToken, for: secret)
                try Task.checkCancellation()
                if !(workspace.namedSecrets ?? []).contains(where: { $0.id == secret.id }) {
                    if workspace.namedSecrets == nil { workspace.namedSecrets = [] }
                    workspace.namedSecrets?.append(secret)
                }
                workspace.authProfiles?[index].kind = .bearer
                workspace.authProfiles?[index].tokenExpiresAt = token.expiresAt
                oauthStatus =
                    "Token stored in native Keychain"
                    + (token.expiresAt == nil
                        ? " (provider supplied no expiry)" : " with provider expiry")
            } catch is CancellationError {
                if oauthGeneration == generation { oauthStatus = "Authorization cancelled" }
            } catch let error as URLError where error.code == .cancelled {
                if oauthGeneration == generation { oauthStatus = "Authorization cancelled" }
            } catch {
                if oauthGeneration == generation {
                    self.error = "OAuth did not complete. \(error.localizedDescription)"
                    oauthStatus = "Authorization failed"
                }
            }
            if oauthGeneration == generation {
                oauthRunning = false
                oauthTask = nil
                oauthGeneration = nil
            }
        }
    }
    func setNamedSecret(name: String, value: String, replacing id: UUID? = nil) {
        guard canEdit, persistenceAvailable else { return }
        let secret = (workspace.namedSecrets ?? []).first { $0.id == id } ?? NamedSecret(name: name)
        do {
            let key = try NamedSecretResolver.environmentKey(for: secret.name)
            guard
                !(workspace.namedSecrets ?? []).contains(where: {
                    $0.id != secret.id
                        && (try? NamedSecretResolver.environmentKey(for: $0.name)) == key
                })
            else { throw WorkspaceError.invalidStructure }
        } catch {
            self.error = error.localizedDescription
            return
        }
        importing = true
        cancel()
        Task {
            defer { importing = false }
            do {
                try await secretVault.set(value, for: secret)
                if !(workspace.namedSecrets ?? []).contains(where: { $0.id == secret.id }) {
                    if workspace.namedSecrets == nil { workspace.namedSecrets = [] }
                    workspace.namedSecrets?.append(secret)
                }
            } catch { self.error = error.localizedDescription }
        }
    }
    func deleteNamedSecret(_ secret: NamedSecret) {
        guard canEdit, persistenceAvailable else { return }
        let alert = NSAlert()
        alert.messageText = "Delete native secret \(secret.name)?"
        alert.informativeText =
            "Profiles and templates retain their references. They will fail if no secret is available. A matching RILL_SECRET_ process value becomes eligible after native metadata is removed."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Delete")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        importing = true
        cancel()
        Task {
            defer { importing = false }
            do {
                try await secretVault.delete(secret)
                workspace.namedSecrets?.removeAll { $0.id == secret.id }
            } catch { self.error = error.localizedDescription }
        }
    }
    func searchResults(_ query: String) -> [WorkspaceSearchResult] {
        var effective = workspace
        for draft in editor.drafts {
            if let index = effective.requests.firstIndex(where: { $0.id == draft.id }) {
                effective.requests[index] = draft
            } else {
                effective.requests.append(draft)
            }
        }
        return WorkspaceSearch.results(query, in: effective)
    }
    func activateSearch(_ result: WorkspaceSearchResult) {
        switch result.kind {
        case .request: selection = result.targetID
        case .collection:
            search = ""
            focusedCollectionID = result.targetID
            selection = workspace.requests.first { $0.collectionID == result.targetID }?.id
        case .environment:
            workspace.selectedEnvironmentID = result.targetID
            showEnvironments = true
        case .history:
            inspectedHistoryID = result.targetID
            showHistory = true
        }
    }
    func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Rill-diagnostics.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let diagnostics = SupportDiagnostics(
            workspace: workspace, persistence: persistenceHealth, lastFailure: lastFailure)
        Task {
            do { try await Task.detached { try diagnostics.write(to: url) }.value } catch {
                self.error = "Could not export diagnostics."
            }
        }
    }
    func exportWorkspace() {
        guard canEdit else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Rill-workspace.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var snapshot = workspace
        snapshot.history = []
        for index in snapshot.requests.indices { snapshot.requests[index].credential = "" }
        let exported = snapshot
        Task {
            do { try await Task.detached { try WorkspaceFile.save(exported, to: url) }.value } catch
            { self.error = error.localizedDescription }
        }
    }
    func importWorkspace() {
        guard canEdit, persistenceAvailable else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importing = true
        cancel()
        saveTask?.cancel()
        saveGeneration = UUID()
        Task {
            defer { importing = false }
            do {
                guard await saveWorkspaceNow() else { return }
                let current = workspace
                let plan = try await Task.detached {
                    try WorkspaceImportPlan(
                        incoming: WorkspaceFile.load(from: url), current: current)
                }.value
                let preview = plan.preview
                let alert = NSAlert()
                alert.messageText = "Import Rill workspace?"
                alert.informativeText =
                    "Add \(preview.collections) collection(s), \(preview.requests) request(s), \(preview.environments) environment(s), \(preview.profiles) auth profile(s), \(preview.tlsProfiles) TLS profile(s) and \(preview.secretDescriptors) secret descriptor(s).\n\n"
                    + preview.warnings.joined(separator: "\n\n")
                if !preview.requestNames.isEmpty {
                    let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 430, height: 120))
                    text.isEditable = false
                    text.string =
                        preview.requestNames.joined(separator: "\n")
                        + (preview.requests > preview.requestNames.count ? "\n…" : "")
                    let scroll = NSScrollView(frame: text.frame)
                    scroll.documentView = text
                    scroll.hasVerticalScroller = true
                    alert.accessoryView = scroll
                }
                alert.addButton(withTitle: "Cancel")
                alert.addButton(withTitle: "Apply Import")
                guard alert.runModal() == .alertSecondButtonReturn else { return }
                let merged = try await persistence.applyImport(plan, current: workspace)
                applyingWorkspace = true
                workspace = merged
                applyingWorkspace = false
                hasUnsavedChanges = false
                persistenceHealth = .saved
            } catch {
                self.error =
                    "Import failed without applying incoming changes. \(error.localizedDescription)"
                if (error as? WorkspaceError) == .conflict {
                    persistenceAvailable = false
                    persistenceHealth = .conflict
                }
            }
        }
    }
    func exportInterchange(_ target: String) {
        guard canEdit else { return }
        let alert = NSAlert()
        alert.messageText = "Export " + target + "?"
        alert.informativeText =
            "URLs, bodies, file paths and unmarked variables may contain secrets. Postman and Insomnia export saved requests; Insomnia includes the selected environment. Foreign scripts are omitted to avoid enabling them in another app; Bruno exports a ZIP bundle with plain environments and omits scripts; form/file-body exports fail explicitly. Native secret references need local configuration. HAR exports the current draft without sending it, with an explicitly unexecuted response placeholder. Masked HAR also redacts query values and nonessential headers. File references are exported as metadata only; unsupported profiles or bodies fail before writing."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Export Masked")
        alert.addButton(withTitle: "Include Auth Values")
        let choice = alert.runModal()
        guard choice != .alertFirstButtonReturn else { return }
        let include = choice == .alertThirdButtonReturn
        let panel = NSSavePanel()
        panel.nameFieldStringValue =
            "Rill-" + target
            + (target == "HAR"
                ? ".har"
                : (target == "Insomnia collection"
                    ? ".yaml" : (target == "Bruno bundle" ? ".zip" : ".json")))
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let snapshot = workspace
        let request = selected
        let environment = environment
        let resolver = NamedSecretResolver(catalog: snapshot.namedSecrets ?? [])
        Task {
            do {
                try await Task.detached {
                    let data: Data
                    switch target {
                    case "Bruno bundle":
                        data = try BrunoExporter.bundle(snapshot, includeCredentials: include)
                    case "Insomnia collection":
                        data = try InsomniaExporter.collection(
                            snapshot, environment: environment, includeCredentials: include)
                    case "Postman collection":
                        data = try PostmanExporter.collection(snapshot, includeCredentials: include)
                    case "Postman environment":
                        guard let environment else { throw ForeignExportError.unsupported }
                        data = try PostmanExporter.environment(environment)
                    default:
                        guard let request else { throw ForeignExportError.unsupported }
                        data = try HARExporter.request(
                            request, environment: environment, includeCredentials: include,
                            profiles: snapshot.authProfiles ?? [], secrets: resolver)
                    }
                    if target == "Bruno bundle" {
                        try BrunoExportFile.write(data, to: url)
                    } else if target == "Insomnia collection" {
                        try InsomniaExportFile.write(data, to: url)
                    } else {
                        try ForeignExportFile.write(data, to: url)
                    }
                }.value
            } catch { self.error = "Export did not complete. " + error.localizedDescription }
        }
    }
    func applyAPIDefinition(_ definition: APIDefinition, refreshing id: UUID?) async -> Bool {
        guard canEdit, persistenceAvailable else { return false }
        importing = true
        cancel()
        saveTask?.cancel()
        saveGeneration = UUID()
        defer { importing = false }
        guard await saveWorkspaceNow() else { return false }
        do {
            let current = workspace
            let plan = try await Task.detached {
                try APIImportPlan(definition, current: current, refreshing: id)
            }.value
            let alert = NSAlert()
            alert.messageText = id == nil ? "Import API definition?" : "Apply definition refresh?"
            let counts = Dictionary(grouping: plan.changes, by: \.state).map {
                "\($0.key.rawValue): \($0.value.count)"
            }.sorted().joined(separator: " · ")
            alert.informativeText =
                counts
                + "\n\nLocally edited requests are preserved. Removed locally edited requests are retained unlinked. Source snapshots/examples stay plain text."
            let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 570, height: 280))
            text.isEditable = false
            let changeLines: [String] = plan.changes.prefix(300).map { change in
                "\(change.state.rawValue) · \(String(change.key.prefix(300)))"
            }
            let warningLines = plan.warnings.prefix(30).map { String($0.prefix(500)) }
            text.string =
                changeLines.joined(separator: "\n") + "\n\n" + warningLines.joined(separator: "\n")
            let scroll = NSScrollView(frame: text.frame)
            scroll.documentView = text
            scroll.hasVerticalScroller = true
            alert.accessoryView = scroll
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Apply")
            guard alert.runModal() == .alertSecondButtonReturn else { return false }
            let updated = try await persistence.applyAPIPlan(plan, current: workspace)
            applyingWorkspace = true
            workspace = updated
            applyingWorkspace = false
            hasUnsavedChanges = false
            persistenceHealth = .saved
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }
    func importForeign(_ format: ForeignImportFormat) {
        guard canEdit, persistenceAvailable else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = format == .bruno
        panel.allowedContentTypes =
            format == .bruno
            ? [UTType(filenameExtension: "bru") ?? .plainText, .zip, .json]
            : (format == .insomnia ? [.json, .yaml] : [.json])
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importing = true
        cancel()
        saveTask?.cancel()
        saveGeneration = UUID()
        Task {
            defer { importing = false }
            do {
                guard await saveWorkspaceNow() else { return }
                let current = workspace
                let plan = try await Task.detached {
                    try ForeignImportPlan(format.load(from: url), current: current)
                }.value
                let preview = plan.preview
                let alert = NSAlert()
                alert.messageText = "Import " + format.rawValue + "?"
                alert.informativeText =
                    "Add \(preview.collections) collection(s), \(preview.requests) request(s), \(preview.environments) environment(s) and \(preview.secretDescriptors) secret descriptor(s).\n\n"
                    + preview.warnings.joined(separator: "\n\n")
                let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 460, height: 160))
                text.isEditable = false
                text.string = preview.requestNames.joined(separator: "\n")
                let scroll = NSScrollView(frame: text.frame)
                scroll.documentView = text
                scroll.hasVerticalScroller = true
                alert.accessoryView = scroll
                alert.addButton(withTitle: "Cancel")
                alert.addButton(withTitle: "Apply Import")
                guard alert.runModal() == .alertSecondButtonReturn else { return }
                let updated = try await persistence.applyForeignImport(plan, current: workspace)
                applyingWorkspace = true
                workspace = updated
                applyingWorkspace = false
                hasUnsavedChanges = false
                persistenceHealth = .saved
            } catch {
                self.error = "Foreign import did not complete. \(error.localizedDescription)"
                if (error as? WorkspaceError) == .conflict {
                    persistenceAvailable = false
                    persistenceHealth = .conflict
                }
            }
        }
    }
    func importCommand(_ result: CommandImport) async -> Bool {
        guard canEdit, persistenceAvailable else { return false }
        importing = true
        cancel()
        saveTask?.cancel()
        saveGeneration = UUID()
        defer { importing = false }
        guard await saveWorkspaceNow() else { return false }
        do {
            var request = result.request
            request.collectionID = focusedCollectionID ?? workspace.collections.first?.id
            let imported = try await persistence.importRequest(request, current: workspace)
            applyingWorkspace = true
            workspace = imported.workspace
            applyingWorkspace = false
            hasUnsavedChanges = false
            persistenceHealth = .saved
            selection = imported.requestID
            return true
        } catch {
            self.error = "Request import did not complete. \(error.localizedDescription)"
            if (error as? WorkspaceError) == .conflict {
                persistenceAvailable = false
                persistenceHealth = .conflict
            }
            return false
        }
    }
    func createBackup() {
        guard canEdit else { return }
        let alert = NSAlert()
        alert.messageText = "Create workspace backup"
        alert.informativeText =
            "Auth passwords and tokens are omitted. URLs, headers, bodies, environment values and foreign script text remain as entered and may contain sensitive data."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Workspace Only")
        alert.addButton(withTitle: "Include Drafts")
        let choice = alert.runModal()
        guard choice != .alertFirstButtonReturn else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Rill-workspace.rillbackup"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let snapshot = workspace
        let session = choice == .alertThirdButtonReturn ? editor : nil
        Task {
            do {
                try await Task.detached {
                    try WorkspaceBackup.write(workspace: snapshot, editor: session, to: url)
                }.value
            } catch { self.error = error.localizedDescription }
        }
    }
    func restoreBackup() {
        guard canEdit else { return }
        let panel = NSOpenPanel()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importing = true
        cancel()
        saveTask?.cancel()
        saveGeneration = UUID()
        Task {
            defer { importing = false }
            var restoreAttempted = false
            do {
                let contents = try await Task.detached { try WorkspaceBackup.load(from: url) }.value
                let alert = NSAlert()
                alert.messageText = "Replace this workspace?"
                alert.informativeText =
                    "Restore \(contents.workspace.collections.count) collection(s), \(contents.workspace.requests.count) request(s) and \(contents.editor?.drafts.count ?? 0) draft(s). Current editors will be replaced. A pre-restore backup will be retained locally. Auth secrets are not in this backup; matching local Keychain entries are retained."
                alert.addButton(withTitle: "Cancel")
                alert.addButton(withTitle: "Restore Backup")
                guard alert.runModal() == .alertSecondButtonReturn else {
                    persist()
                    return
                }
                guard await saveWorkspaceNow() else { return }
                let previous = directory.appendingPathComponent(
                    "backups/before-restore-\(UUID().uuidString).rillbackup")
                restoreAttempted = true
                let restored = try await persistence.restore(
                    contents, retainingPreviousAt: previous, editor: editor)
                applyingWorkspace = true
                workspace = restored
                applyingWorkspace = false
                persistenceHealth = .saved
                hasUnsavedChanges = false
                var fresh = contents.editor ?? EditorSessionState()
                try fresh.reconcile(with: restored)
                editor = fresh
                selection = fresh.activeID
                do {
                    editor = try await editorPersistence.restore(fresh, workspace: restored)
                    checkpointNeeded = false
                } catch {
                    persistenceAvailable = false
                    checkpointAvailable = false
                    checkpointFailed = true
                    self.error =
                        "Workspace restored, but session recovery could not be updated. The prior checkpoint and pre-restore backup are preserved."
                }
            } catch {
                if restoreAttempted {
                    persistenceAvailable = false
                    checkpointAvailable = false
                    persistenceHealth = .failed
                }
                self.error =
                    "Restore did not complete. Original or pre-restore data is retained. Reopen Rill before retrying if saving is paused. \(error.localizedDescription)"
            }
        }
    }
}
