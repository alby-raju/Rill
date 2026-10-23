import SwiftUI

// Explicit type alias avoids macro/type name ambiguity in newer SDKs.
typealias ViewState<Value> = SwiftUI.State<Value>

@main struct RillApp: App {
    @StateObject private var store = WorkbenchStore()
    @AppStorage("appearance") private var appearance = "system"
    var body: some Scene {
        WindowGroup {
            WorkbenchView().environmentObject(store)
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
                Button("Import Rill Workspace…") { store.importWorkspace() }
                Button("Export Rill Workspace…") { store.exportWorkspace() }
            }
            CommandMenu("Request") {
                Button("Send Request") { store.send() }.keyboardShortcut(.return, modifiers: .command).disabled(store.running)
                Button("Cancel Request") { store.cancel() }.keyboardShortcut(".")
                Button("Find Request") { store.showPalette = true }.keyboardShortcut("k")
                Button("Environments") { store.showEnvironments = true }.keyboardShortcut("e", modifiers: [.command, .shift])
            }
        }
        Settings {
            Form {
                Picker("Appearance", selection: $appearance) { Text("System").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark") }
                Text("Authentication tokens and passwords are stored in macOS Keychain. Headers, bodies, URLs and environment values are stored locally as entered. Response history is kept only for this session.")
                    .font(.callout).foregroundStyle(.secondary)
            }.padding(24).frame(width: 450)
        }
    }
}
