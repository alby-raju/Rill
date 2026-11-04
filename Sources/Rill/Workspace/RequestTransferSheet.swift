import RillCore
import SwiftUI

struct RequestTransfer: Identifiable {
    let id = UUID()
    let requestIDs: [UUID]
    let copy: Bool
}

struct RequestTransferSheet: View {
    @EnvironmentObject var store: WorkbenchStore
    @SwiftUI.Environment(\.dismiss) private var dismiss
    let transfer: RequestTransfer
    @ViewState private var destination: UUID?
    @ViewState<Bool> private var destinationChosen = false
    @ViewState private var search = ""
    @ViewState private var failure: String?
    private var requests: [RequestDraft] {
        transfer.requestIDs.compactMap { store.editor.request($0, in: store.workspace) }
    }
    var body: some View {
        let requests = requests
        let source = requests.first?.collectionID
        let sameCollection = !requests.isEmpty && requests.allSatisfy { $0.collectionID == source }
        VStack(alignment: .leading, spacing: 16) {
            Label(
                transfer.copy ? "Copy to collection" : "Move to collection",
                systemImage: transfer.copy ? "doc.on.doc" : "folder"
            )
            .font(.title2.weight(.semibold))
            Text(
                requests.count == 1
                    ? requests[0].name : "\(requests.count) requests selected"
            ).foregroundStyle(.secondary)
                .lineLimit(2)
            TextField("Find a collection", text: $search).textFieldStyle(RillTextFieldStyle())
            ScrollView {
                LazyVStack(spacing: 4) {
                    SelectionRow(
                        title: "Unfiled", detail: "Keep outside collections", icon: "tray",
                        selected: destinationChosen && destination == nil
                    ) { choose(nil) }
                    ForEach(
                        store.workspace.collections.filter {
                            search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)
                        }
                    ) { collection in
                        SelectionRow(
                            title: collection.name,
                            detail: sameCollection && collection.id == source
                                ? "Current collection" : "",
                            selected: destinationChosen && destination == collection.id
                        ) { choose(collection.id) }
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            Text(
                destinationChosen
                    ? "Destination: "
                        + (store.workspace.collections.first(where: { $0.id == destination })?.name
                            ?? "Unfiled") : "Choose a destination"
            )
            .font(.caption.weight(.semibold)).lineLimit(2)
            Text(
                transfer.copy
                    ? "Copies the current settings, including unsaved edits."
                    : "Keeps request identities, history and unsaved edits."
            )
            .font(.caption).foregroundStyle(.secondary)
            if let failure { Text(failure).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(transfer.copy ? "Copy here" : "Move here") {
                    do {
                        try store.transferRequests(
                            transfer.requestIDs, to: destination, copy: transfer.copy)
                        dismiss()
                    } catch { failure = error.localizedDescription }
                }.buttonStyle(RillButtonStyle(emphasis: .primary)).keyboardShortcut(.defaultAction)
                    .disabled(
                        !destinationChosen || requests.isEmpty
                            || requests.count != transfer.requestIDs.count
                            || (!transfer.copy && sameCollection
                                && destination == source)
                    )
            }
        }.padding(RillSpacing.sheet).frame(width: 510, height: 510).rillToolControls()
            .onAppear {
                if sameCollection { choose(source) }
            }
    }

    private func choose(_ id: UUID?) {
        destination = id
        destinationChosen = true
    }
}
