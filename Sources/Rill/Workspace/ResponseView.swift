import RillCore
import SwiftUI

struct ResponseView: View {
    @EnvironmentObject private var store: WorkbenchStore
    var exchange: Exchange?
    var running: Bool
    @ViewState<String> private var section = "Body"
    @ViewState<Bool> private var pretty = true
    @AppStorage("editorFontSize") private var fontSize = 12.0
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 18) {
                Text("RESPONSE").font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                if let exchange {
                    Label("HTTP \(exchange.status)", systemImage: "circle.fill").foregroundStyle(
                        exchange.status < 400 ? Color.green : Color.orange)
                    Text(String(format: "%.0f ms", exchange.duration * 1000))
                    Text(
                        ByteCountFormatter.string(
                            fromByteCount: Int64(exchange.body.count), countStyle: .file))
                }
            }.font(.system(size: 11, weight: .medium, design: .monospaced)).padding(.horizontal, 24)
                .padding(.vertical, 16)
            Divider()
            if running {
                VStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text("Following the request…").font(.callout).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let exchange {
                validationBanner(exchange)
                RillTabs(
                    titles: ["Body", "Headers", "Checks", "Request", "Timeline"],
                    selection: $section
                )
                .padding(.horizontal, 15).accessibilityLabel("Response section")
                GeometryReader { _ in
                    VStack(spacing: 0) {
                        if section == "Body" {
                            HStack {
                                Toggle("Pretty JSON", isOn: $pretty).toggleStyle(.checkbox)
                                Spacer()
                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(
                                        exchange.previewIsTruncated
                                            ? exchange.text
                                            : pretty ? exchange.prettyText : exchange.text,
                                        forType: .string)
                                } label: {
                                    Label("Copy", systemImage: "doc.on.doc")
                                }.help("Copy response body")
                                Button {
                                    export(exchange)
                                } label: {
                                    Label("Export", systemImage: "square.and.arrow.up")
                                }.help("Export response")
                            }.font(.caption).padding(.horizontal, 20).padding(.vertical, 8)
                        }
                        if section == "Body" {
                            if exchange.previewIsTruncated {
                                Text(
                                    "Preview limited to \(ByteCountFormatter.string(fromByteCount: Int64(exchange.previewByteLimit), countStyle: .file)). Export or copy retained bytes to inspect more."
                                )
                                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20)
                            }
                            ResponseBodyPreview(
                                exchange: exchange, pretty: pretty, fontSize: fontSize
                            ).id(
                                exchange.id)
                        } else if section == "Headers" {
                            List(exchange.headers) { field in
                                HStack(alignment: .top) {
                                    Text(field.name).fontWeight(.medium).frame(
                                        width: 190, alignment: .leading)
                                    Text(field.value).textSelection(.enabled).frame(
                                        maxWidth: .infinity, alignment: .leading)
                                    Button {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(
                                            field.value, forType: .string)
                                    } label: {
                                        Image(systemName: "doc.on.doc")
                                    }.buttonStyle(.plain).help("Copy header value")
                                }.font(.system(size: 11, design: .monospaced))
                            }
                        } else if section == "Timeline" {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 12) {
                                    ForEach(exchange.events ?? []) { event in
                                        HStack {
                                            Text(String(format: "%.1f ms", event.elapsed * 1000))
                                                .frame(
                                                    width: 100, alignment: .leading)
                                            Text(event.title)
                                        }
                                    }
                                    Text(
                                        "Monotonic elapsed transport milestones. Local preparation precedes this timeline; DNS, connection and TLS phases are not separately measured."
                                    ).font(.caption).foregroundStyle(.secondary)
                                }.font(.system(size: fontSize, design: .monospaced)).frame(
                                    maxWidth: .infinity, maxHeight: .infinity,
                                    alignment: .topLeading
                                ).padding(20)
                            }
                        } else if section == "Request" {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text("Effective response URL: " + exchange.url).textSelection(
                                        .enabled)
                                    if let summary = exchange.preparedRequest {
                                        Text(summary.method + " " + summary.url).textSelection(
                                            .enabled)
                                        Text("TLS: " + (summary.tlsPolicy ?? "System trust"))
                                        if let limit = exchange.downloadLimit {
                                            Text(
                                                "Download budget: "
                                                    + ByteCountFormatter.string(
                                                        fromByteCount: Int64(limit),
                                                        countStyle: .file))
                                        }
                                        Button("Export redacted prepared request…") {
                                            exportPrepared(summary)
                                        }
                                        Text(
                                            "Prepared body: \(summary.bodyBytes.map { String($0) + " bytes" } ?? "none")"
                                        )
                                        ForEach(summary.headers) { field in
                                            Text(field.name + ": " + field.value).textSelection(
                                                .enabled)
                                        }
                                    }
                                    Text(
                                        "Initial prepared request before redirects and transport-added headers. Query values and custom header values are masked; URL paths and response URLs may still contain sensitive data. Timing is total elapsed time; DNS/connect/TLS phases are not measured."
                                    ).foregroundStyle(.secondary)
                                }.font(.system(size: fontSize, design: .monospaced)).frame(
                                    maxWidth: .infinity, alignment: .leading
                                ).padding(20)
                            }
                        } else if exchange.checks.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Label("Add response checks", systemImage: "checkmark.seal").font(
                                    .callout.weight(.medium))
                                Text(
                                    "Set an expected status or body match in the request’s Checks tab."
                                )
                                .font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
                        } else {
                            List(exchange.checks) { check in
                                Label(
                                    check.title,
                                    systemImage: check.passed
                                        ? "checkmark.circle.fill" : "xmark.circle.fill"
                                ).foregroundStyle(check.passed ? Color.green : Color.red)
                            }
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }.clipped()

            } else {
                VStack(spacing: 12) {
                    Image(systemName: "arrow.up.right.circle").font(
                        .system(size: 34, weight: .ultraLight)
                    ).foregroundStyle(.tertiary)
                    Text("Ready for a response").font(.system(size: 18, weight: .medium))
                    Text("Send your request to explore the body, headers and checks here.").font(
                        .callout
                    ).foregroundStyle(.secondary)
                    Button {
                        store.send()
                    } label: {
                        Label("Send request  ⌘↵", systemImage: "arrow.up.right")
                    }.buttonStyle(RillButtonStyle()).disabled(
                        store.selected?.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            != false || !store.canEdit
                    ).padding(.top, 3)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        #if DEBUG
            .onReceive(RillPreview.responseSections) { section = $0 }
        #endif
    }
    private func validationBanner(_ exchange: Exchange) -> some View {
        let failed = exchange.checks.filter { !$0.passed }.count
        let color: Color = failed > 0 ? .red : exchange.checks.isEmpty ? .secondary : .green
        let title =
            failed > 0
            ? "\(failed) of \(exchange.checks.count) checks failed"
            : exchange.checks.isEmpty
                ? "No checks configured" : "\(exchange.checks.count) checks passed"
        return HStack(spacing: 8) {
            Image(
                systemName: failed > 0
                    ? "xmark.circle.fill"
                    : exchange.checks.isEmpty ? "info.circle" : "checkmark.circle.fill"
            )
            .foregroundStyle(color)
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(color).lineLimit(1)
            Spacer(minLength: 6)
            if !exchange.checks.isEmpty && section != "Checks" {
                Button("Review checks") { section = "Checks" }.font(.caption)
            }
        }
        .help(
            failed > 0
                ? "HTTP \(exchange.status) was received, but configured validation failed. Review individual checks for details."
                : exchange.checks.isEmpty
                    ? "HTTP status alone does not validate the result. Configure request checks to validate responses."
                    : "The response satisfied every configured check."
        )
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(color.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 4)
    }

    private func exportPrepared(_ summary: PreparedRequestSummary) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "prepared-request.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do { try await Task.detached { try summary.write(to: url) }.value } catch {
                NSAlert(error: error).runModal()
            }
        }
    }
    private func export(_ exchange: Exchange) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "response.bin"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try exchange.body.write(to: url, options: .atomic) } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }
}
