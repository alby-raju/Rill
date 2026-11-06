import Foundation

/// Portable route definitions. Advanced rules are optional; old route arrays remain valid.
public enum MockRouteFile {
    public static let maximumBytes = 2 * 1024 * 1024
    private struct PortableField: Codable {
        let name: String
        let value: String
        let enabled: Bool?
    }
    private static func fields(_ value: Any?) throws -> [Field]? {
        guard let value else { return nil }
        guard let rows = value as? [[String: Any]], rows.count <= 100,
            rows.allSatisfy({ Set($0.keys).isSubset(of: ["name", "value", "enabled"]) })
        else { throw WorkflowError.invalidConfiguration }
        let decoded = try JSONDecoder().decode(
            [PortableField].self, from: JSONSerialization.data(withJSONObject: rows))
        return decoded.map { item in
            var field = Field(name: item.name, value: item.value)
            field.enabled = item.enabled ?? true
            return field
        }
    }
    private static func object<T: Decodable>(_ value: Any, type: T.Type, keys: Set<String>) throws
        -> T
    {
        guard let row = value as? [String: Any], Set(row.keys).isSubset(of: keys) else {
            throw WorkflowError.invalidConfiguration
        }
        return try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: row))
    }
    public static func decode(_ data: Data) throws -> [MockRoute] {
        guard data.count <= maximumBytes else { throw WorkflowError.limit }
        let parsed = try JSONValueParser(data).parse()
        guard let parsedRows = parsed.array,
            let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
            rows.count <= 1000
        else { throw WorkflowError.invalidConfiguration }
        let routes = try rows.enumerated().map { index, row in
            try Task.checkCancellation()
            guard
                Set(row.keys).isSubset(of: [
                    "method", "path", "status", "headers", "body", "query", "requestHeaders",
                    "requestBody", "delayMilliseconds", "fault", "scenario", "origin",
                ]),
                let method = (row["method"] as? String).flatMap(HTTPMethod.init(rawValue:)),
                let path = row["path"] as? String, let statusValue = parsedRows[index]["status"],
                let status = try ExactSchemaNumber(statusValue).nonnegativeInt,
                let body = row["body"] as? String
            else { throw WorkflowError.invalidConfiguration }
            var route = MockRoute()
            route.method = method
            route.path = path
            route.status = status
            route.body = body
            if let headers = row["headers"] {
                guard let headers = headers as? [String: String] else {
                    throw WorkflowError.invalidConfiguration
                }
                route.headers = headers.keys.sorted().map { Field(name: $0, value: headers[$0]!) }
            } else {
                route.headers = []
            }
            route.query = try fields(row["query"])
            route.requestHeaders = try fields(row["requestHeaders"])
            if let expected = row["requestBody"] {
                guard let expected = expected as? String else {
                    throw WorkflowError.invalidConfiguration
                }
                route.expectedBody = expected
            }
            if let delay = parsedRows[index]["delayMilliseconds"] {
                guard let value = try ExactSchemaNumber(delay).nonnegativeInt else {
                    throw WorkflowError.invalidConfiguration
                }
                route.delayMilliseconds = value
            }
            if let fault = row["fault"] {
                guard let value = (fault as? String).flatMap(MockFault.init(rawValue:)) else {
                    throw WorkflowError.invalidConfiguration
                }
                route.fault = value
            }
            if let scenario = row["scenario"] {
                route.scenario = try object(
                    scenario, type: MockScenario.self, keys: ["name", "requiredState", "nextState"])
            }
            if let origin = row["origin"] {
                route.origin = try object(
                    origin, type: MockFixtureOrigin.self, keys: ["kind", "sourceID", "operation"])
            }
            return route
        }
        try MockServer.validate(routes)
        return routes
    }
    public static func encode(_ routes: [MockRoute]) throws -> Data {
        try MockServer.validate(routes)
        func rows(_ fields: [Field]) -> [[String: Any]] {
            fields.map { ["name": $0.name, "value": $0.value, "enabled": $0.enabled] }
        }
        func encoded<T: Encodable>(_ value: T) throws -> Any {
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
        }
        let values: [[String: Any]] = try routes.map { route in
            var row: [String: Any] = [
                "method": route.method.rawValue, "path": route.path, "status": route.status,
                "headers": Dictionary(
                    uniqueKeysWithValues: route.headers.filter(\.enabled).map {
                        ($0.name, $0.value)
                    }),
                "body": route.body,
            ]
            if let query = route.query { row["query"] = rows(query) }
            if let headers = route.requestHeaders { row["requestHeaders"] = rows(headers) }
            if let body = route.expectedBody { row["requestBody"] = body }
            if let delay = route.delayMilliseconds { row["delayMilliseconds"] = delay }
            if let fault = route.fault { row["fault"] = fault.rawValue }
            if let scenario = route.scenario { row["scenario"] = try encoded(scenario) }
            if let origin = route.origin { row["origin"] = try encoded(origin) }
            return row
        }
        let data = try JSONSerialization.data(
            withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
        guard data.count <= maximumBytes else { throw WorkflowError.limit }
        return data
    }
}
