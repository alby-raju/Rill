import RillCore
import SwiftUI

struct WorkflowEditor: View {
    @Binding var request: RequestDraft
    @ViewState<String> private var stage = "Rules"
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if request.apiLink != nil {
                HStack {
                    Toggle(
                        "Check linked API contract",
                        isOn: Binding(
                            get: { request.apiLink?.checkContract ?? false },
                            set: { request.apiLink?.checkContract = $0 }))
                    Button("Unlink API source") { request.apiLink = nil }
                }
                Text(request.apiLink?.operationKey ?? "").font(.caption).foregroundStyle(.secondary)
            }
            RillTabs(
                titles: ["Rules & extraction", "Pre-request", "Post-response"],
                selection: Binding(
                    get: {
                        stage == "Rules"
                            ? "Rules & extraction"
                            : stage == "Pre" ? "Pre-request" : "Post-response"
                    },
                    set: {
                        stage =
                            $0 == "Rules & extraction"
                            ? "Rules" : $0 == "Pre-request" ? "Pre" : "Post"
                    }))
            if stage == "Rules" {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label("Assertions", systemImage: "checkmark.seal").font(
                                .system(size: 14, weight: .semibold))
                            Spacer()
                            Text("\((request.assertions ?? []).count) rules").font(.caption)
                                .foregroundStyle(.secondary)
                            Button("Add assertion", systemImage: "plus") {
                                if request.assertions == nil { request.assertions = [] }
                                request.assertions?.append(ResponseAssertion())
                            }.disabled((request.assertions?.count ?? 0) >= 128)
                        }
                        if (request.assertions ?? []).isEmpty {
                            RillNotice(
                                text:
                                    "Make the expected result explicit. Add a status, header or JSON assertion to catch unexpected responses.",
                                icon: "checkmark.circle")
                        }
                        ForEach(Array((request.assertions ?? []).enumerated()), id: \.element.id) {
                            index, _ in
                            HStack {
                                Toggle("Enabled", isOn: assertion(index, \.enabled)).labelsHidden()
                                RillSelect(
                                    title: "Assertion kind",
                                    value: assertion(index, \.kind).wrappedValue.rawValue,
                                    selection: assertion(index, \.kind)
                                ) {
                                    ForEach(AssertionKind.allCases, id: \.self) {
                                        Text($0.rawValue).tag($0)
                                    }
                                }.frame(width: 150)
                                TextField("Header or JSON path", text: assertion(index, \.selector))
                                TextField(
                                    "Expected (JSON for jsonEquals)",
                                    text: assertion(index, \.expected))
                                Button("Remove") { request.assertions?.remove(at: index) }
                            }
                        }
                        Divider().padding(.vertical, 8)
                        HStack {
                            Label("Capture variables", systemImage: "arrow.down.doc").font(
                                .system(size: 14, weight: .semibold))
                            Spacer()
                            Button("Add extraction", systemImage: "plus") {
                                if request.extractions == nil { request.extractions = [] }
                                request.extractions?.append(ResponseExtraction())
                            }.disabled((request.extractions?.count ?? 0) >= 128)
                        }
                        if (request.extractions ?? []).isEmpty {
                            RillNotice(
                                text:
                                    "Capture a response value and reuse it in the next request of a run.",
                                icon: "arrow.triangle.branch")
                        }
                        ForEach(Array((request.extractions ?? []).enumerated()), id: \.element.id) {
                            index, _ in
                            HStack {
                                Toggle("Enabled", isOn: extraction(index, \.enabled)).labelsHidden()
                                RillSelect(
                                    title: "Extraction kind",
                                    value: extraction(index, \.kind).wrappedValue.rawValue,
                                    selection: extraction(index, \.kind)
                                ) {
                                    ForEach(ExtractionKind.allCases, id: \.self) {
                                        Text($0.rawValue).tag($0)
                                    }
                                }.frame(width: 100)
                                TextField(
                                    "Header or JSON path", text: extraction(index, \.selector))
                                TextField("Variable name", text: extraction(index, \.variable))
                                Button("Remove") { request.extractions?.remove(at: index) }
                            }
                        }
                        Text(
                            "JSON paths support $.field[0] or JSON Pointer /field/0. Missing/invalid values fail. Variables propagate only after a successful step; saved environments stay unchanged."
                        ).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
                Toggle(
                    "Enable this reviewed native hook",
                    isOn: Binding(
                        get: { currentHook.enabled },
                        set: {
                            var hook = currentHook
                            hook.enabled = $0
                            setHook(hook)
                        }))
                Text(
                    "json-operations-v1: finite JSON operations; JavaScript is unsupported. Hooks run only when enabled. Sources are plain text and may contain secrets. Imported hooks start disabled."
                ).font(.caption).foregroundStyle(.secondary)
                CodeEditor(
                    text: Binding(
                        get: { currentHook.source },
                        set: {
                            var hook = currentHook
                            hook.source = $0
                            setHook(hook)
                        }), contentType: "application/json", completions: [])
                Text(
                    #"Example: [{"op":"uuid","name":"nonce"},{"op":"header","name":"X-Nonce","value":"{{nonce}}"}]"#
                ).font(.caption).textSelection(.enabled)
            }
        }.padding(18).buttonStyle(RillButtonStyle()).textFieldStyle(RillTextFieldStyle())
    }
    private var currentHook: RequestHook {
        (stage == "Pre" ? request.preHook : request.postHook) ?? RequestHook()
    }
    private func setHook(_ hook: RequestHook) {
        if stage == "Pre" { request.preHook = hook } else { request.postHook = hook }
    }
    private func assertion<T>(_ index: Int, _ key: WritableKeyPath<ResponseAssertion, T>)
        -> Binding<T>
    {
        Binding(
            get: {
                (request.assertions?.indices.contains(index) == true
                    ? request.assertions![index] : ResponseAssertion())[keyPath: key]
            },
            set: {
                if request.assertions?.indices.contains(index) == true {
                    request.assertions?[index][keyPath: key] = $0
                }
            })
    }
    private func extraction<T>(_ index: Int, _ key: WritableKeyPath<ResponseExtraction, T>)
        -> Binding<T>
    {
        Binding(
            get: {
                (request.extractions?.indices.contains(index) == true
                    ? request.extractions![index] : ResponseExtraction())[keyPath: key]
            },
            set: {
                if request.extractions?.indices.contains(index) == true {
                    request.extractions?[index][keyPath: key] = $0
                }
            })
    }
}
