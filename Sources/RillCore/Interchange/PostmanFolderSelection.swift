import Foundation

public enum PostmanFolderSelectionError: Error {
    case invalidPath
    case missingOrAmbiguous
}

/// Select before import flattens the folder hierarchy. Ancestors retain auth, scripts and settings.
struct PostmanFolderSelection {
    let data: Data
    let root: [String: Any]
    let originalIndices: [Int]

    static func prepare(_ collection: Data, folder: String?) throws -> Self {
        try Task.checkCancellation()
        try WorkspaceFile.checkJSONBounds(collection)
        let bytes =
            collection.starts(with: [0xef, 0xbb, 0xbf])
            ? Data(collection.dropFirst(3)) : collection
        guard let root = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            throw PostmanImportError.invalid
        }
        guard let folder else { return Self(data: collection, root: root, originalIndices: []) }
        guard folder.hasPrefix("/"), folder.utf8.count <= 4096 else {
            throw PostmanFolderSelectionError.invalidPath
        }
        let tokens = folder.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        guard !tokens.isEmpty, tokens.count <= 32 else {
            throw PostmanFolderSelectionError.invalidPath
        }
        let names = try tokens.map { token -> String in
            let bytes = Array(token.utf8)
            var result: [UInt8] = []
            var index = 0
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                if byte == 126 {
                    guard index < bytes.count, bytes[index] == 48 || bytes[index] == 49 else {
                        throw PostmanFolderSelectionError.invalidPath
                    }
                    result.append(bytes[index] == 48 ? 126 : 47)
                    index += 1
                } else {
                    result.append(byte)
                }
            }
            return String(decoding: result, as: UTF8.self)
        }
        var indices: [Int] = []
        func select(_ row: [String: Any], depth: Int) throws -> [String: Any] {
            try Task.checkCancellation()
            guard let items = row["item"] as? [[String: Any]] else {
                throw PostmanFolderSelectionError.missingOrAmbiguous
            }
            let matches = items.indices.filter {
                items[$0]["name"] as? String == names[depth] && items[$0]["item"] != nil
            }
            guard matches.count == 1, let index = matches.first,
                items[index]["item"] is [[String: Any]], items[index]["request"] == nil
            else { throw PostmanFolderSelectionError.missingOrAmbiguous }
            indices.append(index)
            let chosen =
                depth + 1 == names.count
                ? items[index] : try select(items[index], depth: depth + 1)
            var selected = row
            selected["item"] = [chosen]
            return selected
        }
        let selected = try select(root, depth: 0)
        let data = try JSONSerialization.data(withJSONObject: selected)
        return Self(data: data, root: selected, originalIndices: indices)
    }
}
