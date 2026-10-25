import Foundation
import CryptoKit

public struct BackupContents: Codable, Sendable {
    public var version: Int
    public var createdAt: Date
    public var credentialPolicy: String
    public var workspace: Workspace
    public var editor: EditorSessionState?
    public func validate() throws {
        guard version == 1, credentialPolicy == "omit-auth-credentials", workspace.history.isEmpty,
              workspace.requests.allSatisfy({ $0.credential.isEmpty }),
              editor?.drafts.allSatisfy({ $0.credential.isEmpty }) ?? true else { throw BackupError.invalid }
        try WorkspaceFile.validate(workspace)
        if let editor { try editor.validate(in: workspace) }
    }
}
private struct BackupEnvelope: Codable {
    var version: Int
    var checksum: String
    var payload: Data
}
public enum BackupError: LocalizedError {
    case invalid
    public var errorDescription: String? { "The backup is invalid, modified, unsupported or exceeds its limits. No restore was applied." }
}
public enum WorkspaceBackup {
    public static func encode(workspace: Workspace, editor: EditorSessionState?) throws -> Data {
        try WorkspaceFile.validate(workspace)
        if let editor { try editor.validate(in: workspace) }
        var workspace = workspace, editor = editor
        workspace.history = []; workspace.storageRevision = nil
        for index in workspace.requests.indices { workspace.requests[index].credential = "" }
        if editor != nil { for index in editor!.drafts.indices { editor!.drafts[index].credential = "" } }
        let contents = BackupContents(version: 1, createdAt: Date(), credentialPolicy: "omit-auth-credentials", workspace: workspace, editor: editor)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(contents)
        let checksum = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let data = try encoder.encode(BackupEnvelope(version: 1, checksum: checksum, payload: payload))
        guard data.count <= ResourceLimits.workspaceBytes else { throw WorkspaceError.tooLarge }
        return data
    }
    public static func decode(_ data: Data) throws -> BackupContents {
        do {
            try WorkspaceFile.checkJSONBounds(data)
            let envelope = try JSONDecoder().decode(BackupEnvelope.self, from: data)
            guard envelope.version == 1,
                  SHA256.hash(data: envelope.payload).map({ String(format: "%02x", $0) }).joined() == envelope.checksum else { throw BackupError.invalid }
            try WorkspaceFile.checkJSONBounds(envelope.payload)
            let contents = try JSONDecoder().decode(BackupContents.self, from: envelope.payload)
            try contents.validate()
            return contents
        } catch { throw BackupError.invalid }
    }
    public static func load(from url: URL) throws -> BackupContents { try decode(WorkspaceFile.readBounded(from: url)) }
    public static func write(workspace: Workspace, editor: EditorSessionState?, to url: URL) throws {
        try WorkspaceFile.atomicWrite(encode(workspace: workspace, editor: editor), to: url)
    }
}
