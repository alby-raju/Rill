import RillCore
import SwiftUI

/// The packaged release uses this explicit self-test in an isolated workspace.
@MainActor enum InstallationCheck {
    static var enabled: Bool { CommandLine.arguments.contains("--verify-installation") }
    private static let domain = "app.rill.installation-check." + UUID().uuidString
    static let preferences = UserDefaults(suiteName: domain)!
    static let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "Rill-Installation-Check-" + UUID().uuidString, isDirectory: true)
    static weak var store: WorkbenchStore?

    static func makeStore() -> WorkbenchStore {
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            // An absent workspace would hydrate the normal starter request via
            // Keychain. The installation check must never query user credentials.
            try WorkspaceFile.create(
                Workspace(), at: directory.appendingPathComponent("workspace.json"))
        } catch {
            fputs("Unable to create isolated installation workspace.\n", stderr)
            exit(1)
        }
        let result = WorkbenchStore(storageDirectory: directory, preferences: preferences)
        store = result
        return result
    }

    static func verifyIfRequested() async {
        guard enabled else { return }
        var success = false
        do {
            for _ in 0..<100 {
                if store?.loading == false { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            try await Task.sleep(for: .milliseconds(800))
            guard store?.loading == false, store?.error == nil,
                NSApplication.shared.windows.contains(where: {
                    $0.isVisible && $0.contentView != nil
                }),
                let icon = RillResources.url(forResource: "Rill", withExtension: "icns"),
                NSImage(contentsOf: icon) != nil,
                let help = RillResources.url(forResource: "Help", withExtension: "json")
            else { throw CocoaError(.fileReadCorruptFile) }
            let sections = try JSONDecoder().decode(
                [HelpSection].self, from: Data(contentsOf: help))
            guard !sections.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
            print(
                "RILL_INSTALLATION_OK version=\(RillVersion.number) build=\(RillVersion.build) window=ready icon=loaded help=\(sections.count)"
            )
            success = true
        } catch {
            fputs(
                "Rill installation verification failed: window or bundled resources unavailable.\n",
                stderr)
        }
        UserDefaults.standard.removePersistentDomain(forName: domain)
        try? FileManager.default.removeItem(at: directory)
        exit(success ? 0 : 1)
    }
}
