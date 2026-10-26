import RillCore
import SwiftUI

struct RequestTransfer: Identifiable {
    let id = UUID()
    let requestID: UUID
    let copy: Bool
}

struct RequestTransferSheet: View {
    @EnvironmentObject var store: WorkbenchStore
    @SwiftUI.Environment(\.dismiss) private var dismiss
    let transfer: RequestTransfer
    @ViewState private var destination: UUID?
    @ViewState private var search = ""
    @ViewState private var failure: String?
    private var request: RequestDraft? {
        store.editor.request(transfer.requestID, in: store.workspace)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(
                transfer.copy ? "Copy request" : "Move request",
                systemImage: transfer.copy ? "doc.on.doc" : "folder"
            )
            .font(.title2.weight(.semibold))
            Text(request?.name ?? "Request no longer available").foregroundStyle(.secondary)
                .lineLimit(2)
            TextField("Find a collection", text: $search).textFieldStyle(RillTextFieldStyle())
            ScrollView {
                LazyVStack(spacing: 4) {
                    SelectionRow(
                        title: "Unfiled", detail: "Keep outside collections", icon: "tray",
                        selected: destination == nil
                    ) { destination = nil }
                    ForEach(
                        store.workspace.collections.filter {
                            search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)
                        }
                    ) { collection in
                        SelectionRow(
                            title: collection.name,
                            detail: collection.id == request?.collectionID
                                ? "Current collection" : "", selected: destination == collection.id
                        ) { destination = collection.id }
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            Text(
                "Destination: "
                    + (store.workspace.collections.first(where: { $0.id == destination })?.name
                        ?? "Unfiled")
            )
            .font(.caption.weight(.semibold)).lineLimit(2)
            Text(
                transfer.copy
                    ? "Creates a new request with the visible settings, including unsaved edits."
                    : "Keeps the request identity, history and unsaved edits."
            )
            .font(.caption).foregroundStyle(.secondary)
            if let failure { Text(failure).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(transfer.copy ? "Copy here" : "Move here") {
                    do {
                        try store.transferRequest(
                            transfer.requestID, to: destination, copy: transfer.copy)
                        dismiss()
                    } catch { failure = error.localizedDescription }
                }.buttonStyle(RillButtonStyle(emphasis: .primary)).keyboardShortcut(.defaultAction)
                    .disabled(
                        request == nil || (!transfer.copy && destination == request?.collectionID))
            }
        }.padding(24).frame(width: 510, height: 510).background(RillPalette.canvas).buttonStyle(
            RillButtonStyle()
        )
        .onAppear { destination = request?.collectionID }
    }
}
