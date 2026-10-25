import SwiftUI
import AppKit

/// Snapshot a tab menu only when opened. SwiftUI's live menu reconciliation can
/// repeatedly rebuild an active AppKit context menu during workspace updates.
struct RequestTabMenu: NSViewRepresentable {
    enum Action: Int, Sendable { case pin, close, left, right, all }
    var pinned: Bool
    var canEdit: Bool
    var hasLeft: Bool
    var hasRight: Bool
    var perform: @MainActor (Action) -> Void

    func makeNSView(context: Context) -> MenuView { MenuView() }
    func updateNSView(_ view: MenuView, context: Context) { view.configuration = self }

    final class MenuView: NSView {
        var configuration: RequestTabMenu?
        private let target = MenuTarget()
        #if DEBUG
        private(set) var diagnosticMenu: NSMenu?
        private(set) var diagnosticBuildCount = 0
        func openDiagnosticMenu() {
            guard let window else { preconditionFailure("Diagnostic menu needs a window") }
            let location = convert(NSPoint(x: bounds.midX, y: bounds.midY), to: nil)
            let event = NSEvent.mouseEvent(with: .rightMouseDown, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            showMenu(event)
        }
        #endif
        override init(frame frameRect: NSRect) { super.init(frame: frameRect); setAccessibilityElement(false) }
        required init?(coder: NSCoder) { nil }
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent,
                  event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control)) else { return nil }
            return super.hitTest(point)
        }
        override func rightMouseDown(with event: NSEvent) { showMenu(event) }
        override func mouseDown(with event: NSEvent) {
            if event.modifierFlags.contains(.control) { showMenu(event) }
            else { super.mouseDown(with: event) }
        }
        private func showMenu(_ event: NSEvent) {
            guard let configuration else { return }
            let menu = NSMenu(); menu.autoenablesItems = false
            func add(_ title: String, _ action: Action, enabled: Bool = true) {
                let item = NSMenuItem(title: title, action: #selector(MenuTarget.choose(_:)), keyEquivalent: "")
                item.target = target; item.tag = action.rawValue; item.isEnabled = enabled
                menu.addItem(item)
            }
            add(configuration.pinned ? "Unpin" : "Pin", .pin, enabled: configuration.canEdit)
            add("Close", .close, enabled: configuration.canEdit)
            menu.addItem(.separator())
            add("Close Tabs to the Left", .left, enabled: configuration.canEdit && configuration.hasLeft)
            add("Close Tabs to the Right", .right, enabled: configuration.canEdit && configuration.hasRight)
            add("Close All Tabs", .all, enabled: configuration.canEdit)
            target.perform = configuration.perform
            #if DEBUG
            diagnosticMenu = menu; diagnosticBuildCount += 1
            defer { diagnosticMenu = nil }
            #endif
            NSMenu.popUpContextMenu(menu, with: event, for: self)

        }
    }
    @MainActor private final class MenuTarget: NSObject {
        var perform: (@MainActor (Action) -> Void)?
        @objc func choose(_ sender: NSMenuItem) {
            guard let action = Action(rawValue: sender.tag), let perform else { return }
            // Default-mode work runs only after the context-menu tracking loop
            // exits, even on OS versions that service main-queue jobs in menus.
            RunLoop.main.perform(inModes: [.default]) {
                MainActor.assumeIsolated { perform(action) }
            }
        }
    }
}
