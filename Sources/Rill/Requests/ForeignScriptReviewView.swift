import RillCore
import SwiftUI

struct ForeignScriptReviewView: View {
    @EnvironmentObject private var store: WorkbenchStore
    @SwiftUI.Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Imported scripts · Disabled").font(.title2)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            Text(
                "Retained for review only. Rill does not execute this source or provide an enable action. Scripts may contain secrets and remain plain text in workspace exports and backups."
            ).font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(
                        Array((store.selected?.foreignScripts ?? []).enumerated()), id: \.offset
                    ) { _, script in
                        Text(script.origin + " · " + script.stage).font(.headline)
                        Text(script.source).font(.system(.body, design: .monospaced)).textSelection(
                            .enabled
                        ).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(24).frame(width: 850, height: 600)
    }
}
