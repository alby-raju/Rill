import RillCore
import SwiftUI

struct CookieManagerView: View {
    let jar: CookieJar
    @SwiftUI.Environment(\.dismiss) private var dismiss
    @ViewState<[HTTPCookie]> private var cookies = []
    @ViewState<String> private var filter = ""
    @ViewState<Bool> private var showValues = false
    @ViewState<Bool> private var confirmingClear = false

    private var visible: [HTTPCookie] {
        cookies.filter {
            filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter)
                || $0.domain.localizedCaseInsensitiveContains(filter)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                RillToolHeading(
                    title: "Cookie Manager",
                    subtitle: "Cookies collected by HTTP requests in this session.",
                    icon: "tray.full")
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            HStack {
                TextField("Filter by domain or name", text: $filter)
                    .accessibilityLabel("Filter by domain or name")
                Toggle("Show values", isOn: $showValues)
                    .disabled(cookies.isEmpty)
            }
            if visible.isEmpty {
                RillToolEmpty(
                    title: cookies.isEmpty ? "No cookies saved" : "No matching cookies",
                    detail: cookies.isEmpty
                        ? "Send an HTTP request to a server that returns a Set-Cookie header."
                        : "Try another domain or cookie name.",
                    icon: "tray"
                ).rillToolPanel()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(visible, id: \.self) { cookie in
                            row(cookie)
                        }
                    }.padding(12)
                }.rillToolPanel()
            }
            HStack {
                Text("\(visible.count) of \(cookies.count) cookies · cleared when Rill quits")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Clear all…", systemImage: "trash", role: .destructive) {
                    confirmingClear = true
                }.disabled(cookies.isEmpty)
            }
        }.padding(24).frame(width: 760, height: 540).rillToolControls()
            .onAppear(perform: refresh)
            .onReceive(
                NotificationCenter.default.publisher(for: .NSHTTPCookieManagerCookiesChanged)
                    .receive(on: RunLoop.main)
            ) { _ in refresh() }
            .alert("Clear all cookies?", isPresented: $confirmingClear) {
                Button("Clear all", role: .destructive) {
                    jar.removeAll()
                    refresh()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Later requests may need to sign in again.")
            }
    }

    private func row(_ cookie: HTTPCookie) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text(cookie.name).font(.headline).lineLimit(1)
                Text(cookie.domain + cookie.path)
                    .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                HStack {
                    if cookie.isSecure { Text("Secure") }
                    if cookie.isHTTPOnly { Text("HttpOnly") }
                    if let expires = cookie.expiresDate {
                        Text("Expires \(expires.formatted(date: .abbreviated, time: .shortened))")
                    } else {
                        Text("Session cookie")
                    }
                }.font(.caption).foregroundStyle(.secondary)
                if showValues {
                    Text(cookie.value).font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            Spacer()
            Button {
                jar.remove(cookie)
                refresh()
            } label: {
                Image(systemName: "trash")
            }.buttonStyle(RillButtonStyle(emphasis: .quiet))
                .accessibilityLabel("Delete cookie \(cookie.name)")
        }.padding(12).rillToolPanel()
    }

    private func refresh() {
        cookies = jar.cookies.sorted {
            ($0.domain, $0.path, $0.name) < ($1.domain, $1.path, $1.name)
        }
    }
}
