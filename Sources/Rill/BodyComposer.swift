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
            }.pickerStyle(.segmented)
            if request.method == .GET || request.method == .HEAD {
                Text("GET and HEAD require no body with this transport. Choose None to retain inactive body settings.").font(.caption).foregroundStyle(.secondary)
            }
            switch request.bodyMode {
            case .none?: Text("No request body. Other body settings are retained.").foregroundStyle(.secondary)
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
