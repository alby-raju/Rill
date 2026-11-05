import RillCore
import SwiftUI

struct AuthenticationManager: View {
    @EnvironmentObject private var store: WorkbenchStore
    @SwiftUI.Environment(\.dismiss) private var dismiss
    @ViewState<String> private var section: String
    @ViewState<UUID?> private var selection: UUID?
    @ViewState<String> private var secretName = ""
    @ViewState<String> private var secretValue = ""
    @ViewState<UUID?> private var replacing: UUID?
    init(showSecrets: Bool = false) {
        _section = ViewState(wrappedValue: showSecrets ? "Secrets" : "Profiles")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: RillSpacing.section) {
            HStack {
                RillToolHeading(
                    title: "Authentication and secrets",
                    subtitle: "Reuse auth profiles and manage Keychain-backed values.",
                    icon: "key.horizontal")
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            RillTabs(titles: ["Profiles", "Secrets"], selection: $section)
                .disabled(store.oauthRunning)
            Group {
                if section == "Profiles" { profilesPage } else { secretsPage }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .disabled(store.oauthRunning)
            if store.oauthRunning {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(store.oauthStatus).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Cancel authorization") { store.cancelOAuth() }
                }
            } else if section == "Profiles", !store.oauthStatus.isEmpty {
                Text(store.oauthStatus).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.padding(RillSpacing.sheet).frame(width: 850, height: 620, alignment: .topLeading)
            .rillToolControls().disabled(store.importing)
            .onAppear { selection = store.workspace.authProfiles?.first?.id }
            .onChange(of: section) { _, _ in secretValue = "" }
            .onDisappear {
                if store.oauthRunning { store.cancelOAuth() }
                secretValue = ""
            }
    }

    private var profilesPage: some View {
        HStack(alignment: .top, spacing: RillSpacing.section) {
            VStack(alignment: .leading, spacing: RillSpacing.controls) {
                Text("PROFILES").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(store.workspace.authProfiles ?? []) { profile in
                            SelectionRow(
                                title: profile.name, detail: profile.kind.rawValue,
                                icon: "key.horizontal", selected: selection == profile.id
                            ) { selection = profile.id }
                        }
                    }
                }.frame(maxHeight: .infinity)
                Button("New profile", systemImage: "plus", action: createProfile)
                    .buttonStyle(RillButtonStyle(emphasis: .primary))
            }.padding(12).frame(width: 205).frame(maxHeight: .infinity).rillToolPanel()
            if let profile = store.workspace.authProfiles?.first(where: { $0.id == selection }) {
                profileForm(profile).id(profile.id)
            } else {
                RillToolEmpty(
                    title: "No profile selected",
                    detail: "Choose or create a profile to configure request authentication.",
                    icon: "key.horizontal"
                ).rillToolPanel()
            }
        }
    }

    private var secretsPage: some View {
        HStack(alignment: .top, spacing: RillSpacing.section) {
            VStack(alignment: .leading, spacing: RillSpacing.controls) {
                Text("NATIVE SECRETS").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(store.workspace.namedSecrets ?? []) { secret in
                            SelectionRow(
                                title: secret.name, icon: "lock", selected: replacing == secret.id
                            ) {
                                replacing = secret.id
                                secretName = secret.name
                                secretValue = ""
                            }
                        }
                    }
                }.frame(maxHeight: .infinity)
                Button("New secret", systemImage: "plus", action: resetSecret)
                    .buttonStyle(RillButtonStyle(emphasis: .primary))
            }.padding(12).frame(width: 205).frame(maxHeight: .infinity).rillToolPanel()
            ScrollView {
                VStack(alignment: .leading, spacing: RillSpacing.section) {
                    RillSection(
                        title: replacing == nil ? "Create a secret" : "Replace secret value",
                        subtitle: "Values are stored in macOS Keychain.",
                        icon: "lock"
                    ) {
                        TextField("Secret name", text: $secretName).disabled(replacing != nil)
                        SecureField("New value", text: $secretValue)
                        Button(replacing == nil ? "Create secret" : "Replace value") {
                            store.setNamedSecret(
                                name: secretName, value: secretValue, replacing: replacing)
                            secretValue = ""
                        }.disabled(secretName.isEmpty || secretValue.isEmpty)
                    }
                    RillNotice(
                        text:
                            "Use {{secret:name}} directly or inside an environment value. Native entries take precedence over the read-only RILL_SECRET_NAME process fallback."
                    )
                    if let secret = store.workspace.namedSecrets?.first(where: {
                        $0.id == replacing
                    }) {
                        Button("Delete secret…", systemImage: "trash", role: .destructive) {
                            store.deleteNamedSecret(secret)
                        }
                    }
                }.padding(2)
            }.onChange(of: store.workspace.namedSecrets?.map(\.id)) { _, ids in
                if let replacing, ids?.contains(replacing) != true { resetSecret() }
            }
        }
    }

    private func createProfile() {
        var profile = AuthenticationProfile()
        let names = Set((store.workspace.authProfiles ?? []).map(\.name))
        let base = profile.name
        var suffix = 2
        while names.contains(profile.name) {
            profile.name = "\(base) \(suffix)"
            suffix += 1
        }
        store.workspace.authProfiles = (store.workspace.authProfiles ?? []) + [profile]
        selection = profile.id
    }

    private func resetSecret() {
        replacing = nil
        secretName = ""
        secretValue = ""
    }

    private func profileForm(_ original: AuthenticationProfile) -> some View {
        let profile = Binding(
            get: {
                (store.workspace.authProfiles ?? []).first { $0.id == original.id } ?? original
            },
            set: { updated in
                if let current = store.workspace.authProfiles?.firstIndex(where: {
                    $0.id == original.id
                }) {
                    store.workspace.authProfiles?[current] = updated
                }
            })
        return ScrollView {
            VStack(alignment: .leading, spacing: RillSpacing.section) {
                RillSection(title: "Profile settings", subtitle: "", icon: "key.horizontal") {
                    TextField("Profile name", text: profile.name)
                        .accessibilityLabel("Profile name")
                    RillSelect(
                        title: "Authentication method", value: original.kind.rawValue,
                        selection: profile.kind
                    ) {
                        ForEach(AuthKind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    if profile.wrappedValue.kind == .basic {
                        TextField("Username", text: profile.username)
                    }
                    if profile.wrappedValue.kind != .none {
                        TextField("Secret name", text: profile.secretName)
                    }
                    if profile.wrappedValue.kind == .apiKey {
                        TextField("Key name", text: profile.apiKeyName)
                        RillSelect(
                            title: "Send in", value: original.apiKeyLocation.rawValue,
                            selection: profile.apiKeyLocation
                        ) {
                            ForEach(APIKeyLocation.allCases, id: \.self) {
                                Text($0.rawValue).tag($0)
                            }
                        }
                    }
                }
                RillSection(title: "OAuth 2.0", subtitle: "", icon: "person.badge.key") {
                    Toggle(
                        "Acquire tokens for this profile",
                        isOn: Binding(
                            get: { profile.wrappedValue.oauth != nil },
                            set: { enabled in
                                profile.wrappedValue.oauth = enabled ? OAuthConfiguration() : nil
                                profile.wrappedValue.tokenExpiresAt = nil
                            }))
                    if profile.wrappedValue.oauth != nil {
                        OAuthConfigurationEditor(
                            configuration: Binding(
                                get: { profile.wrappedValue.oauth ?? OAuthConfiguration() },
                                set: { profile.wrappedValue.oauth = $0 }))
                        Text(
                            "The profile secret name above receives the access token. Client secrets use a different named entry. Tokens are acquired only by these buttons; refresh tokens are not retained."
                        ).font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("Client credentials") {
                                store.acquireOAuth(profileID: original.id, browser: false)
                            }
                            Button("Browser + PKCE") {
                                store.acquireOAuth(profileID: original.id, browser: true)
                            }
                        }
                        if let expiry = profile.wrappedValue.tokenExpiresAt {
                            Text("Token expires: " + expiry.formatted()).font(.caption)
                        }
                    }
                }
                Text(
                    "Profiles store references and metadata. Secret values stay in Keychain or the process provider."
                ).font(.caption).foregroundStyle(.secondary).fixedSize(
                    horizontal: false, vertical: true)
                Button("Delete profile…", role: .destructive) {
                    let alert = NSAlert()
                    alert.messageText = "Delete this profile?"
                    alert.informativeText =
                        "Requests retain their selection and fail until another profile or request-specific auth is selected."
                    alert.addButton(withTitle: "Cancel")
                    alert.addButton(withTitle: "Delete")
                    if alert.runModal() == .alertSecondButtonReturn {
                        store.workspace.authProfiles?.removeAll { $0.id == original.id }
                        selection = store.workspace.authProfiles?.first?.id
                    }
                }
            }.padding(2)
        }
    }
}

private struct OAuthConfigurationEditor: View {
    @Binding var configuration: OAuthConfiguration
    var body: some View {
        Group {
            TextField("Authorization endpoint", text: $configuration.authorizationEndpoint)
            TextField("Token endpoint", text: $configuration.tokenEndpoint)
            TextField("Client ID", text: $configuration.clientID)
            TextField("Scope", text: $configuration.scope)
            RillSelect(
                title: "Client authentication", value: configuration.clientAuthentication.rawValue,
                selection: $configuration.clientAuthentication
            ) {
                ForEach(OAuthClientAuthentication.allCases, id: \.self) {
                    Text($0.rawValue).tag($0)
                }
            }
            if configuration.clientAuthentication != .none {
                TextField("Client secret name", text: $configuration.clientSecretName)
            }
            Text(
                "Register http://127.0.0.1:{dynamic-port}/oauth/callback for the public native client. HTTPS endpoints are required except literal loopback testing."
            ).font(.caption).foregroundStyle(.secondary)
        }
    }
}
