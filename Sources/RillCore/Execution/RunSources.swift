import CryptoKit
import Foundation

public enum RunSources {
    /// Structural identities, never derived from URLs, credentials or labels. Compare the same
    /// logical file: moving/inserting Postman items changes these positional identities.
    static func postman(_ selection: PostmanFolderSelection) throws -> [String] {
        var result: [String] = []
        func walk(_ row: [String: Any], path: String, depth: Int) throws {
            try Task.checkCancellation()
            guard depth <= 33, result.count <= 10_000 else { throw WorkflowError.limit }
            if let children = row["item"] as? [[String: Any]] {
                for (index, child) in children.enumerated() {
                    let original =
                        depth < selection.originalIndices.count
                        ? selection.originalIndices[depth] : index
                    try walk(child, path: path + "/item/\(original)", depth: depth + 1)
                }
            } else if row["request"] != nil {
                result.append(path)
            }
        }
        try walk(selection.root, path: "", depth: 0)
        return result
    }
    static func id(_ source: String) -> UUID {
        var bytes = Array(
            SHA256.hash(data: Data(("rill.postman-position.v1:" + source).utf8)).prefix(16))
        bytes[6] = (bytes[6] & 15) | 0x80
        bytes[8] = (bytes[8] & 63) | 0x80
        let text = bytes.enumerated().map { index, byte in
            ([4, 6, 8, 10].contains(index) ? "-" : "") + String(format: "%02x", byte)
        }.joined()
        return UUID(uuidString: text)!
    }
    static func valid(_ source: String) -> Bool {
        source.utf8.count <= 2048
            && source.range(
                of: #"\A(?:(?:/item/[0-9]{1,5}){1,33}|/requests/[0-9]{1,5})\z"#,
                options: .regularExpression) != nil
    }
}
