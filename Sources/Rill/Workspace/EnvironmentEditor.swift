import SwiftUI
import RillCore

struct EnvironmentEditor: View {
    @EnvironmentObject var store: WorkbenchStore
    @SwiftUI.Environment(\.dismiss) var dismiss
    @ViewState<UUID?> private var selected: UUID?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { VStack(alignment: .leading, spacing: 4) { Text("Environments").font(.title2.weight(.semibold)); Text("One request. Every stage of your API.").foregroundStyle(.secondary) }; Spacer(); Button("Done") { store.persist(); dismiss() }.keyboardShortcut(.defaultAction) }
            HSplitView {
                VStack {
                    List(selection: $selected) { ForEach(store.workspace.environments) { Text($0.name).tag($0.id) } }
                    Button("New environment", systemImage: "plus") { let environment = RillCore.Environment(name: "New environment"); store.workspace.environments.append(environment); selected = environment.id; store.persist() }
                }.frame(minWidth: 180, maxWidth: 220)
                if let index = store.workspace.environments.firstIndex(where: { $0.id == selected }) {
                    VStack(alignment: .leading) {
                        TextField("Environment name", text: $store.workspace.environments[index].name).font(.title3).textFieldStyle(RillTextFieldStyle()).padding(16)
                        Picker("Inherits from", selection: $store.workspace.environments[index].parentID) {
                            Text("None").tag(nil as UUID?)
                            ForEach(EnvironmentResolver.validParents(for: store.workspace.environments[index].id, in: store.workspace.environments)) { parent in Text(parent.name).tag(Optional(parent.id)) }
                        }.padding(.horizontal, 16)
                        FieldEditor(fields: $store.workspace.environments[index].variables, noun: "variable")
                        Text("Use {{name}} in URLs, headers, body or auth. Environment values are stored in plain text; keep tokens in the request’s Auth tab.").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16)
                        Button("Delete environment", role: .destructive) { if let selected { WorkspaceOperations.deleteEnvironment(selected, in: &store.workspace) }; selected = nil; store.persist() }.padding(16)
                    }
                } else { ContentUnavailableView("Choose an environment", systemImage: "square.stack.3d.up", description: Text("Create Local, Staging or Production variable sets.")) }
            }
        }.padding(24).frame(width: 800, height: 500)
            .onAppear { selected = store.workspace.selectedEnvironmentID ?? store.workspace.environments.first?.id }
            .onDisappear { store.persist() }
    }
}
