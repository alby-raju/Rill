import RillCore
import SwiftUI

struct WorkspaceToolsView: View {
    @EnvironmentObject private var store: WorkbenchStore
    @SwiftUI.Environment(\.dismiss) private var dismiss
    @ViewState<String> private var section = "Git"
    @ViewState<String> private var repository = ""
    @ViewState<String> private var commitMessage = ""
    @ViewState<String> private var result = ""
    @ViewState<String?> private var error: String?
    @ViewState<Bool> private var busy = false
    @ViewState<UUID> private var generation = UUID()
    @ViewState<Task<Void, Never>?> private var operation: Task<Void, Never>?
    @ViewState<WorkspaceShareServer> private var server = WorkspaceShareServer()
    @ViewState<String> private var token = ""
    @ViewState<String> private var shareURL = ""
    @ViewState<Bool> private var lan = false
    @ViewState<Int> private var port = 0
    @ViewState<String> private var pullURL = ""
    @ViewState<String> private var pluginDirectory = ""
    @ViewState<[DiscoveredPlugin]> private var plugins = []
    @ViewState<PluginTrust> private var trust = PluginTrust()
    private var trustURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Application Support/Rill/plugin-trust.json")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Workspace integrations").font(.title2)
                Spacer()
                Button("Done") {
                    stop()
                    dismiss()
                }.keyboardShortcut(.cancelAction)
            }
            Picker("Tool", selection: $section) {
                Text("Git").tag("Git")
                Text("Read-only sharing").tag("Sharing")
                Text("Local extensions").tag("Plugins")
            }.pickerStyle(.segmented)
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if section == "Git" { git } else if section == "Sharing" { sharing } else { extensions }
            ScrollView {
                Text(result).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.frame(minHeight: 100, maxHeight: 160)
        }.padding(24).frame(width: 950, height: 680)
            .onDisappear { stop() }
            .onChange(of: section) { _, _ in stop() }
    }
    private var git: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(
                "Explicit portable workspace checkout, separate from runtime data. Export retains entered URLs, headers, bodies, schemas and environment values; review them before committing. Keychain values and response history are omitted. No remote operations or automatic commits run; hooks and automatic commit signing are disabled for these limited commands."
            ).font(.callout)
            HStack {
                TextField("Repository directory", text: $repository)
                Button("Choose…") { chooseDirectory { repository = $0.path } }
            }
            HStack {
                Button("Initialize repository") {
                    perform {
                        try await WorkspaceGit.initialize(URL(fileURLWithPath: repository))
                        result = "Repository initialized"
                    }
                }
                Button("Status") {
                    perform {
                        result = try await WorkspaceGit.status(URL(fileURLWithPath: repository))
                    }
                }
                Button("Export saved workspace") {
                    let workspace = store.workspace
                    let directory = URL(fileURLWithPath: repository)
                    perform {
                        try await Task.detached {
                            try WorkspaceGit.export(workspace, to: directory)
                        }.value
                        try Task.checkCancellation()
                        result =
                            "Portable workspace exported; review workspace.json before committing."
                    }
                }
            }.disabled(busy || repository.isEmpty)
            TextField("Commit message", text: $commitMessage)
            Button("Commit reviewed workspace.json and .gitignore") {
                perform {
                    result = try await WorkspaceGit.commit(
                        URL(fileURLWithPath: repository), message: commitMessage)
                }
            }.disabled(busy || repository.isEmpty || commitMessage.isEmpty)
            Spacer()
        }
    }
    private var sharing: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(
                "Shares a sanitized snapshot: removes credentials/profiles/history, values, bodies, schemas and hooks. Labels and URL hosts/paths remain visible. Review names and paths before sharing. Token required on every request; default bind is loopback. Closing this tool stops the listener."
            ).font(.callout)
            SecureField("Access token (generate or paste 32–256 characters)", text: $token)
                .disabled(!shareURL.isEmpty)
            HStack {
                Button("Generate token") {
                    do { token = try WorkspaceSharing.token() } catch {
                        self.error = error.localizedDescription
                    }
                }.disabled(!shareURL.isEmpty)
                Button("Copy token") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(token, forType: .string)
                }.disabled(token.isEmpty)
                Text("Port")
                TextField("Port", value: $port, format: .number).frame(width: 80).disabled(
                    !shareURL.isEmpty)
                Toggle("Allow LAN (plaintext HTTP)", isOn: $lan).disabled(!shareURL.isEmpty)
            }
            HStack {
                Button("Start read-only share") { startSharing() }.disabled(
                    busy || !shareURL.isEmpty || token.isEmpty)
                Button("Stop share") {
                    perform {
                        await server.stop()
                        shareURL = ""
                    }
                }.disabled(busy || shareURL.isEmpty)
                Text(shareURL).textSelection(.enabled)
            }
            Divider()
            TextField("Share URL to pull", text: $pullURL)
            Button("Pull sanitized copy to a new file…") { pull() }.disabled(
                busy || pullURL.isEmpty || token.isEmpty)
            Spacer()
        }
    }
    private var extensions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(
                "Native extension API v1 registers data-only request templates and mock-route services. No scripts, JARs or dynamic libraries are loaded. Enabling trusts exact manifest/service hashes; edits invalidate approval. Imported template hooks and automatic introspection stay disabled."
            ).font(.callout)
            HStack {
                TextField("Extension directory", text: $pluginDirectory)
                Button("Choose…") { chooseDirectory { pluginDirectory = $0.path } }
                Button("Discover") { discover() }.disabled(busy || pluginDirectory.isEmpty)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(plugins) { plugin in
                        Text(
                            plugin.descriptor.name + " · " + plugin.id + " · "
                                + plugin.descriptor.version
                        ).font(.headline)
                        HStack {
                            Text(
                                trust.allows(plugin) ? "Enabled for this exact content" : "Disabled"
                            ).font(.caption)
                            Button(trust.allows(plugin) ? "Revoke" : "Review and enable…") {
                                enable(plugin)
                            }.disabled(busy)
                        }
                        ForEach(plugin.descriptor.services) { service in
                            HStack {
                                Text(service.id + " · " + service.kind.rawValue).font(.caption)
                                if service.kind == .mockRoutes {
                                    Button("Export routes…") {
                                        exportRoutes(plugin, service: service.id)
                                    }.disabled(busy || !trust.allows(plugin))
                                }
                                if service.kind == .requestTemplate {
                                    Button("Import template") {
                                        importTemplate(plugin, service: service.id)
                                    }.disabled(busy || !trust.allows(plugin))
                                }
                            }
                        }
                        Divider()
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
    private func chooseDirectory(_ selected: (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url { selected(url) }
    }
    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        busy = true
        error = nil
        operation?.cancel()
        generation = UUID()
        let id = generation
        operation = Task {
            defer {
                if generation == id {
                    busy = false
                    operation = nil
                }
            }
            do {
                try await action()
                try Task.checkCancellation()
            } catch {
                if generation == id && !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }
    private func startSharing() {
        guard (0...65535).contains(port) else {
            error = "Choose a valid port."
            return
        }
        if lan {
            let alert = NSAlert()
            alert.messageText = "Expose this snapshot on the LAN?"
            alert.informativeText =
                "All IPv4 interfaces will accept connections. HTTP sends the access token and retained labels/URL paths without encryption. Share only with intended recipients on a trusted network."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Start LAN Share")
            guard alert.runModal() == .alertSecondButtonReturn else { return }
        }
        let workspace = store.workspace
        let token = token
        let port = UInt16(port)
        let lan = lan
        perform {
            shareURL = try await server.start(
                workspace: workspace, token: token, port: port, allowLAN: lan
            ).absoluteString
            result =
                lan
                ? "Listening on all IPv4 interfaces; recipients use this Mac's LAN address and selected port."
                : "Loopback share started."
        }
    }
    private func pull() {
        guard let url = URL(string: pullURL) else {
            error = "Invalid share URL."
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "shared-workspace.json"
        guard panel.runModal() == .OK, let target = panel.url else { return }
        let token = token
        let allow = lan
        perform {
            try await WorkspaceSharing.pull(
                url, token: token, destination: target, allowPlaintextLAN: allow)
            result = "Sanitized copy saved with fresh identities; no existing file was overwritten."
        }
    }
    private func discover() {
        let root = URL(fileURLWithPath: pluginDirectory)
        let trustURL = trustURL
        perform {
            let found = try await Task.detached { try PluginRegistry.discover(root) }.value
            try Task.checkCancellation()
            plugins = found
            trust = try PluginTrust.load(trustURL)
            result = "\(found.count) extension(s) discovered; none executed."
        }
    }
    private func enable(_ plugin: DiscoveredPlugin) {
        if !trust.allows(plugin) {
            let alert = NSAlert()
            alert.messageText = "Enable this data-only extension?"
            alert.informativeText =
                plugin.id
                + "\n\nReview its manifest and JSON service files first. Approval applies only to fingerprint:\n"
                + plugin.fingerprint
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Enable reviewed content")
            guard alert.runModal() == .alertSecondButtonReturn else { return }
        }
        do {
            if trust.allows(plugin) { trust.disable(plugin.id) } else { trust.enable(plugin) }
            try trust.save(trustURL)
        } catch { self.error = error.localizedDescription }
    }
    private func importTemplate(_ plugin: DiscoveredPlugin, service: String) {
        let registry = PluginRegistry(
            plugins: plugins, trust: trust, context: PluginContext(workspace: store.workspace))
        perform {
            let request = try await Task.detached {
                try registry.request(plugin: plugin.id, service: service)
            }.value
            try Task.checkCancellation()
            _ = await store.importCommand(
                CommandImport(
                    request: request,
                    warnings: ["Trusted template imported; hooks remain disabled."]))
        }
    }
    private func exportRoutes(_ plugin: DiscoveredPlugin, service: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "mock-routes.json"
        guard panel.runModal() == .OK, let target = panel.url else { return }
        let registry = PluginRegistry(
            plugins: plugins, trust: trust, context: PluginContext(workspace: store.workspace))
        perform {
            let routes = try await Task.detached {
                try registry.mockRoutes(plugin: plugin.id, service: service)
            }.value
            try Task.checkCancellation()
            try WorkspaceFile.writeNew(MockRouteFile.encode(routes), to: target)
            result = "Validated routes exported; open them in API tools or mock-serve."
        }
    }
    private func stop() {
        generation = UUID()
        let id = generation
        operation?.cancel()
        operation = nil
        busy = true
        Task {
            await server.stop()
            if generation == id {
                shareURL = ""
                busy = false
            }
        }
    }
}
