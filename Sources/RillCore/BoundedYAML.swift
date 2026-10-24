import Foundation
import Yams
import CYaml

public enum YAMLImportError: LocalizedError {
    case invalid, unsupported
    public var errorDescription: String? {
        switch self {
        case .invalid: "Invalid or non-JSON-compatible YAML. Source text is omitted from diagnostics."
        case .unsupported: "YAML exceeds the supported limits or uses anchors, aliases, custom tags or multiple documents."
        }
    }
}
enum BoundedYAML {
    static func object(_ data: Data) throws -> [String: Any] {
        guard data.count <= 8 * 1024 * 1024, let text = String(data: data, encoding: .utf8) else { throw YAMLImportError.unsupported }
        var parser = yaml_parser_t()
        guard yaml_parser_initialize(&parser) != 0 else { throw YAMLImportError.invalid }
        defer { yaml_parser_delete(&parser) }
        try data.withUnsafeBytes { raw in
            guard let bytes = raw.bindMemory(to: UInt8.self).baseAddress else { throw YAMLImportError.invalid }
            yaml_parser_set_input_string(&parser, bytes, data.count)
            var events = 0, depth = 0, documents = 0
            func metadata(anchor: UnsafePointer<UInt8>?, tag: UnsafePointer<UInt8>?) throws {
                guard anchor == nil else { throw YAMLImportError.unsupported }
                if let tag {
                    let allowed = ["str", "int", "float", "bool", "null", "seq", "map"].map { "tag:yaml.org,2002:" + $0 }
                    guard allowed.contains(String(cString: tag)) else { throw YAMLImportError.unsupported }
                }
            }
            while true {
                try Task.checkCancellation()
                var event = yaml_event_t()
                guard yaml_parser_parse(&parser, &event) != 0 else { throw YAMLImportError.invalid }
                defer { yaml_event_delete(&event) }
                events += 1; guard events <= 100_000 else { throw YAMLImportError.unsupported }
                switch event.type {
                case YAML_DOCUMENT_START_EVENT: documents += 1; guard documents == 1 else { throw YAMLImportError.unsupported }
                case YAML_ALIAS_EVENT: throw YAMLImportError.unsupported
                case YAML_SCALAR_EVENT:
                    try metadata(anchor: event.data.scalar.anchor, tag: event.data.scalar.tag)
                    guard event.data.scalar.length <= 1024 * 1024 else { throw YAMLImportError.unsupported }
                case YAML_SEQUENCE_START_EVENT:
                    depth += 1; try metadata(anchor: event.data.sequence_start.anchor, tag: event.data.sequence_start.tag)
                case YAML_MAPPING_START_EVENT:
                    depth += 1; try metadata(anchor: event.data.mapping_start.anchor, tag: event.data.mapping_start.tag)
                case YAML_SEQUENCE_END_EVENT, YAML_MAPPING_END_EVENT: depth -= 1
                case YAML_STREAM_END_EVENT: return
                default: break
                }
                guard (0...64).contains(depth) else { throw YAMLImportError.unsupported }
            }
        }
        do {
            let resolver = try Resolver.basic
                .appending(.bool, "^(?:true|True|TRUE|false|False|FALSE)$")
                .appending(.int, #"^-?(?:0|[1-9][0-9]*)$"#)
                .appending(.float, #"^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?$"#)
                .appending(.null, "^(?:null|Null|NULL|~|)$")
            guard let result = try Yams.load(yaml: text, resolver) as? [String: Any], JSONSerialization.isValidJSONObject(result) else { throw YAMLImportError.invalid }
            return result
        } catch { throw YAMLImportError.invalid }
    }
}
