import RillCore
import SwiftUI

struct EnvironmentEditor: View {
    @EnvironmentObject var store: WorkbenchStore
    @SwiftUI.Environment(\.dismiss) var dismiss
    @ViewState private var selected: UUID?
    @ViewState private var pendingDeletion: RillCore.Environment?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                RillToolHeading(
                    title: "Environments", subtitle: "Manage reusable variables and inheritance.",
                    icon: "square.stack.3d.up")
                Spacer()
                Button("Done") {
                    store.persist()
                    dismiss()
                }
                .buttonStyle(RillButtonStyle()).keyboardShortcut(.defaultAction)
            }
            HSplitView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("VARIABLE SETS · \(store.workspace.environments.count)")
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    ScrollView {
                        LazyVStack(spacing: 5) {
                            ForEach(store.workspace.environments) { environment in
                                SelectionRow(
                                    title: environment.name,
                                    detail: "\(environment.variables.count) variables",
                                    icon: "square.stack.3d.up", selected: selected == environment.id
                                ) { selected = environment.id }
                            }
                            if store.workspace.environments.isEmpty {
                                Text("No environments yet").font(.callout).foregroundStyle(
                                    .secondary
                                ).padding(.vertical, 20)
                            }
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    Button("New environment", systemImage: "plus", action: create)
                        .buttonStyle(RillButtonStyle(emphasis: .primary))
                }.padding(14).frame(
                    minWidth: 210, idealWidth: 235, maxWidth: 270, maxHeight: .infinity
                )
                .background(RillPalette.surface, in: RoundedRectangle(cornerRadius: 12))
                Group {
                    if let environment = store.workspace.environments.first(where: {
                        $0.id == selected
                    }) {
                        editor(environment).id(environment.id)
                    } else {
                        VStack(spacing: 15) {
                            Image(systemName: "square.stack.3d.up").font(.system(size: 38))
                                .foregroundStyle(RillPalette.accent)
                            Text("Your API, in every environment").font(.title3.weight(.semibold))
                            Text(
                                store.workspace.environments.isEmpty
                                    ? "Create a variable set, then select it from the Workbench."
                                    : "Select a variable set to edit its name, parent and values."
                            )
                            .foregroundStyle(.secondary).multilineTextAlignment(.center)
                            Button(
                                "New environment", systemImage: "plus", action: create
                            )
                            .buttonStyle(RillButtonStyle(emphasis: .primary))
                        }.padding(26).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }.frame(minWidth: 430, maxWidth: .infinity, maxHeight: .infinity)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.padding(24).frame(width: 900, height: 590).rillToolControls()
            .alert(
                "Delete environment?",
                isPresented: Binding(
                    get: { pendingDeletion != nil },
                    set: { if !$0 { pendingDeletion = nil } }),
                presenting: pendingDeletion
            ) { environment in
                Button("Delete", role: .destructive) { delete(environment.id) }
                Button("Cancel", role: .cancel) {}
            } message: { environment in
                Text(
                    "“\(environment.name)” and its variables will be removed. Environments that inherit from it will lose that parent."
                )
            }
            .onAppear {
                selected =
                    store.workspace.selectedEnvironmentID ?? store.workspace.environments.first?.id
            }
            .onDisappear { store.persist() }
    }
    private func create() {
        var suffix = 1
        let names = Set(store.workspace.environments.map(\.name))
        var name = "New environment"
        while names.contains(name) {
            suffix += 1
            name = "New environment \(suffix)"
        }
        let environment = RillCore.Environment(name: name)
        store.workspace.environments.append(environment)
        selected = environment.id
        store.persist()
    }
    private func delete(_ id: UUID) {
        selected = store.workspace.environments.first { $0.id != id }?.id
        WorkspaceOperations.deleteEnvironment(id, in: &store.workspace)
        store.persist()
    }

    private func editor(_ original: RillCore.Environment) -> some View {
        let environment = $store.workspace.environments.element(original)
        return VStack(alignment: .leading, spacing: 14) {
            RillSection(
                title: "Variable set", subtitle: "Child values override variables from the parent.",
                icon: "square.stack.3d.up"
            ) {
                TextField("Environment name", text: environment.name)
                    .accessibilityLabel("Environment name")
                RillSelect(
                    title: "Inherits from",
                    value: store.workspace.environments.first {
                        $0.id == original.parentID
                    }?.name ?? "No parent environment",
                    selection: environment.parentID
                ) {
                    Text("No parent environment").tag(nil as UUID?)
                    ForEach(
                        EnvironmentResolver.validParents(
                            for: original.id, in: store.workspace.environments)
                    ) { Text($0.name).tag(Optional($0.id)) }
                }
            }
            FieldEditor(fields: environment.variables, noun: "variable")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .rillToolPanel()
            RillNotice(
                text:
                    "Use {{name}} in URLs, headers, bodies or auth. Use named secrets for credentials.",
                icon: "curlybraces")
            Button("Delete environment", systemImage: "trash", role: .destructive) {
                pendingDeletion = original
            }.foregroundStyle(.red)
        }.padding(.leading, 16).padding(.vertical, 2)
    }
}
