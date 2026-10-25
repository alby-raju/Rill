import RillCore
import SwiftUI

struct RequestSearch: View {
    @EnvironmentObject var store: WorkbenchStore
    @SwiftUI.Environment(\.dismiss) var dismiss
    @ViewState<String> private var query = ""
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "magnifyingglass")
                TextField("Find requests, collections, environments or history", text: $query)
                    .textFieldStyle(.plain).focused($focused)
                Button("Done") { dismiss() }
            }
            Divider()
            List(store.searchResults(query)) { result in
                Button {
                    dismiss()
                    Task { @MainActor in
                        await Task.yield()
                        store.activateSearch(result)
                    }
                } label: {
                    HStack {
                        Text(result.kind.rawValue.capitalized).font(.caption).foregroundStyle(
                            .secondary
                        ).frame(width: 90)
                        VStack(alignment: .leading) {
                            Text(result.title)
                            Text(result.detail).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                    }
                }.buttonStyle(.plain).padding(.vertical, 6)
            }
        }.padding(24).frame(width: 720, height: 400).onAppear { focused = true }
    }
}
