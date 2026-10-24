import SwiftUI

// Explicit type alias avoids macro/type name ambiguity in newer SDKs.
typealias ViewState<Value> = SwiftUI.State<Value>

@main struct RillApp: App {
    @NSApplicationDelegateAdaptor(RillAppDelegate.self) private var delegate
    @StateObject private var store = WorkbenchStore()
    @AppStorage("appearance") private var appearance = "system"
    var body: some Scene {
        WindowGroup {
            WorkbenchView().environmentObject(store)
                .onAppear { delegate.store = store }
                .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
                .frame(minWidth: 1050, minHeight: 700)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 920)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Request") { store.newRequest() }.keyboardShortcut("n")
                Button("New Collection") { store.newCollection() }.keyboardShortcut("n", modifiers: [.command, .shift])
                Divider()
                Button("Import cURL / HTTPie / HAR…") { store.showCommandImport = true }
                Button("Import Postman JSON…") { store.importForeign(.postman) }
                Button("Import HTTPie Desktop JSON…") { store.importForeign(.httpieDesktop) }
                Button("Import Rill Workspace…") { store.importWorkspace() }
                Button("Export Postman Collection…") { store.exportInterchange("Postman collection") }
                Button("Export Postman Environment…") { store.exportInterchange("Postman environment") }.disabled(store.environment == nil)
                Button("Export HAR Request…") { store.exportInterchange("HAR") }.disabled(store.selected == nil)
                Button("Export Rill Workspace…") { store.exportWorkspace() }
                Button("Export Support Diagnostics…") { store.exportDiagnostics() }
                Divider()
                Button("Create Backup…") { store.createBackup() }
                Button("Restore Backup…") { store.restoreBackup() }
            }
            CommandGroup(replacing: .saveItem) { Button("Save Request") { store.saveSelected() }.keyboardShortcut("s") }
            CommandMenu("Request") {
                Button("New Request Tab") { store.newRequest() }.keyboardShortcut("t")
                Button("Close Request Tab") { if let id = store.selection { store.closeTab(id) } }.keyboardShortcut("w")
                Button("Reopen Closed Tab") { store.reopenTab() }.keyboardShortcut("t", modifiers: [.command, .shift])
                Button("Move Request Earlier") { store.reorderSelected(-1) }.keyboardShortcut(.upArrow, modifiers: .option)
                Button("Move Request Later") { store.reorderSelected(1) }.keyboardShortcut(.downArrow, modifiers: .option)
                Divider()
                Button("Generate Command…") { store.showCommandExport = true }.disabled(store.selection == nil)
                Button("Send Request") { store.send() }.keyboardShortcut(.return, modifiers: .command).disabled(store.running || store.loading)
                Button("Cancel Request") { store.cancel() }.keyboardShortcut(".")
                Button("Find Request") { store.showPalette = true }.keyboardShortcut("k")
                Button("TLS Profiles") { store.showTLS = true }
                Button("Authentication and Secrets") { store.showAuthentication = true }
                Button("Environments") { store.showEnvironments = true }.keyboardShortcut("e", modifiers: [.command, .shift])
            }
        }
        Settings {
            Form {
                Picker("Appearance", selection: $appearance) { Text("System").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark") }
                Text("Authentication tokens and passwords are stored in macOS Keychain. Headers, bodies, URLs and environment values are stored locally as entered. Response history is session-only unless you explicitly enable durable snapshots below.")
                    .font(.callout).foregroundStyle(.secondary)
                ResponseSettingsView().environmentObject(store)
            }.padding(24).frame(width: 650, height: 650)
        }
    }
}

@MainActor final class RillAppDelegate: NSObject, NSApplicationDelegate {
    weak var store: WorkbenchStore?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store else { return .terminateNow }
        guard !store.importing else { store.error = "Wait for the workspace operation to finish before quitting."; return .terminateCancel }
        store.cancelOAuth()
        store.closing = true
        store.cancel()
        Task {
            let saved = await store.flushPendingChanges()
            if saved { sender.reply(toApplicationShouldTerminate: true); return }
            if store.quitCancelled { store.closing = false; sender.reply(toApplicationShouldTerminate: false); return }
            let alert = NSAlert()
            alert.messageText = "Some changes have not been saved"
            alert.informativeText = "Cancel quitting to export your edits or retry saving. Quitting without saving loses in-memory changes."
            alert.addButton(withTitle: "Cancel Quit")
            alert.addButton(withTitle: "Quit Without Saving")
            let quit = alert.runModal() == .alertSecondButtonReturn
            if !quit { store.closing = false }
            sender.reply(toApplicationShouldTerminate: quit)
        }
        return .terminateLater
    }
}
