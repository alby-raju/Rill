import SwiftUI

struct LaunchView: View {
    var status: String
    var loading = true
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            Image(systemName: "water.waves").font(.system(size: 50, weight: .medium)).foregroundStyle(RillPalette.accent)
                .frame(width: 100, height: 100).background(RillPalette.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 26))
            Text("rill").font(.system(size: 38, weight: .bold, design: .rounded)).padding(.top, 20)
            Text("Your API workspace").font(.system(size: 15)).foregroundStyle(.secondary).padding(.top, 6)
            HStack(spacing: 10) {
                if loading && !reduceMotion { ProgressView().controlSize(.small) }
                else if !loading { Image(systemName: "checkmark.circle.fill").foregroundStyle(RillPalette.accent) }
                Text(status).font(.system(size: 12)).foregroundStyle(.secondary)
            }.padding(.top, 35).accessibilityElement(children: .combine)
            Spacer()
            Label("Local workspace · Ready when you are", systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary).padding(.bottom, 28)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(RillPalette.canvas)
            .accessibilityLabel(loading ? "Opening Rill" : "Rill is ready").accessibilityValue(status)
    }
}

struct WelcomeView: View {
    @EnvironmentObject private var store: WorkbenchStore
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    VStack(alignment: .leading, spacing: 15) {
                        Image(systemName: "water.waves").font(.system(size: 32, weight: .medium)).foregroundStyle(RillPalette.accent)
                            .frame(width: 65, height: 65).background(RillPalette.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 18))
                        Text(store.workspace.requests.isEmpty ? "A fresh start for your APIs." : "Back to your flow.").font(.system(size: 30, weight: .semibold, design: .rounded))
                        Text("Build a request, explore a response, and keep everything in one local workspace.")
                            .font(.system(size: 14)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 10) {
                            Button { store.newRequest() } label: { HStack(spacing: 14) { Label("New request", systemImage: "plus"); Text("⌘N").opacity(0.65) } }.buttonStyle(RillButtonStyle(emphasis: .primary))
                            Button { store.showCommandImport = true } label: { Label("Import request", systemImage: "square.and.arrow.down") }.buttonStyle(RillButtonStyle())
                        }.padding(.top, 5)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 245), spacing: 12)], spacing: 12) {
                        entry("API definitions", detail: "Bring in an OpenAPI document or create a mock.", icon: "curlybraces.square") { store.showAPITools = true }
                        entry("Live connections", detail: "Explore WebSocket, SSE and GraphQL streams.", icon: "waveform.path") { store.showLiveStreams = true }
                        entry("gRPC explorer", detail: "Load Protobuf schemas and call native gRPC services.", icon: "point.3.connected.trianglepath.dotted") { store.showGRPC = true }
                        entry("Workspace tools", detail: "Git, read-only sharing and local extensions.", icon: "square.stack.3d.up") { store.showWorkspaceTools = true }
                    }
                    HStack(spacing: 16) {
                        Label("\(store.workspace.requests.count) requests", systemImage: "arrow.up.right")
                        Label("\(store.workspace.collections.count) collections", systemImage: "folder")
                        Spacer()
                        Button("Explore the guide") { store.showHelp = true }.buttonStyle(.plain).foregroundStyle(RillPalette.accent)
                    }.font(.system(size: 11)).foregroundStyle(.secondary)
                }.frame(maxWidth: 710, alignment: .leading).padding(40)
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .center)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func entry(_ title: String, detail: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 11) {
                HStack { Image(systemName: icon).font(.system(size: 18)).foregroundStyle(RillPalette.accent); Spacer(); Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.tertiary) }
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
            }.padding(10).frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading)
        }.buttonStyle(RillButtonStyle()).accessibilityLabel(title).accessibilityHint(detail)
    }
}
