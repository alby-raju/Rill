import RillCore
import SwiftUI

struct TLSManagerView: View {
    @EnvironmentObject private var store: WorkbenchStore
    @SwiftUI.Environment(\.dismiss) private var dismiss
    @ViewState<UUID?> private var selection: UUID?
    @ViewState<[TLSIdentityChoice]> private var identities = []
    @ViewState<Bool> private var busy = false
    private let manager = TLSIdentityManager()
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                RillToolHeading(
                    title: "TLS profiles",
                    subtitle: "Manage certificate trust and client identities.",
                    icon: "lock.shield")
                Spacer()
                if busy {
                    ProgressView().controlSize(.small).accessibilityLabel("Accessing Keychain")
                }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
            }
            HStack(alignment: .top, spacing: RillSpacing.section) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("PROFILES · \((store.workspace.tlsProfiles ?? []).count)")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ScrollView {
                        LazyVStack(spacing: 5) {
                            ForEach(store.workspace.tlsProfiles ?? []) { profile in
                                SelectionRow(
                                    title: profile.name, detail: profile.mode.rawValue,
                                    icon: profile.mode == .insecure
                                        ? "exclamationmark.shield" : "lock.shield",
                                    selected: selection == profile.id
                                ) { selection = profile.id }
                            }
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    Button("New profile", systemImage: "plus") {
                        let profile = TLSProfile()
                        if store.workspace.tlsProfiles == nil { store.workspace.tlsProfiles = [] }
                        store.workspace.tlsProfiles?.append(profile)
                        selection = profile.id
                    }.buttonStyle(RillButtonStyle(emphasis: .primary))
                }.padding(14)
                    .frame(width: 205).frame(maxHeight: .infinity)
                    .rillToolPanel()
                Group {
                    if let profile = (store.workspace.tlsProfiles ?? []).first(where: {
                        $0.id == selection
                    }) {
                        profileForm(profile).id(profile.id)
                    } else {
                        RillToolEmpty(
                            title: "No TLS profile selected",
                            detail:
                                "Create a profile to customize certificate trust or attach a Keychain identity.",
                            icon: "lock.shield")
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .disabled(busy)
        }.padding(RillSpacing.sheet).frame(width: 850, height: 600).rillToolControls()
            .onAppear { selection = store.workspace.tlsProfiles?.first?.id }
    }
    private func profileForm(_ original: TLSProfile) -> some View {
        let profile = Binding(
            get: { (store.workspace.tlsProfiles ?? []).first { $0.id == original.id } ?? original },
            set: { updated in
                if let index = store.workspace.tlsProfiles?.firstIndex(where: {
                    $0.id == original.id
                }) {
                    store.workspace.tlsProfiles?[index] = updated
                }
            })
        let identity = Binding<Data?>(
            get: { profile.wrappedValue.identityReference },
            set: { reference in
                if let reference {
                    guard let choice = identities.first(where: { $0.reference == reference }) else {
                        return
                    }
                    setIdentity(choice, on: profile)
                } else {
                    setIdentity(nil, on: profile)
                }
            })
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                RillSection(
                    title: "Certificate verification",
                    subtitle: "Choose how Rill verifies the server certificate.",
                    icon: "checkmark.shield"
                ) {
                    TextField("Profile name", text: profile.name)
                        .accessibilityLabel("Profile name")
                    RillSelect(
                        title: "Verification", value: original.mode.rawValue,
                        selection: profile.mode
                    ) {
                        ForEach(TLSMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    if profile.wrappedValue.mode == .insecure {
                        Text(
                            "Certificate and hostname verification are disabled for requests selecting this profile. Send asks for explicit confirmation."
                        ).foregroundStyle(.red)
                    }
                    if profile.wrappedValue.mode == .custom {
                        Toggle("Also trust system roots", isOn: profile.includeSystemRoots)
                        Text("\(profile.wrappedValue.anchors.count) custom anchor(s)").font(
                            .caption)
                        Button("Add DER/PEM certificate…") {
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = false
                            if panel.runModal() == .OK, let url = panel.url {
                                busy = true
                                store.importing = true
                                Task {
                                    defer {
                                        busy = false
                                        store.importing = false
                                    }
                                    do {
                                        let data = try await Task.detached {
                                            try TLSProfiles.certificateData(
                                                TLSProfiles.readFile(url, maximum: 1024 * 1024))
                                        }.value
                                        guard profile.wrappedValue.anchors.count < 16 else {
                                            throw TLSError.invalidProfile
                                        }
                                        profile.wrappedValue.anchors.append(data)
                                    } catch { store.error = error.localizedDescription }
                                }
                            }
                        }
                        Button("Remove custom anchors", role: .destructive) {
                            profile.wrappedValue.anchors = []
                        }.disabled(profile.wrappedValue.anchors.isEmpty)
                        Text(
                            "Hostname verification remains enabled. Custom evaluation does not fetch missing certificates from the network."
                        ).font(.caption).foregroundStyle(.secondary)
                    }
                }
                RillSection(
                    title: "Client identity",
                    subtitle: "Select a macOS Keychain identity for mutual TLS.",
                    icon: "person.badge.key"
                ) {
                    RillSelect(
                        title: "Keychain identity",
                        value: original.identityLabel
                            ?? (original.requiresClientIdentity
                                ? "Choose an identity" : "No client identity"),
                        selection: identity
                    ) {
                        Text("No client identity").tag(nil as Data?)
                        if let current = original.identityReference,
                            !identities.contains(where: { $0.reference == current })
                        {
                            Text(original.identityLabel ?? "Current identity").tag(
                                Optional(current))
                        }
                        ForEach(identities) { choice in
                            Text(choice.label).tag(Optional(choice.reference))
                        }
                    }
                    HStack(spacing: RillSpacing.controls) {
                        Button("Load from Keychain") {
                            busy = true
                            store.importing = true
                            Task {
                                defer {
                                    busy = false
                                    store.importing = false
                                }
                                do { identities = try await manager.choices() } catch {
                                    store.error = error.localizedDescription
                                }
                            }
                        }
                        Button("Import PKCS#12…") {
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = false
                            guard panel.runModal() == .OK, let url = panel.url else { return }
                            let alert = NSAlert()
                            alert.messageText = "Import client identity into macOS Keychain"
                            alert.informativeText =
                                "The identity and private key will be added to your default Keychain. Its password is used only for import."
                            let password = NSSecureTextField(
                                frame: NSRect(x: 0, y: 0, width: 280, height: 24))
                            alert.accessoryView = password
                            alert.addButton(withTitle: "Import")
                            alert.addButton(withTitle: "Cancel")
                            guard alert.runModal() == .alertFirstButtonReturn else { return }
                            let passphrase = password.stringValue
                            password.stringValue = ""
                            busy = true
                            store.importing = true
                            Task {
                                defer {
                                    busy = false
                                    store.importing = false
                                }
                                do {
                                    let data = try await Task.detached {
                                        try TLSProfiles.readFile(url, maximum: 4 * 1024 * 1024)
                                    }.value
                                    let imported = try await manager.importPKCS12(
                                        data, passphrase: passphrase)
                                    identities = imported
                                    if let first = imported.first {
                                        setIdentity(first, on: profile)
                                    }
                                } catch { store.error = error.localizedDescription }
                            }
                        }
                    }
                }
                Text(
                    "Workspace files store public trust certificates and identity references, never private keys or import passwords. Removing a profile does not remove imported identities from Keychain."
                ).font(.caption).foregroundStyle(.secondary)
                Button("Delete TLS profile", role: .destructive) {
                    let alert = NSAlert()
                    alert.messageText = "Delete TLS profile?"
                    alert.informativeText =
                        "Requests retain the missing profile selection and fail until reconfigured."
                    alert.addButton(withTitle: "Cancel")
                    alert.addButton(withTitle: "Delete")
                    if alert.runModal() == .alertSecondButtonReturn {
                        store.workspace.tlsProfiles?.removeAll { $0.id == original.id }
                        selection = store.workspace.tlsProfiles?.first?.id
                    }
                }
            }.padding(2)
        }
    }

    private func setIdentity(_ identity: TLSIdentityChoice?, on profile: Binding<TLSProfile>) {
        var updated = profile.wrappedValue
        updated.identityReference = identity?.reference
        updated.identityLabel = identity?.label
        updated.requiresClientIdentity = identity != nil
        profile.wrappedValue = updated
    }

}
