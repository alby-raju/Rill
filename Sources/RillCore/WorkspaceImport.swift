import Foundation

public enum WorkspaceImport {
    /// Build an entirely validated value before publishing any imported edits.
    /// Imported auth credentials are never trusted as local Keychain material.
    public static func merging(_ incoming: Workspace, into existing: Workspace) throws -> Workspace {
        try WorkspaceFile.validate(incoming)
        try WorkspaceFile.validate(existing)
        var result = existing
        var collections: [UUID: UUID] = [:]
        for var collection in incoming.collections {
            let original = collection.id
            collection.id = UUID()
            collections[original] = collection.id
            result.collections.append(collection)
        }
        for var request in incoming.requests {
            request.id = UUID()
            request.collectionID = request.collectionID.flatMap { collections[$0] }
            request.credential = ""
            result.requests.append(request)
        }
        for var environment in incoming.environments {
            environment.id = UUID()
            result.environments.append(environment)
        }
        try WorkspaceFile.validate(result)
        return result
    }
}
