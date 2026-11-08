import Foundation
import RillCore

struct AttachmentOptions {
    private struct Manifest: Decodable {
        let schemaVersion: Int
        let attachments: [[String: String]]
    }

    let files: [String: URL]

    init(_ args: Arguments) throws {
        guard let path = args.value("attachments") else {
            files = [:]
            return
        }
        do {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            let data = try BoundedFileInput.read(url, limit: 64 * 1024)
            try WorkspaceFile.checkJSONBounds(data)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                Set(object.keys) == ["schemaVersion", "attachments"]
            else { throw WorkflowError.invalidConfiguration }
            let manifest = try JSONDecoder().decode(Manifest.self, from: data)
            guard manifest.schemaVersion == 1, manifest.attachments.count <= 256 else {
                throw WorkflowError.invalidConfiguration
            }
            var files: [String: URL] = [:]
            for entry in manifest.attachments {
                try Task.checkCancellation()
                guard Set(entry.keys) == ["slot", "file"], let slot = entry["slot"],
                    let path = entry["file"], !slot.isEmpty, slot.utf8.count <= 2048,
                    !path.isEmpty, path != "-", path.utf8.count <= 4096, !path.contains("\0"),
                    files[slot] == nil
                else { throw WorkflowError.invalidConfiguration }
                let resolved = URL(
                    fileURLWithPath: path, relativeTo: url.deletingLastPathComponent()
                )
                .standardizedFileURL
                files[slot] =
                    args.flags.contains("dry-run") ? resolved : resolved.resolvingSymlinksInPath()
            }
            self.files = files
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CLIError.usage(
                "Invalid --attachments manifest. Use version 1, at most 256 unique slot/file entries and 64 KiB. No requests sent; inputs omitted."
            )
        }
    }
}
