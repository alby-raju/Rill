import RillCore
import SwiftUI

struct EnvironmentEditor: View {
    @EnvironmentObject var store: WorkbenchStore
    @SwiftUI.Environment(\.dismiss) var dismiss
    @ViewState private var selected: UUID?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Label("Environments", systemImage: "square.stack.3d.up").font(
                        .title2.weight(.semibold))
                    Text("Keep local, staging and production variables together.").font(.callout)
                        .foregroundStyle(.secondary)
                }
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
                    if let index = store.workspace.environments.firstIndex(where: {
                        $0.id == selected
                    }) {
                        editor(index).id(store.workspace.environments[index].id)
                    } else {
                        VStack(spacing: 15) {
                            Image(systemName: "square.stack.3d.up").font(.system(size: 38))
                                .foregroundStyle(RillPalette.accent)
                            Text("Your API, in every environment").font(.title3.weight(.semibold))
                            Text("Create a variable set, then select it from the Workbench.")
                                .foregroundStyle(.secondary).multilineTextAlignment(.center)
                            Button(
                                "Create your first environment", systemImage: "plus", action: create
                            )
                            .buttonStyle(RillButtonStyle(emphasis: .primary))
                        }.padding(26).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }.frame(minWidth: 430, maxWidth: .infinity, maxHeight: .infinity)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.padding(24).frame(width: 900, height: 590).background(RillPalette.canvas).textFieldStyle(
            RillTextFieldStyle()
        ).buttonStyle(
            RillButtonStyle()
        )
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
    private func editor(_ index: Int) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("Environment name", text: $store.workspace.environments[index].name)
                .font(.title3.weight(.semibold)).textFieldStyle(RillTextFieldStyle())
            RillSelect(
                title: "Inherits from",
                value: store.workspace.environments.first(where: {
                    $0.id == store.workspace.environments[index].parentID
                })?.name ?? "No parent environment",
                selection: $store.workspace.environments[index].parentID
            ) {
                Text("No parent environment").tag(nil as UUID?)
                ForEach(
                    EnvironmentResolver.validParents(
                        for: store.workspace.environments[index].id,
                        in: store.workspace.environments)
                ) { Text($0.name).tag(Optional($0.id)) }
            }
            FieldEditor(fields: $store.workspace.environments[index].variables, noun: "variable")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Text(
                "Use {{name}} in URLs, headers, body or auth. Values are stored in plain text; use named secrets for tokens."
            )
            .font(.caption).foregroundStyle(.secondary)
            Button("Delete environment", systemImage: "trash", role: .destructive) {
                let id = store.workspace.environments[index].id
                WorkspaceOperations.deleteEnvironment(id, in: &store.workspace)
                selected = store.workspace.environments.first?.id
                store.persist()
            }
        }.padding(.leading, 20).padding(.vertical, 6)
    }
}
