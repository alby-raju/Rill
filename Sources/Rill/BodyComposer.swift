import SwiftUI
import RillCore

struct BodyComposer: View {
    @EnvironmentObject private var store: WorkbenchStore
    @Binding var request: RequestDraft
    private var mode: Binding<RequestBodyMode> { Binding(get: { request.bodyMode ?? .text }, set: { request.bodyMode = $0 }) }
    var body: some View {
        VStack(spacing: 8) {
            Picker("Body", selection: mode) {
                ForEach(RequestBodyMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.menu)
            if request.method == .GET || request.method == .HEAD {
                Text("GET and HEAD require no body with this transport. Choose None to retain inactive body settings.").font(.caption).foregroundStyle(.secondary)
            }
            switch request.bodyMode {
            case .none?: Text("No request body. Other body settings are retained.").foregroundStyle(.secondary)
            case .binary?:
                HStack {
                    Button("Select file…") {
                        let panel = NSOpenPanel(); panel.canChooseDirectories = false
                        if panel.runModal() == .OK, let url = panel.url {
                            do { request.binaryFile = try UploadFileReference.capture(url) } catch { store.error = error.localizedDescription }
                        }
                    }
                    Text(request.binaryFile?.path ?? "No file selected").lineLimit(2).textSelection(.enabled)
                }
                TextField("Content type", text: $request.contentType)
                Text("Files are streamed through a private temporary snapshot, up to 256 MiB. Changed files must be selected again. Exports retain paths and metadata, not file contents.").font(.caption).foregroundStyle(.secondary)
            case .multipart?: MultipartComposer(parts: Binding(get: { request.multipartParts ?? [] }, set: { request.multipartParts = $0 }))
            case .form?: FieldEditor(fields: Binding(get: { request.formFields ?? [] }, set: { request.formFields = $0 }), noun: "form field")
            default:
                HStack {
                    Picker("Content type", selection: $request.contentType) {
                        Text("JSON").tag("application/json"); Text("Text").tag("text/plain"); Text("XML").tag("application/xml"); Text("Raw form").tag("application/x-www-form-urlencoded")
                    }.frame(width: 220)
                    Spacer()
                    Button("Format JSON") {
                        do { request.body = try JSONTextFormatter.pretty(request.body) }
                        catch { store.error = error.localizedDescription }
                    }.disabled(request.contentType != "application/json")
                }
                CodeEditor(text: $request.body, contentType: request.contentType, completions: InputSuggestions.variables(in: store.environment)).id(request.id)
                if request.bodyMode == nil && request.body.isEmpty {
                    Text("Legacy empty bodies send no payload. Select Raw text explicitly to send empty text.").font(.caption).foregroundStyle(.secondary)
                    Button("Use explicit empty text") { request.bodyMode = .text }
                }
            }
        }.padding(16)
    }
}

private struct MultipartComposer: View {
    @EnvironmentObject private var store: WorkbenchStore
    @Binding var parts: [MultipartPart]
    @ViewState<MultipartPart?> private var editing: MultipartPart?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach($parts) { $part in
                    HStack {
                        Toggle("Enabled", isOn: $part.enabled).labelsHidden()
                        TextField("Name", text: $part.name)
                        Text(part.kind.rawValue).foregroundStyle(.secondary)
                        Button("Edit…") { editing = part }
                        Button { move(part.id, by: -1) } label: { Image(systemName: "arrow.up") }.help("Move part earlier")
                        Button { move(part.id, by: 1) } label: { Image(systemName: "arrow.down") }.help("Move part later")
                        Button { parts.removeAll { $0.id == part.id } } label: { Image(systemName: "minus.circle") }.help("Remove part")
                    }
                }
                Button("Add part", systemImage: "plus") { var part = MultipartPart(); part.name = "field"; parts.append(part); editing = part }
                Text("The generated boundary and content type always match the body. Exports include file paths and metadata, not attached files. Total upload limit: 256 MiB.").font(.caption).foregroundStyle(.secondary)
            }
        }.sheet(item: $editing) { part in
            MultipartPartEditor(original: part) { updated in
                if let index = parts.firstIndex(where: { $0.id == updated.id }) { parts[index] = updated }
                editing = nil
            }
        }
    }
    private func move(_ id: UUID, by offset: Int) {
        guard let index = parts.firstIndex(where: { $0.id == id }), parts.indices.contains(index + offset) else { return }
        parts.swapAt(index, index + offset)
    }
}
private struct MultipartPartEditor: View {
    @SwiftUI.Environment(\.dismiss) private var dismiss
    @ViewState<MultipartPart> private var draft: MultipartPart
    let apply: (MultipartPart) -> Void
    init(original: MultipartPart, apply: @escaping (MultipartPart) -> Void) { _draft = ViewState(wrappedValue: original); self.apply = apply }
    @ViewState<String?> private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit multipart part").font(.title2)
            TextField("Name", text: $draft.name)
            Picker("Kind", selection: $draft.kind) { ForEach(MultipartPartKind.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
            if draft.kind == .file {
                Button("Select file…") {
                    let panel = NSOpenPanel(); panel.canChooseDirectories = false
                    if panel.runModal() == .OK, let url = panel.url {
                        do { draft.file = try UploadFileReference.capture(url); draft.filename = url.lastPathComponent; draft.contentType = "application/octet-stream" }
                        catch { self.error = error.localizedDescription }
                    }
                }
                Text(draft.file?.path ?? "No file selected").textSelection(.enabled)
                TextField("Filename", text: $draft.filename)
            } else {
                CodeEditor(text: $draft.value, contentType: draft.kind == .json ? "application/json" : draft.contentType, completions: [])
            }
            if draft.kind != .json { TextField("Content type", text: $draft.contentType) }
            if let error { Text(error).foregroundStyle(.red) }
            HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Button("Apply") { apply(draft) }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 650, height: 450)
    }
}
