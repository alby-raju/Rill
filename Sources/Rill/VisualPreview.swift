import SwiftUI
import RillCore

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
    static let preferences: UserDefaults = isRendering ? UserDefaults(suiteName: preferenceDomain)! : .standard

    static func makeStore() -> WorkbenchStore {
        #if DEBUG
        if let state = argument("--ui-state"), argument("--ui-snapshot") != nil {
            let store = WorkbenchStore(preview: ["blank", "intro"].contains(state) ? "empty" : state)
            if state == "blank" {
                store.newRequest()
                precondition(store.selected?.bodyMode == RequestBodyMode.none, "Blank requests must explicitly start without a body")
            }
            return store
        }
        #endif
        return WorkbenchStore()
    }
    static var section: String {
        #if DEBUG
        if argument("--ui-snapshot") != nil {
            switch argument("--ui-state") { case "response-failed", "response-passed", "response-unchecked": return "Checks"; case "body", "blank": return "Body"; case "auth": return "Auth"; case "workflow": return "Workflow"; default: break }
        }
        #endif
        return "Parameters"
    }
    static var scheme: ColorScheme? {
        #if DEBUG
        if argument("--ui-snapshot") != nil { return argument("--ui-appearance") == "light" ? .light : .dark }
        #endif
        return nil
    }
    static func captureIfRequested() async {
        #if DEBUG
        guard let path = argument("--ui-snapshot"), argument("--ui-state") != nil else { return }
        do {
            let introduction = argument("--ui-state") == "intro"
            try await Task.sleep(for: .milliseconds(introduction ? 50 : 800))
            guard let window = NSApplication.shared.windows.first(where: { $0.contentView != nil && $0.isVisible }), let view = window.contentView else { finish(1) }
            let compact = argument("--ui-width").flatMap(Double.init) ?? 1440
            window.setContentSize(NSSize(width: max(1050, compact), height: 920))
            view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(introduction ? 30 : 300))
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { finish(1) }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else { finish(1) }
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            finish(0)
        } catch { finish(1) }
        #endif
    }
    #if DEBUG
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
            let body = Data(#"{"id":42,"name":"Rill demo","active":true,"items":[{"id":1,"price":12.5}],"unicode":"Hello 👋 café"}"#.utf8)
            let checks: [CheckResult]
        }
        let checks = state == "response-unchecked" ? [] : [CheckResult(title: "Status equals \(state == "response-passed" ? 200 : 201)", passed: state == "response-passed")]
        let fixture = Fixture(requestID: request.id, requestName: request.name, method: request.method, url: request.url, checks: checks)
        return try! JSONDecoder().decode(Exchange.self, from: JSONEncoder().encode(fixture))
    }
    private static func finish(_ status: Int32) -> Never {
        UserDefaults.standard.removePersistentDomain(forName: preferenceDomain)
        exit(status)
    }
    private static func argument(_ name: String) -> String? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: name), args.indices.contains(index + 1) else { return nil }
        return args[index + 1]
    }
    #endif
}
