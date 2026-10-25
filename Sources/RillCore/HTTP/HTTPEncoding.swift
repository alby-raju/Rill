import Foundation

public enum HTTPEncoding {
    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    public static func component(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: unreserved)! }
    public static func formComponent(_ value: String) -> String { component(value).replacingOccurrences(of: "%20", with: "+") }
    public static func isHeaderName(_ value: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        return !value.isEmpty && value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
    static func removingQuery(_ name: String, from query: String?) -> String? {
        guard let query else { return nil }
        let parts = query.split(separator: "&", omittingEmptySubsequences: false).filter { part in
            let encoded = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            return encoded.removingPercentEncoding != name
        }
        return parts.isEmpty ? nil : parts.joined(separator: "&")
    }
}
