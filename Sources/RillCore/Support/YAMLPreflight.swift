import CYaml
import Foundation

/// Alias expansion is opt-in for API definitions; foreign workspace formats keep refusing it.
enum YAMLPreflight {
    private struct Weight {
        var nodes: Int
        var height: Int
        var bytes: Int
    }
    private struct Frame {
        var anchor: String?
        var weight = Weight(nodes: 1, height: 1, bytes: 16)
    }
    static func validate(_ data: Data, allowAliases: Bool, exactNumbers: Bool = false) throws {
        var parser = yaml_parser_t()
        guard yaml_parser_initialize(&parser) != 0 else { throw YAMLImportError.invalid }
        defer { yaml_parser_delete(&parser) }
        try data.withUnsafeBytes { raw in
            guard let bytes = raw.bindMemory(to: UInt8.self).baseAddress else {
                throw YAMLImportError.invalid
            }
            yaml_parser_set_input_string(&parser, bytes, data.count)
            var events = 0
            var documents = 0
            var expanded = 0
            var expandedBytes = 0
            var frames: [Frame] = []
            var anchors: [String: Weight] = [:]
            var announced = Set<String>()
            func metadata(_ anchor: UnsafePointer<UInt8>?, _ tag: UnsafePointer<UInt8>?) throws
                -> String?
            {
                if let tag {
                    let allowed = ["str", "int", "float", "bool", "null", "seq", "map"].map {
                        "tag:yaml.org,2002:" + $0
                    }
                    guard allowed.contains(String(cString: tag)) else {
                        throw YAMLImportError.unsupported
                    }
                }
                guard let anchor else { return nil }
                let name = String(cString: anchor)
                guard allowAliases, name.utf8.count <= 128, announced.insert(name).inserted else {
                    throw YAMLImportError.unsupported
                }
                return name
            }
            func child(_ weight: Weight) throws {
                guard frames.count + weight.height <= 64 else { throw YAMLImportError.unsupported }
                if !frames.isEmpty {
                    let index = frames.count - 1
                    frames[index].weight.nodes += weight.nodes
                    frames[index].weight.bytes += weight.bytes
                    frames[index].weight.height = max(
                        frames[index].weight.height, weight.height + 1)
                    guard frames[index].weight.nodes <= 100_000,
                        frames[index].weight.bytes <= 32 * 1024 * 1024
                    else { throw YAMLImportError.unsupported }
                }
            }
            while true {
                try Task.checkCancellation()
                var event = yaml_event_t()
                guard yaml_parser_parse(&parser, &event) != 0 else { throw YAMLImportError.invalid }
                defer { yaml_event_delete(&event) }
                events += 1
                guard events <= 100_000 else { throw YAMLImportError.unsupported }
                switch event.type {
                case YAML_DOCUMENT_START_EVENT:
                    documents += 1
                    guard documents == 1 else { throw YAMLImportError.unsupported }
                case YAML_ALIAS_EVENT:
                    guard allowAliases, let name = event.data.alias.anchor,
                        let weight = anchors[String(cString: name)]
                    else { throw YAMLImportError.unsupported }
                    expanded += weight.nodes
                    expandedBytes += weight.bytes
                    try child(weight)
                case YAML_SCALAR_EVENT:
                    let anchor = try metadata(event.data.scalar.anchor, event.data.scalar.tag)
                    guard event.data.scalar.length <= 1024 * 1024 else {
                        throw YAMLImportError.unsupported
                    }
                    let tag = event.data.scalar.tag.map { String(cString: $0) }
                    let explicitNumber = ["tag:yaml.org,2002:int", "tag:yaml.org,2002:float"]
                        .contains(tag ?? "")
                    if exactNumbers
                        && (event.data.scalar.style == YAML_PLAIN_SCALAR_STYLE && tag == nil
                            || explicitNumber)
                    {
                        let text = String(
                            decoding: UnsafeBufferPointer(
                                start: event.data.scalar.value, count: Int(event.data.scalar.length)
                            ), as: UTF8.self)
                        let parsed = try? JSONValueParser(Data(text.utf8)).parse()
                        if let value = parsed, case .number = value {
                            if Int64(text) == nil {
                                let number = try ExactSchemaNumber(value)
                                guard number.digits.count <= 15,
                                    (-100...100).contains(number.exponent)
                                else { throw YAMLImportError.unsupported }
                            }
                        } else if explicitNumber {
                            throw YAMLImportError.unsupported
                        }
                    }
                    let weight = Weight(
                        nodes: 1, height: 0, bytes: Int(event.data.scalar.length) + 16)
                    if let anchor { anchors[anchor] = weight }
                    expanded += 1
                    expandedBytes += weight.bytes
                    try child(weight)
                case YAML_SEQUENCE_START_EVENT, YAML_MAPPING_START_EVENT:
                    let anchor =
                        try event.type == YAML_SEQUENCE_START_EVENT
                        ? metadata(event.data.sequence_start.anchor, event.data.sequence_start.tag)
                        : metadata(event.data.mapping_start.anchor, event.data.mapping_start.tag)
                    frames.append(Frame(anchor: anchor))
                    expanded += 1
                    expandedBytes += 16
                    guard frames.count <= 64 else { throw YAMLImportError.unsupported }
                case YAML_SEQUENCE_END_EVENT, YAML_MAPPING_END_EVENT:
                    guard let frame = frames.popLast() else { throw YAMLImportError.invalid }
                    if let anchor = frame.anchor { anchors[anchor] = frame.weight }
                    try child(frame.weight)
                case YAML_STREAM_END_EVENT:
                    guard frames.isEmpty else { throw YAMLImportError.invalid }
                    return
                default: break
                }
                guard expanded <= 100_000, expandedBytes <= 32 * 1024 * 1024 else {
                    throw YAMLImportError.unsupported
                }
            }
        }
    }
}
