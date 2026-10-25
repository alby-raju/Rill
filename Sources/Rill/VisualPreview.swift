import SwiftUI
import RillCore

/// Debug-only, synthetic visual QA. Release builds never interpret preview arguments.
@MainActor enum RillPreview {
    static func makeStore() -> WorkbenchStore {
        #if DEBUG
        if let state = argument("--ui-state"), argument("--ui-snapshot") != nil {
            let store = WorkbenchStore(preview: state == "blank" ? "empty" : state)
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
            switch argument("--ui-state") { case "body", "blank": return "Body"; case "auth": return "Auth"; case "workflow": return "Workflow"; default: break }
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
            try await Task.sleep(for: .milliseconds(800))
            guard let window = NSApplication.shared.windows.first(where: { $0.contentView != nil && $0.isVisible }), let view = window.contentView else { exit(1) }
            let compact = argument("--ui-width").flatMap(Double.init) ?? 1440
            window.setContentSize(NSSize(width: max(1050, compact), height: 920))
            view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(300))
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            exit(0)
        } catch { exit(1) }
        #endif
    }
    #if DEBUG
    private static func argument(_ name: String) -> String? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: name), args.indices.contains(index + 1) else { return nil }
        return args[index + 1]
    }
    #endif
}
