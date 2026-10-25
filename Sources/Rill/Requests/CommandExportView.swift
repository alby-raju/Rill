import SwiftUI
import RillCore

struct CommandExportView: View {
    @EnvironmentObject private var store: WorkbenchStore
    @SwiftUI.Environment(\.dismiss) private var dismiss
    @ViewState<CommandTarget> private var target = .curl
    @ViewState<Bool> private var clientSnippet = false
    @ViewState<ClientTarget> private var clientTarget = .requests
    @ViewState<Bool> private var includeCredentials = false
    @ViewState<String> private var output = ""
    @ViewState<String?> private var error: String?
    @ViewState<Bool> private var generating = false
    @ViewState<UUID> private var generation = UUID()
    @ViewState<Task<Void, Never>?> private var workerTask: Task<Void, Never>? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("Generate command or client").font(.title2); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
            Toggle("Generate a client program", isOn: $clientSnippet)
            if clientSnippet {
                Picker("Client", selection: $clientTarget) { ForEach(ClientTarget.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
            }
            if !clientSnippet { Picker("Target", selection: $target) { ForEach(CommandTarget.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented) }
            Toggle("Include auth, cookie and API-key header values", isOn: $includeCredentials)
            Text("URL queries, bodies, file paths and uncommon headers may contain secrets even with masking enabled. Generation runs enabled native pre-hooks and resolves selected variables/secrets and may read selected files to freeze the request; it never sends traffic. Review before copying or sharing.").font(.caption).foregroundStyle(.secondary)
            Button(generating ? "Generating…" : "Generate from current draft") {
                guard let request = store.selected else { return }
                let environment = store.environment, profiles = store.workspace.authProfiles ?? [], secrets = NamedSecretResolver(catalog: store.workspace.namedSecrets ?? [])
                let target = target, include = includeCredentials, client = clientSnippet, clientTarget = clientTarget
                clear(); let id = generation; generating = true; error = nil
                workerTask = Task {
                    let worker = Task.detached {
                        if client {
                            let frozen = try FrozenClientRequest.capture(request, environment: environment, includeCredentials: include, profiles: profiles, secrets: secrets)
                            return try ClientSnippetGenerator.generate(frozen, target: clientTarget)
                        }
                        return try CommandGenerator.generate(request, environment: environment, target: target, includeCredentials: include, profiles: profiles, secrets: secrets)
                    }
                    do {
                        let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                        if generation == id && !Task.isCancelled {
                            if store.selected == request && store.environment == environment && (store.workspace.authProfiles ?? []) == profiles && (store.workspace.namedSecrets ?? []) == secrets.catalog { output = result }
                            else { error = "The draft, environment or auth configuration changed. Generate again." }
                        }
                    } catch { if generation == id && !Task.isCancelled { self.error = error.localizedDescription } }
                    if generation == id { generating = false }
                }
            }.disabled(generating || store.selected == nil)
            ScrollView([.vertical, .horizontal]) { Text(output).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            if let error { Text(error).foregroundStyle(.red) }
            HStack { Text("Clients embed bodies up to 1 MiB and disable redirects. CLI binary bodies keep file references; unsupported CLI forms and TLS profiles fail explicitly.").font(.caption).foregroundStyle(.secondary); Spacer(); Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(output, forType: .string) }.disabled(output.isEmpty) }
        }.padding(24).frame(width: 850, height: 600)
        .onChange(of: target) { _, _ in clear() }
        .onChange(of: clientTarget) { _, _ in clear() }
        .onChange(of: clientSnippet) { _, _ in clear() }
        .onChange(of: store.selected) { _, _ in clear() }
        .onChange(of: store.environment) { _, _ in clear() }
        .onChange(of: store.workspace.authProfiles) { _, _ in clear() }
        .onChange(of: store.workspace.namedSecrets) { _, _ in clear() }
        .onChange(of: includeCredentials) { _, _ in clear() }
        .onChange(of: store.selection) { _, _ in clear() }
        .onDisappear { clear() }
    }
    private func clear() {
        generation = UUID(); workerTask?.cancel(); workerTask = nil; output = ""; error = nil; generating = false

    }
}
