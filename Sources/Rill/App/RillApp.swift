import RillCore
import SwiftUI

// Explicit type alias avoids macro/type name ambiguity in newer SDKs.
typealias ViewState<Value> = SwiftUI.State<Value>

@main struct RillApp: App {
    @NSApplicationDelegateAdaptor(RillAppDelegate.self) private var delegate
    @StateObject private var store = RillPreview.makeStore()
    @ViewState<String> private var settingsSection = "General"
    @AppStorage("appearance") private var appearance = "system"
    var body: some Scene {
        WindowGroup {
            WorkbenchView().environmentObject(store).defaultAppStorage(RillPreview.preferences)
                // Give the window one toolbar surface. The native toolbar sidebar inset
                // has a different edge from the resizable navigation column below.
                .toolbarBackground(RillPalette.canvas, for: .windowToolbar)
                .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
                .onAppear {
                    delegate.store = store
                    if let url = RillResources.url(forResource: "Rill", withExtension: "icns") {
                        NSApplication.shared.applicationIconImage = NSImage(contentsOf: url)
                    }
                }
                .preferredColorScheme(
                    RillPreview.scheme
                        ?? (appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
                )
                .task {
                    await InstallationCheck.verifyIfRequested()
                    await RillPreview.captureIfRequested()
                }
                .frame(minWidth: 1050, minHeight: 700)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 920)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Request") { store.newRequest() }.keyboardShortcut("n")
                Button("New Collection") { store.newCollection() }.keyboardShortcut(
                    "n", modifiers: [.command, .shift])
                Divider()
                Menu("Import Requests and Collections") {
                    Button("cURL / HTTPie / HAR…") { store.showCommandImport = true }
                    Divider()
                    Button("Bruno File / Folder / ZIP…") { store.importForeign(.bruno) }
                    Button("HTTPie Desktop JSON…") { store.importForeign(.httpieDesktop) }
                    Button("Insomnia JSON / YAML…") { store.importForeign(.insomnia) }
                    Button("Postman JSON…") { store.importForeign(.postman) }
                }
                Menu("Export Requests and Collections") {
                    Button("Bruno Bundle…") { store.exportInterchange("Bruno bundle") }
                    Button("HAR Request…") { store.exportInterchange("HAR request") }.disabled(
                        store.selected == nil)
                    Button("Insomnia Collection…") {
                        store.exportInterchange("Insomnia collection")
                    }
                    Button("Postman Collection…") {
                        store.exportInterchange("Postman collection")
                    }
                    Button("Postman Environment…") {
                        store.exportInterchange("Postman environment")
                    }.disabled(store.environment == nil)
                }
            }
            CommandGroup(replacing: .help) {
                Button("Rill Offline Help") { store.showHelp = true }.keyboardShortcut(
                    "?", modifiers: .command)
                Button("Export Support Diagnostics…") { store.exportDiagnostics() }
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save Request") { store.saveSelected() }.keyboardShortcut("s")
            }
            CommandMenu("Request") {
                Button("Send Request") { store.send() }.keyboardShortcut(
                    .return, modifiers: .command
                ).disabled(store.running || !store.canEdit || store.selected == nil)
                Button("Cancel Request") { store.cancel() }.keyboardShortcut(".")
                    .disabled(!store.running)
                Button("Find Request") { store.showPalette = true }.keyboardShortcut("k")
                Divider()
                Menu("Tabs") {
                    Button("New Request Tab") { store.newRequest() }.keyboardShortcut("t")
                    Button("Reopen Closed Tab") { store.reopenTab() }.keyboardShortcut(
                        "t", modifiers: [.command, .shift])
                    Divider()
                    Button("Close Request Tab") {
                        if let id = store.selection { store.closeTab(id) }
                    }
                    .keyboardShortcut("w")
                    Button("Close Tabs to the Left") {
                        store.closeTabs(.left, relativeTo: store.selection)
                    }.disabled(
                        !store.canEdit
                            || store.editor.tabsToClose(.left, relativeTo: store.selection).isEmpty)
                    Button("Close Tabs to the Right") {
                        store.closeTabs(.right, relativeTo: store.selection)
                    }.disabled(
                        !store.canEdit
                            || store.editor.tabsToClose(.right, relativeTo: store.selection).isEmpty
                    )
                    Button("Close All Tabs") { store.closeTabs(.all) }.disabled(
                        !store.canEdit || store.editor.openTabs.isEmpty)
                }
                Menu("Reorder Request") {
                    Button("Move Request Earlier") { store.reorderSelected(-1) }.keyboardShortcut(
                        .upArrow, modifiers: .option)
                    Button("Move Request Later") { store.reorderSelected(1) }.keyboardShortcut(
                        .downArrow, modifiers: .option)
                }.disabled(store.selected == nil)
                Divider()
                Button("Review Imported Scripts…") { store.showForeignScripts = true }.disabled(
                    store.selected?.foreignScripts?.isEmpty != false)
                Button("Generate Command…") { store.showCommandExport = true }.disabled(
                    store.selection == nil)
            }
            CommandMenu("Workspace") {
                Button("Browse Tools…") { store.showToolBrowser = true }.disabled(!store.canEdit)
                Divider()
                ForEach(WorkspaceTool.groups) { group in
                    Menu(group.title) {
                        ForEach(group.tools) { tool in
                            Button(tool.title + "…") { tool.open(store) }
                                .keyboardShortcut(tool.shortcut)
                                .disabled(!tool.isAvailable(in: store))
                        }
                    }
                }
            }
        }
        Settings {
            VStack(alignment: .leading, spacing: 16) {
                RillToolHeading(
                    title: "Settings", subtitle: "Customize Rill on this Mac.",
                    icon: "gearshape")
                RillTabs(
                    titles: ["General", "Response limits", "Snapshots"], selection: $settingsSection
                )
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if settingsSection == "General" {
                            RillSection(
                                title: "Appearance", subtitle: "Choose a theme or follow macOS.",
                                icon: "circle.lefthalf.filled"
                            ) {
                                Picker("Appearance", selection: $appearance) {
                                    Text("System").tag("system")
                                    Text("Light").tag("light")
                                    Text("Dark").tag("dark")
                                }.pickerStyle(.segmented).labelsHidden()
                            }
                            RillSection(title: "Local data", subtitle: "", icon: "lock") {
                                Text(
                                    "Authentication tokens and passwords are stored in macOS Keychain. Headers, bodies, URLs and environment values are stored locally as entered. Enable snapshots to retain response history across sessions."
                                )
                                .font(.callout).foregroundStyle(.secondary)
                            }
                        } else {
                            ResponseSettingsView(snapshots: settingsSection == "Snapshots")
                                .environmentObject(store)
                        }
                    }
                }
            }.padding(RillSpacing.sheet).frame(width: 650, height: 550).rillToolControls()
                .preferredColorScheme(
                    appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
        }
    }
}

@MainActor final class RillAppDelegate: NSObject, NSApplicationDelegate {
    weak var store: WorkbenchStore?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store else { return .terminateNow }
        guard !store.importing else {
            store.error = "Wait for the workspace operation to finish before quitting."
            return .terminateCancel
        }
        store.cancelOAuth()
        store.closing = true
        store.cancel()
        Task {
            let saved = await store.flushPendingChanges()
            if saved {
                sender.reply(toApplicationShouldTerminate: true)
                return
            }
            if store.quitCancelled {
                store.closing = false
                sender.reply(toApplicationShouldTerminate: false)
                return
            }
            let alert = NSAlert()
            alert.messageText = "Some changes have not been saved"
            alert.informativeText =
                "Cancel quitting to export your edits or retry saving. Quitting without saving loses in-memory changes."
            alert.addButton(withTitle: "Cancel Quit")
            alert.addButton(withTitle: "Quit Without Saving")
            let quit = alert.runModal() == .alertSecondButtonReturn
            if !quit { store.closing = false }
            sender.reply(toApplicationShouldTerminate: quit)
        }
        return .terminateLater
    }
}
