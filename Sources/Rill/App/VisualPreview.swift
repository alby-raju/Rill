import RillCore
import SwiftUI

/// Debug-only, synthetic visual QA. Release builds never interpret preview arguments.
@MainActor enum RillPreview {
    static var isRendering: Bool {
        #if DEBUG
            return argument("--ui-state") != nil && argument("--ui-snapshot") != nil
        #else
            return false
        #endif
    }
    private static let preferenceDomain = "app.rill.visual-preview." + UUID().uuidString
    static let preferences: UserDefaults =
        InstallationCheck.enabled
        ? InstallationCheck.preferences
        : isRendering ? UserDefaults(suiteName: preferenceDomain)! : .standard

    #if DEBUG
        private static weak var previewStore: WorkbenchStore?
    #endif
    static func makeStore() -> WorkbenchStore {
        if InstallationCheck.enabled { return InstallationCheck.makeStore() }
        #if DEBUG
            if let state = argument("--ui-state"), argument("--ui-snapshot") != nil {
                let store = WorkbenchStore(
                    preview: ["blank", "intro"].contains(state) ? "empty" : state)
                previewStore = store
                if state == "blank" {
                    store.newRequest()
                    precondition(
                        store.selected?.bodyMode == RequestBodyMode.none,
                        "Blank requests must explicitly start without a body")
                }
                return store
            }
        #endif
        return WorkbenchStore()
    }
    static var section: String {
        #if DEBUG
            if argument("--ui-snapshot") != nil {
                switch argument("--ui-state") {
                case "response-failed", "response-passed", "response-unchecked": return "Checks"
                case "body", "blank": return "Body"
                case "auth": return "Auth"
                case "workflow": return "Workflow"
                default: break
                }
            }
        #endif
        return "Parameters"
    }
    static var scheme: ColorScheme? {
        #if DEBUG
            if argument("--ui-snapshot") != nil {
                return argument("--ui-appearance") == "light" ? .light : .dark
            }
        #endif
        return nil
    }
    static func captureIfRequested() async {
        #if DEBUG
            guard let path = argument("--ui-snapshot"), argument("--ui-state") != nil else {
                return
            }
            do {
                let introduction = argument("--ui-state") == "intro"
                try await Task.sleep(for: .milliseconds(introduction ? 50 : 800))
                guard
                    let window = NSApplication.shared.windows.first(where: {
                        $0.contentView != nil && $0.isVisible
                    }), var view = window.contentView
                else { finish(1) }
                let compact = argument("--ui-width").flatMap(Double.init) ?? 1440
                window.setContentSize(NSSize(width: max(1050, compact), height: 920))
                func showSurface(_ host: NSView, size: NSSize) {
                    let panel = NSWindow(
                        contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                        backing: .buffered, defer: false)
                    panel.contentView = host
                    host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                    panel.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                    window.addChildWindow(panel, ordered: .above)
                    panel.orderFront(nil)
                }
                if let state = argument("--ui-state"), let store = previewStore {
                    if state == "environment-empty" || state == "environment-editor" {
                        if state == "environment-editor" {
                            var local = RillCore.Environment(name: "Local development")
                            local.variables = [
                                Field(name: "base_url", value: "http://localhost:8080"),
                                Field(name: "api_version", value: "v1"),
                            ]
                            store.workspace.environments = [
                                local, RillCore.Environment(name: "Staging"),
                            ]
                            store.workspace.selectedEnvironmentID = local.id
                        }
                        let host = NSHostingView(
                            rootView: EnvironmentEditor().environmentObject(store)
                                .preferredColorScheme(scheme))
                        showSurface(host, size: NSSize(width: 900, height: 590))
                        view = host
                    } else if state == "copy-request" || state == "move-request",
                        let request = store.workspace.requests.first
                    {
                        store.workspace.collections = [
                            RequestCollection(name: "Customer API"),
                            RequestCollection(name: "Archived requests"),
                        ]
                        store.workspace.requests[0].collectionID = store.workspace.collections[0].id
                        let host = NSHostingView(
                            rootView: RequestTransferSheet(
                                transfer: RequestTransfer(
                                    requestID: request.id, copy: state == "copy-request")
                            ).environmentObject(store).preferredColorScheme(scheme))
                        showSurface(host, size: NSSize(width: 510, height: 510))
                        view = host
                    }
                }
                view.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(introduction ? 30 : 300))
                if argument("--ui-state") == "collection-transfer", let store = previewStore,
                    var request = store.workspace.requests.first
                {
                    let first = RequestCollection(name: "Customer API")
                    let second = RequestCollection(name: "Archived requests")
                    store.workspace.collections = [first, second]
                    request.collectionID = first.id
                    store.workspace.requests = [request]
                    var draft = request
                    draft.body = "unsaved synthetic payload"
                    try store.editor.update(draft, savedIn: store.workspace)
                    try store.transferRequest(request.id, to: second.id, copy: false)
                    precondition(
                        store.workspace.requests[0].id == request.id
                            && store.workspace.requests[0].body == request.body)
                    precondition(
                        store.editor.request(request.id, in: store.workspace)?.body == draft.body
                            && store.editor.request(request.id, in: store.workspace)?.collectionID
                                == second.id
                    )
                    try store.transferRequest(request.id, to: first.id, copy: true)
                    guard let copy = store.workspace.requests.first(where: { $0.id != request.id })
                    else { preconditionFailure("Copy missing") }
                    precondition(copy.body == draft.body && copy.collectionID == first.id)
                    store.reorder(request.id, target: copy.id, after: false)
                    precondition(
                        store.workspace.requests.first?.id == request.id
                            && store.editor.request(request.id, in: store.workspace)?.collectionID
                                == first.id
                    )
                    print(
                        "Collection transfer: visible draft copied; move/reorder retain identity and unsaved payload"
                    )
                    view.layoutSubtreeIfNeeded()
                }
                if argument("--ui-state") == "tabs-close", let store = previewStore {
                    let start = ProcessInfo.processInfo.systemUptime
                    store.closeTabs(.all)
                    let model = ProcessInfo.processInfo.systemUptime - start
                    await Task.yield()
                    view.layoutSubtreeIfNeeded()
                    let layout = ProcessInfo.processInfo.systemUptime - start
                    try await Task.sleep(for: .milliseconds(100))
                    precondition(
                        store.editor.openTabs.isEmpty && store.selection == nil,
                        "Bulk close must remain closed after UI updates")
                    print(
                        String(
                            format: "Bulk close: model %.3f ms; model + layout %.3f ms; 100 tabs",
                            model * 1000, layout * 1000))
                }
                if argument("--ui-state") == "tabs-menu-close", let store = previewStore {
                    func findMenu(_ root: NSView) -> RequestTabMenu.MenuView? {
                        if let menu = root as? RequestTabMenu.MenuView, !menu.visibleRect.isEmpty {
                            return menu
                        }
                        return root.subviews.lazy.compactMap { findMenu($0) }.first
                    }
                    guard let menuView = findMenu(view) else {
                        preconditionFailure("Tab menu overlay missing")
                    }
                    let driver = MenuDiagnosticDriver(store: store, menuView: menuView)
                    let timer = Timer(
                        timeInterval: 0.05, target: driver,
                        selector: #selector(MenuDiagnosticDriver.step), userInfo: nil, repeats: true
                    )
                    driver.timer = timer
                    RunLoop.main.add(timer, forMode: .eventTracking)
                    menuView.openDiagnosticMenu()
                    timer.invalidate()
                    precondition(
                        driver.ticks == 30, "Menu diagnostic must exercise every live update")
                    try await Task.sleep(for: .milliseconds(100))
                    precondition(
                        store.editor.openTabs.isEmpty && store.selection == nil,
                        "Menu Close All must close every tab")
                    print(
                        "Stable tab menu: 30 live state updates, one menu build, Close All action passed (100 tabs)"
                    )
                }
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                    finish(1)
                }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                guard let data = bitmap.representation(using: .png, properties: [:]) else {
                    finish(1)
                }
                try data.write(to: URL(fileURLWithPath: path), options: .atomic)
                finish(0)
            } catch { finish(1) }
        #endif
    }
    #if DEBUG
        @MainActor private final class MenuDiagnosticDriver: NSObject {
            let store: WorkbenchStore
            let menuView: RequestTabMenu.MenuView
            var timer: Timer?
            var ticks = 0
            init(store: WorkbenchStore, menuView: RequestTabMenu.MenuView) {
                self.store = store
                self.menuView = menuView
            }
            @objc func step() {
                ticks += 1
                store.search = ticks.isMultiple(of: 2) ? "Request" : ""
                if ticks == 30 {
                    timer?.invalidate()
                    timer = nil
                    guard let menu = menuView.diagnosticMenu else {
                        preconditionFailure("Menu dismissed before diagnostic action")
                    }
                    precondition(
                        menu.numberOfItems == 6 && menuView.diagnosticBuildCount == 1,
                        "Live state updates must not rebuild the active menu")
                    menu.performActionForItem(at: 5)
                    menu.cancelTracking()
                }
            }
        }
        static func response(for request: RequestDraft, state: String) -> Exchange {
            // Exercise the real persisted response shape without exposing a production-only fixture API.
            struct Fixture: Encodable {
                let id = UUID(), date = Date()
                let requestID: UUID
                let requestName: String
                let method: HTTPMethod
                let url: String
                let status = 200
                let duration = 0.003
                let headers = [Field(name: "Content-Type", value: "application/json")]
                let body = Data(
                    #"{"id":42,"name":"Rill demo","active":true,"items":[{"id":1,"price":12.5}],"unicode":"Hello 👋 café"}"#
                        .utf8)
                let checks: [CheckResult]
            }
            let checks =
                state == "response-unchecked"
                ? []
                : [
                    CheckResult(
                        title: "Status equals \(state == "response-passed" ? 200 : 201)",
                        passed: state == "response-passed")
                ]
            let fixture = Fixture(
                requestID: request.id, requestName: request.name, method: request.method,
                url: request.url, checks: checks)
            return try! JSONDecoder().decode(Exchange.self, from: JSONEncoder().encode(fixture))
        }
        private static func finish(_ status: Int32) -> Never {
            UserDefaults.standard.removePersistentDomain(forName: preferenceDomain)
            exit(status)
        }
        private static func argument(_ name: String) -> String? {
            let args = CommandLine.arguments
            guard let index = args.firstIndex(of: name), args.indices.contains(index + 1) else {
                return nil
            }
            return args[index + 1]
        }
    #endif
}
