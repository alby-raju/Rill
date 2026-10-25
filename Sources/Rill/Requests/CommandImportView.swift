import SwiftUI
import RillCore

struct CommandImportView: View {
    @EnvironmentObject private var store: WorkbenchStore
    @SwiftUI.Environment(\.dismiss) private var dismiss
    @ViewState<Bool> private var har = false
    @ViewState<[CommandImport]> private var entries = []
    @ViewState<Int> private var entryIndex = 0
    @ViewState<String> private var input = ""
    @ViewState<CommandImport?> private var preview: CommandImport?
    @ViewState<String?> private var error: String?
    @ViewState<Bool> private var parsing = false
    @ViewState<Task<Void, Never>?> private var parseTask: Task<Void, Never>? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("Import request").font(.title2); Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction) }
            Text("Paste one command or a HAR JSON log. Review the selected request before Apply. Unsupported data fails explicitly.").font(.caption).foregroundStyle(.secondary)
            Toggle("HAR 1.2 JSON (select one captured request)", isOn: $har)
            TextEditor(text: $input).font(.system(.body, design: .monospaced)).frame(minHeight: 160)
            Button(parsing ? "Parsing…" : "Preview import") {
                let snapshot = input, isHAR = har; parsing = true; error = nil; preview = nil
                parseTask?.cancel()
                parseTask = Task {
                    let worker = Task.detached { try isHAR ? HARImporter.parse(Data(snapshot.utf8)) : [CommandImporter.parse(snapshot)] }
                    do {
                        let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                        if input == snapshot && !Task.isCancelled { entries = result; entryIndex = 0; preview = result.first }
                    } catch { if input == snapshot && !Task.isCancelled { self.error = error.localizedDescription } }
                    parsing = false
                }
            }.disabled(parsing || input.isEmpty)
            if har && !entries.isEmpty {
                Picker("Captured request", selection: $entryIndex) {
                    ForEach(entries.indices, id: \.self) { Text(entries[$0].request.name).tag($0) }
                }.onChange(of: entryIndex) { _, index in if entries.indices.contains(index) { preview = entries[index] } }
            }
            if let preview {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(preview.request.method.rawValue + " " + preview.request.url).textSelection(.enabled)
                        Text("Body: " + (preview.request.bodyMode?.rawValue ?? "Raw text") + " · Auth: " + preview.request.auth.rawValue)
                        if !preview.request.credential.isEmpty { Text("The imported auth value will be stored in Keychain on Apply.").font(.caption) }
                        ForEach(Array(preview.warnings.enumerated()), id: \.offset) { Text($0.element).font(.caption).foregroundStyle(.secondary) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 190)
                HStack { Spacer(); Button("Apply Import") { Task { if await store.importCommand(preview) { dismiss() } } }.keyboardShortcut(.defaultAction) }
            }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
        }.padding(24).frame(width: 800, height: 620).disabled(store.importing)
        .onChange(of: input) { _, _ in parseTask?.cancel(); entries = []; preview = nil; error = nil }
        .onChange(of: har) { _, _ in parseTask?.cancel(); entries = []; preview = nil; error = nil }
        .onDisappear { parseTask?.cancel(); input = ""; preview = nil }
    }
}
