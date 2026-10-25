import SwiftUI
import RillCore

struct TLSManagerView: View {
    @EnvironmentObject private var store: WorkbenchStore
    @SwiftUI.Environment(\.dismiss) private var dismiss
    @ViewState<UUID?> private var selection: UUID?
    @ViewState<[TLSIdentityChoice]> private var identities = []
    @ViewState<Bool> private var busy = false
    private let manager = TLSIdentityManager()
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("TLS profiles").font(.title2); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
            HSplitView {
                VStack {
                    List(selection: $selection) { ForEach(store.workspace.tlsProfiles ?? []) { Text(($0.mode == .insecure ? "⚠︎ " : "") + $0.name).tag($0.id) } }
                    Button("New profile", systemImage: "plus") { let profile = TLSProfile(); if store.workspace.tlsProfiles == nil { store.workspace.tlsProfiles = [] }; store.workspace.tlsProfiles?.append(profile); selection = profile.id }
                }.frame(width: 200)
                if let profile = (store.workspace.tlsProfiles ?? []).first(where: { $0.id == selection }) {
                    profileForm(profile).frame(minWidth: 430)
                } else { ContentUnavailableView("Select a TLS profile", systemImage: "lock.shield") }
            }
            if busy { ProgressView("Accessing Keychain…").controlSize(.small) }
        }.padding(24).frame(width: 850, height: 600).disabled(busy)
    }
    private func profileForm(_ original: TLSProfile) -> some View {
        let profile = Binding(get: { (store.workspace.tlsProfiles ?? []).first { $0.id == original.id } ?? original }, set: { updated in
            if let index = store.workspace.tlsProfiles?.firstIndex(where: { $0.id == original.id }) { store.workspace.tlsProfiles?[index] = updated }
        })
        return Form {
            TextField("Name", text: profile.name)
            Picker("Verification", selection: profile.mode) { ForEach(TLSMode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
            if profile.wrappedValue.mode == .insecure { Text("Certificate and hostname verification are disabled for requests selecting this profile. Send asks for explicit confirmation.").foregroundStyle(.red) }
            if profile.wrappedValue.mode == .custom {
                Toggle("Also trust system roots", isOn: profile.includeSystemRoots)
                Text("\(profile.wrappedValue.anchors.count) custom anchor(s)").font(.caption)
                Button("Add DER/PEM certificate…") {
                    let panel = NSOpenPanel(); panel.canChooseDirectories = false
                    if panel.runModal() == .OK, let url = panel.url {
                        busy = true; store.importing = true
                        Task {
                            defer { busy = false; store.importing = false }
                            do {
                                let data = try await Task.detached { try TLSProfiles.certificateData(TLSProfiles.readFile(url, maximum: 1024 * 1024)) }.value
                                guard profile.wrappedValue.anchors.count < 16 else { throw TLSError.invalidProfile }
                                profile.wrappedValue.anchors.append(data)
                            } catch { store.error = error.localizedDescription }
                        }
                    }
                }
                Button("Remove custom anchors") { profile.wrappedValue.anchors = [] }
                Text("Hostname verification remains enabled. Custom evaluation does not fetch missing certificates from the network.").font(.caption).foregroundStyle(.secondary)
            }
            Text("CLIENT IDENTITY").font(.caption).foregroundStyle(.secondary)
            Text(profile.wrappedValue.identityLabel ?? (profile.wrappedValue.requiresClientIdentity ? "Identity needs selection" : "None"))
            Menu("Select Keychain identity") {
                Button("None") { profile.wrappedValue.identityReference = nil; profile.wrappedValue.identityLabel = nil; profile.wrappedValue.requiresClientIdentity = false }
                ForEach(identities) { identity in Button(identity.label) { profile.wrappedValue.identityReference = identity.reference; profile.wrappedValue.identityLabel = identity.label; profile.wrappedValue.requiresClientIdentity = true } }
            }
            Button("Load Keychain identities") {
                busy = true; store.importing = true
                Task { defer { busy = false; store.importing = false }; do { identities = try await manager.choices() } catch { store.error = error.localizedDescription } }
            }
            Button("Import PKCS#12…") {
                let panel = NSOpenPanel(); panel.canChooseDirectories = false
                guard panel.runModal() == .OK, let url = panel.url else { return }
                let alert = NSAlert(); alert.messageText = "Import client identity into macOS Keychain"
                alert.informativeText = "The identity and private key will be added to your default Keychain. Its password is used only for import."
                let password = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24)); alert.accessoryView = password
                alert.addButton(withTitle: "Import"); alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                let passphrase = password.stringValue; password.stringValue = ""; busy = true; store.importing = true
                Task {
                    defer { busy = false; store.importing = false }
                    do {
                        let data = try await Task.detached { try TLSProfiles.readFile(url, maximum: 4 * 1024 * 1024) }.value
                        let imported = try await manager.importPKCS12(data, passphrase: passphrase)
                        identities = imported
                        if let first = imported.first { profile.wrappedValue.identityReference = first.reference; profile.wrappedValue.identityLabel = first.label; profile.wrappedValue.requiresClientIdentity = true }
                    } catch { store.error = error.localizedDescription }
                }
            }
            Text("Workspace files store public trust certificates and identity references, never private keys or import passwords. Removing a profile does not remove imported identities from Keychain.").font(.caption).foregroundStyle(.secondary)
            Button("Delete TLS profile", role: .destructive) {
                let alert = NSAlert(); alert.messageText = "Delete TLS profile?"; alert.informativeText = "Requests retain the missing profile selection and fail until reconfigured."
                alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Delete")
                if alert.runModal() == .alertSecondButtonReturn { store.workspace.tlsProfiles?.removeAll { $0.id == original.id }; selection = nil }
            }
        }.padding(16)
    }
}
