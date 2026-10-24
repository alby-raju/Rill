import SwiftUI
import RillCore

struct AuthenticationComposer: View {
    @EnvironmentObject private var store: WorkbenchStore
    @Binding var request: RequestDraft
    var body: some View {
        Form {
            Picker("TLS profile", selection: $request.tlsProfileID) {
                Text("System defaults").tag(nil as UUID?)
                ForEach(store.workspace.tlsProfiles ?? []) { Text(($0.mode == .insecure ? "⚠︎ " : "") + $0.name).tag(Optional($0.id)) }
                if let id = request.tlsProfileID, !(store.workspace.tlsProfiles ?? []).contains(where: { $0.id == id }) { Text("Missing TLS profile").tag(Optional(id)) }
            }
            if let profile = (store.workspace.tlsProfiles ?? []).first(where: { $0.id == request.tlsProfileID }), profile.mode == .insecure {
                Text("INSECURE TLS: certificate and hostname verification disabled.").foregroundStyle(.red).font(.caption)
            }
            Button("Manage TLS profiles…") { store.showTLS = true }
            Picker("Profile", selection: $request.authProfileID) {
                Text("Request-specific auth").tag(nil as UUID?)
                ForEach(store.workspace.authProfiles ?? []) { Text($0.name).tag(Optional($0.id)) }
                if let id = request.authProfileID, !(store.workspace.authProfiles ?? []).contains(where: { $0.id == id }) { Text("Missing profile").tag(Optional(id)) }
            }
            Button("Manage profiles and secrets…") { store.showAuthentication = true }
            if request.authProfileID == nil {
                Picker("Authentication", selection: $request.auth) { ForEach(AuthKind.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                if request.auth == .apiKey {
                    TextField("Key name", text: Binding(get: { request.apiKeyName ?? "" }, set: { request.apiKeyName = $0 }))
                    Picker("Send in", selection: Binding(get: { request.apiKeyLocation ?? .header }, set: { request.apiKeyLocation = $0 })) { ForEach(APIKeyLocation.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                }
                if request.auth == .basic { TextField("Username", text: $request.username) }
                if request.auth != .none {
                    SecureField(request.auth == .basic ? "Password or {{secret:name}}" : "Token or {{secret:name}}", text: $request.credential)
                    Text("Saved in macOS Keychain. Selected auth replaces a matching header or query key.").font(.caption).foregroundStyle(.secondary)
                }
            } else { Text("The selected profile supplies auth. Missing profiles or secrets fail before sending; request-specific settings remain inactive.").font(.caption).foregroundStyle(.secondary) }
        }.padding(20)
    }
}

struct AuthenticationManager: View {
    @EnvironmentObject private var store: WorkbenchStore
    @SwiftUI.Environment(\.dismiss) private var dismiss
    @ViewState<UUID?> private var selection: UUID?
    @ViewState<String> private var secretName = ""
    @ViewState<String> private var secretValue = ""
    @ViewState<UUID?> private var replacing: UUID?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Authentication and secrets").font(.title2); Spacer(); Button("Done") { store.cancelOAuth(); secretValue = ""; dismiss() }.keyboardShortcut(.defaultAction) }
            HSplitView {
                VStack(alignment: .leading) {
                    Text("PROFILES").font(.caption).foregroundStyle(.secondary)
                    List(selection: $selection) { ForEach(store.workspace.authProfiles ?? []) { Text($0.name).tag($0.id) } }
                    Button("New profile", systemImage: "plus") {
                        let profile = AuthenticationProfile()
                        if store.workspace.authProfiles == nil { store.workspace.authProfiles = [] }
                        store.workspace.authProfiles?.append(profile); selection = profile.id
                    }
                }.frame(minWidth: 160, maxWidth: 200)
                if let index = store.workspace.authProfiles?.firstIndex(where: { $0.id == selection }) {
                    profileForm(index).frame(minWidth: 250)
                } else { Text("Choose or create an auth profile.").foregroundStyle(.secondary).frame(minWidth: 250) }
                VStack(alignment: .leading, spacing: 12) {
                    Text("NATIVE SECRETS").font(.caption).foregroundStyle(.secondary)
                    List(store.workspace.namedSecrets ?? []) { secret in
                        HStack {
                            Button(secret.name) { replacing = secret.id; secretName = secret.name; secretValue = "" }.buttonStyle(.plain)
                            Spacer()
                            Button { store.deleteNamedSecret(secret) } label: { Image(systemName: "trash") }.buttonStyle(.plain).help("Delete native secret")
                        }
                    }
                    TextField("Secret name", text: $secretName).disabled(replacing != nil)
                    SecureField("New value (existing value is never displayed)", text: $secretValue)
                    HStack {
                        Button(replacing == nil ? "Create secret" : "Replace value") { store.setNamedSecret(name: secretName, value: secretValue, replacing: replacing); secretValue = "" }
                            .disabled(secretName.isEmpty || secretValue.isEmpty)
                        Button("New") { replacing = nil; secretName = ""; secretValue = "" }
                    }
                    Text("Use {{secret:name}} directly or inside an environment value. Native entries take precedence. Process fallback uses RILL_SECRET_NAME (uppercase, dot/hyphen → underscore), is read-only and is never saved. Restart to pick up process changes.").font(.caption).foregroundStyle(.secondary)
                }.frame(minWidth: 280)
            }.disabled(store.oauthRunning)
            if store.oauthRunning { HStack { ProgressView().controlSize(.small); Text(store.oauthStatus); Spacer(); Button("Cancel authorization") { store.cancelOAuth() } } }
            else if !store.oauthStatus.isEmpty { Text(store.oauthStatus).font(.caption).foregroundStyle(.secondary) }
        }.padding(24).frame(width: 1100, height: 700).disabled(store.importing).onDisappear { store.cancelOAuth(); secretValue = "" }
    }
    private func profileForm(_ index: Int) -> some View {
        let original = store.workspace.authProfiles![index]
        let profile = Binding(get: { (store.workspace.authProfiles ?? []).first { $0.id == original.id } ?? original }, set: { updated in
            if let current = store.workspace.authProfiles?.firstIndex(where: { $0.id == original.id }) { store.workspace.authProfiles?[current] = updated }
        })
        return Form {
            TextField("Name", text: profile.name)
            Picker("Auth", selection: profile.kind) { ForEach(AuthKind.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
            if profile.wrappedValue.kind == .basic { TextField("Username", text: profile.username) }
            if profile.wrappedValue.kind != .none { TextField("Secret name", text: profile.secretName) }
            if profile.wrappedValue.kind == .apiKey {
                TextField("Key name", text: profile.apiKeyName)
                Picker("Send in", selection: profile.apiKeyLocation) { ForEach(APIKeyLocation.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
            }
            Toggle("OAuth2 token acquisition", isOn: Binding(get: { profile.wrappedValue.oauth != nil }, set: { enabled in profile.wrappedValue.oauth = enabled ? OAuthConfiguration() : nil; profile.wrappedValue.tokenExpiresAt = nil }))
            if profile.wrappedValue.oauth != nil {
                OAuthConfigurationEditor(configuration: Binding(get: { profile.wrappedValue.oauth ?? OAuthConfiguration() }, set: { profile.wrappedValue.oauth = $0 }))
                Text("The profile secret name above receives the access token. Client secrets use a different named entry. Tokens are acquired only by these buttons; refresh tokens are not retained.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Client credentials") { store.acquireOAuth(profileID: original.id, browser: false) }
                    Button("Browser + PKCE") { store.acquireOAuth(profileID: original.id, browser: true) }
                }
                if let expiry = profile.wrappedValue.tokenExpiresAt { Text("Token expires: " + expiry.formatted()).font(.caption) }
            }
            Text("Profiles store references and metadata. Secret values stay in Keychain or the process provider.").font(.caption).foregroundStyle(.secondary)
            Button("Delete profile", role: .destructive) {
                let alert = NSAlert(); alert.messageText = "Delete this profile?"; alert.informativeText = "Requests retain their selection and fail until another profile or request-specific auth is selected."
                alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Delete")
                if alert.runModal() == .alertSecondButtonReturn { store.workspace.authProfiles?.removeAll { $0.id == original.id }; selection = nil }
            }
        }.padding(12)
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
            Picker("Client authentication", selection: $configuration.clientAuthentication) { ForEach(OAuthClientAuthentication.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
            if configuration.clientAuthentication != .none { TextField("Client secret name", text: $configuration.clientSecretName) }
            Text("Register http://127.0.0.1:{dynamic-port}/oauth/callback for the public native client. HTTPS endpoints are required except literal loopback testing.").font(.caption).foregroundStyle(.secondary)
        }
    }
}
