import RillCore
import SwiftUI

struct HistoryView: View {
    @ViewState<String?> private var comparison: String?
    @ViewState<Bool> private var comparing = false
    @ViewState<Task<Void, Never>?> private var comparisonTask: Task<Void, Never>? = nil
    @EnvironmentObject var store: WorkbenchStore
    @SwiftUI.Environment(\.dismiss) var dismiss
    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Response history").font(.title2.weight(.semibold))
                Spacer()
                Button("Clear") { store.clearHistory() }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            HStack {
                Text(store.historyStatus).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let selected = store.workspace.history.first(where: {
                    $0.id == store.inspectedHistoryID
                }) {
                    Menu(comparing ? "Comparing…" : "Compare JSON with…") {
                        ForEach(store.workspace.history.filter { $0.id != selected.id }) { other in
                            Button(
                                other.requestName + " · "
                                    + other.date.formatted(date: .omitted, time: .standard)
                            ) {
                                comparing = true
                                comparisonTask?.cancel()
                                comparisonTask = Task {
                                    let worker = Task.detached {
                                        try ResponseComparator.compare(selected, other).text
                                    }
                                    do {
                                        let result = try await withTaskCancellationHandler {
                                            try await worker.value
                                        } onCancel: {
                                            worker.cancel()
                                        }
                                        if !Task.isCancelled { comparison = result }
                                    } catch {
                                        if !Task.isCancelled {
                                            comparison = error.localizedDescription
                                        }
                                    }
                                    comparing = false
                                }
                            }
                        }
                    }.disabled(comparing)
                }
            }
            HSplitView {
                List(selection: $store.inspectedHistoryID) {
                    ForEach(store.workspace.history) { exchange in
                        VStack(alignment: .leading) {
                            Text("\(exchange.status) · \(exchange.requestName)")
                            Text(exchange.date, style: .time).font(.caption).foregroundStyle(
                                .secondary)
                        }.tag(exchange.id).padding(.vertical, 5)
                    }
                }.frame(minWidth: 200, idealWidth: 250)
                ResponseView(
                    exchange: store.workspace.history.first { $0.id == store.inspectedHistoryID },
                    running: false
                ).frame(minWidth: 500)
            }
        }.padding(24).frame(width: 1000, height: 600)
            .onDisappear { comparisonTask?.cancel() }
            .sheet(
                isPresented: Binding(
                    get: { comparison != nil }, set: { if !$0 { comparison = nil } })
            ) {
                VStack {
                    HStack {
                        Text("Semantic JSON comparison").font(.title2)
                        Spacer()
                        Button("Done") { comparison = nil }.keyboardShortcut(.defaultAction)
                    }
                    ScrollView([.vertical, .horizontal]) {
                        Text(comparison ?? "").font(.system(.body, design: .monospaced))
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.padding(24).frame(width: 750, height: 550)
            }
    }
}
