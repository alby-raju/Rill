import SwiftUI
import RillCore

struct AuthenticationComposer: View {
    @EnvironmentObject private var store: WorkbenchStore
    @Binding var request: RequestDraft
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                RillSection(title: "Authentication", subtitle: "Choose how this request identifies itself.", icon: "key.horizontal") {
                    HStack {
                        Text("Profile").font(.caption).foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
                        RillSelect(title: "Authentication profile", value: request.authProfileID == nil ? "Request-specific auth" : (store.workspace.authProfiles ?? []).first(where: { $0.id == request.authProfileID })?.name ?? "Missing profile", selection: $request.authProfileID) {
                            Text("Request-specific auth").tag(nil as UUID?)
                            ForEach(store.workspace.authProfiles ?? []) { Text($0.name).tag(Optional($0.id)) }
                            if let id = request.authProfileID, !(store.workspace.authProfiles ?? []).contains(where: { $0.id == id }) { Text("Missing profile").tag(Optional(id)) }
                        }.frame(maxWidth: 330)
                    }
                    if request.authProfileID == nil {
                        HStack {
                            Text("Method").font(.caption).foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
                            RillSelect(title: "Authentication method", value: request.auth.rawValue, selection: $request.auth) { ForEach(AuthKind.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.frame(maxWidth: 330)
                        }
                        if request.auth == .apiKey {
                            TextField("API key name", text: Binding(get: { request.apiKeyName ?? "" }, set: { request.apiKeyName = $0 }))
                            RillSelect(title: "API key location", value: (request.apiKeyLocation ?? .header).rawValue, selection: Binding(get: { request.apiKeyLocation ?? .header }, set: { request.apiKeyLocation = $0 })) { ForEach(APIKeyLocation.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.frame(width: 200)
                        }
                        if request.auth == .basic { TextField("Username", text: $request.username) }
                        if request.auth != .none {
                            SecureField(request.auth == .basic ? "Password or {{secret:name}}" : "Token or {{secret:name}}", text: $request.credential)
                            RillNotice(text: "Credentials are saved in macOS Keychain. Use {{secret:name}} to reference a named secret.", icon: "lock.shield")
                        } else { RillNotice(text: "This request does not add authentication. You can still configure headers manually.", icon: "lock.open") }
                    } else { RillNotice(text: "The selected profile supplies authentication. Request-specific settings are kept and remain inactive.") }
                    Button { store.showAuthentication = true } label: { Label("Manage profiles & secrets", systemImage: "key.horizontal") }.buttonStyle(RillButtonStyle(emphasis: .quiet))
                }
                RillSection(title: "Connection security", subtitle: "Certificate verification is enabled by default.", icon: "lock.shield") {
                    RillSelect(title: "TLS profile", value: request.tlsProfileID == nil ? "System trust · recommended" : (store.workspace.tlsProfiles ?? []).first(where: { $0.id == request.tlsProfileID })?.name ?? "Missing TLS profile", selection: $request.tlsProfileID) {
                        Text("System trust · recommended").tag(nil as UUID?)
                        ForEach(store.workspace.tlsProfiles ?? []) { Text(($0.mode == .insecure ? "⚠︎ " : "") + $0.name).tag(Optional($0.id)) }
                        if let id = request.tlsProfileID, !(store.workspace.tlsProfiles ?? []).contains(where: { $0.id == id }) { Text("Missing TLS profile").tag(Optional(id)) }
                    }.frame(maxWidth: 420)
                    if (store.workspace.tlsProfiles ?? []).first(where: { $0.id == request.tlsProfileID })?.mode == .insecure {
                        Label("Certificate and hostname verification are disabled.", systemImage: "exclamationmark.shield").font(.caption).foregroundStyle(.red)
                    }
                    Button { store.showTLS = true } label: { Label("Manage TLS profiles", systemImage: "slider.horizontal.3") }.buttonStyle(RillButtonStyle(emphasis: .quiet))
                }
            }.padding(20).frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity, alignment: .topLeading)
        }.textFieldStyle(RillTextFieldStyle())
    }
}
