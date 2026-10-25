import Foundation

public enum CloudEventError: LocalizedError {
    case invalidAttribute, invalidData, tooLarge
    public var errorDescription: String? {
        switch self {
        case .invalidAttribute:
            "CloudEvents require nonempty id/type, a valid URI-reference source and RFC 3339 time. Attributes cannot contain control characters."
        case .invalidData: "CloudEvent data must be one valid JSON value with unique object keys."
        case .tooLarge: "The structured CloudEvent exceeds the 1 MiB message limit."
        }
    }
}
public enum CloudEvents {
    public static let contentType = "application/cloudevents+json"
    public static func structured(
        source: String, type: String, data: String, id: String = UUID().uuidString,
        time: Date = Date()
    ) throws -> Data {
        func valid(_ value: String) -> Bool {
            !value.isEmpty && value.utf8.count <= 4096
                && value.unicodeScalars.allSatisfy { scalar in
                    let n = scalar.value
                    return n > 31 && !(127...159).contains(n) && !(0xFDD0...0xFDEF).contains(n)
                        && n & 0xFFFF < 0xFFFE
                }
        }
        guard valid(source), valid(type), valid(id), let reference = URLComponents(string: source),
            reference.string == source,
            !source.contains(where: { $0.isWhitespace }), time.timeIntervalSince1970.isFinite,
            (-62135596800...253402300799).contains(time.timeIntervalSince1970)
        else { throw CloudEventError.invalidAttribute }
        guard data.utf8.count <= 1024 * 1024 else { throw CloudEventError.tooLarge }
        let payload: JSONValue
        do { payload = try JSONValueParser(Data(data.utf8)).parse() } catch {
            throw CloudEventError.invalidData
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func string(_ text: String) -> JSONValue { .string(Data(text.utf8)) }
        let envelope: JSONValue = .object([
            JSONKey("specversion"): string("1.0"), JSONKey("id"): string(id),
            JSONKey("source"): string(source),
            JSONKey("type"): string(type), JSONKey("time"): string(formatter.string(from: time)),
            JSONKey("datacontenttype"): string("application/json"), JSONKey("data"): payload,
        ])
        let encoded = Data(try ResponseJSON.encoded(envelope).utf8)
        guard encoded.count <= 1024 * 1024 else { throw CloudEventError.tooLarge }
        return encoded
    }
}
