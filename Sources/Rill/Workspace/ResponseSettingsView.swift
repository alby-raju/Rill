import RillCore
import SwiftUI

struct ResponseSettingsView: View {
    @EnvironmentObject private var store: WorkbenchStore
    private func mib(_ key: WritableKeyPath<ResponseSettings, Int>) -> Binding<Int> {
        Binding(
            get: { store.responseSettings[keyPath: key] / (1024 * 1024) },
            set: { store.responseSettings[keyPath: key] = $0 * 1024 * 1024 })
    }
    var body: some View {
        Section("Response limits (next Send)") {
            Stepper(
                "Download: \(store.responseSettings.downloadBytes / (1024 * 1024)) MiB",
                value: mib(\.downloadBytes), in: 1...256)
            Stepper(
                "Preview: \(store.responseSettings.previewBytes / 1024) KiB",
                value: Binding(
                    get: { store.responseSettings.previewBytes / 1024 },
                    set: { store.responseSettings.previewBytes = $0 * 1024 }), in: 1...8192,
                step: 128)
            Stepper(
                "Session history: \(store.responseSettings.sessionCount) exchanges",
                value: $store.responseSettings.sessionCount, in: 0...500)
            Stepper(
                "Session body budget: \(store.responseSettings.sessionBytes / (1024 * 1024)) MiB",
                value: mib(\.sessionBytes), in: 1...256)
        }
        Section("Durable response snapshots") {
            Toggle("Record snapshots on this Mac", isOn: $store.responseSettings.recordSnapshots)
            Toggle(
                "Retain response bodies in snapshots",
                isOn: $store.responseSettings.retainSnapshotBodies)
            Text(
                "Snapshots retain request names, URL paths and response metadata. Query/header values are masked. Bodies may contain credentials or private data and are omitted by default. Disabling recording leaves existing snapshots until Clear History."
            ).font(.caption).foregroundStyle(.secondary)
            Stepper(
                "Snapshots: \(store.responseSettings.snapshotCount)",
                value: $store.responseSettings.snapshotCount, in: 1...500)
            Stepper(
                "Body per snapshot: \(store.responseSettings.snapshotBodyBytes / 1024) KiB",
                value: Binding(
                    get: { store.responseSettings.snapshotBodyBytes / 1024 },
                    set: { store.responseSettings.snapshotBodyBytes = $0 * 1024 }), in: 0...8192,
                step: 128)
            Stepper(
                "Total snapshot body budget: \(store.responseSettings.snapshotTotalBodyBytes / (1024 * 1024)) MiB",
                value: mib(\.snapshotTotalBodyBytes), in: 1...16)
            Text(store.historyStatus).font(.caption).foregroundStyle(.secondary)
            Button("Clear History…") { store.clearHistory() }
        }
    }
}
