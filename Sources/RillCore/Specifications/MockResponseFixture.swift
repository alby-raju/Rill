import CoreFoundation
import Foundation

public enum MockResponseFixture {
    /// Structural replay template: every scalar value is replaced, rather than guessing secrets.
    /// Object key names remain and require review. Original URLs, headers and payload values do not.
    public static func route(_ response: Exchange) throws -> MockRoute {
        guard response.body.count <= 1024 * 1024, response.bodyWasTruncated != true,
            (200...599).contains(response.status)
        else { throw WorkflowError.invalidConfiguration }
        var route = MockRoute()
        route.method = response.method
        route.path = "/recorded-response"
        route.status = response.status
        route.origin = MockFixtureOrigin(kind: .response, sourceID: response.id)
        if (try? JSONValueParser(response.body).parse()) != nil,
            let object = try? JSONSerialization.jsonObject(
                with: response.body, options: .fragmentsAllowed)
        {
            func replace(_ value: Any, depth: Int) throws -> Any {
                guard depth <= 64 else { throw WorkflowError.limit }
                if let dictionary = value as? [String: Any] {
                    return try dictionary.mapValues { try replace($0, depth: depth + 1) }
                }
                if let array = value as? [Any] {
                    return try array.map { try replace($0, depth: depth + 1) }
                }
                if value is NSNull { return NSNull() }
                if let number = value as? NSNumber {
                    return CFGetTypeID(number) == CFBooleanGetTypeID() ? false : 0
                }
                return "[REDACTED]"
            }
            route.body = String(
                decoding: try JSONSerialization.data(
                    withJSONObject: replace(object, depth: 0),
                    options: [.fragmentsAllowed, .sortedKeys]), as: UTF8.self)
        } else {
            route.headers = [Field(name: "Content-Type", value: "text/plain")]
            route.body = "[REDACTED RESPONSE]"
        }
        try MockServer.validate([route])
        return route
    }
}
