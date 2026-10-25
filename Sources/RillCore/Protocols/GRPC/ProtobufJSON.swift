import Foundation
import SwiftProtobuf

public extension ProtobufSchema {
    func encode(json: String, message: String) throws -> Data {
        guard json.utf8.count <= 1024 * 1024 else { throw BrokerError.limit }
        let value: JSONValue
        do { value = try JSONValueParser(Data(json.utf8)).parse() } catch {
            throw ProtobufError.invalidJSON
        }
        var budget = 10000
        let result = try encodeValue(value, message: message, depth: 0, budget: &budget)
        guard result.count <= 1024 * 1024 else { throw BrokerError.limit }
        return result
    }
    func decode(data: Data, message: String) throws -> String {
        guard data.count <= 1024 * 1024 else { throw BrokerError.limit }
        var budget = 10000
        return try ResponseJSON.encoded(
            decodeValue(data, message: message, depth: 0, budget: &budget))
    }
}
private extension ProtobufSchema {
    func wellKnown(_ name: String) -> (any SwiftProtobuf.Message.Type)? {
        switch name {
        case "google.protobuf.Timestamp": Google_Protobuf_Timestamp.self
        case "google.protobuf.Duration": Google_Protobuf_Duration.self
        case "google.protobuf.Struct": Google_Protobuf_Struct.self
        case "google.protobuf.Value": Google_Protobuf_Value.self
        case "google.protobuf.ListValue": Google_Protobuf_ListValue.self
        case "google.protobuf.FieldMask": Google_Protobuf_FieldMask.self
        case "google.protobuf.DoubleValue": Google_Protobuf_DoubleValue.self
        case "google.protobuf.FloatValue": Google_Protobuf_FloatValue.self
        case "google.protobuf.Int64Value": Google_Protobuf_Int64Value.self
        case "google.protobuf.UInt64Value": Google_Protobuf_UInt64Value.self
        case "google.protobuf.Int32Value": Google_Protobuf_Int32Value.self
        case "google.protobuf.UInt32Value": Google_Protobuf_UInt32Value.self
        case "google.protobuf.BoolValue": Google_Protobuf_BoolValue.self
        case "google.protobuf.StringValue": Google_Protobuf_StringValue.self
        case "google.protobuf.BytesValue": Google_Protobuf_BytesValue.self
        default: nil
        }
    }
    func consume(_ depth: Int, _ budget: inout Int) throws {
        budget -= 1
        guard depth <= 32, budget >= 0 else { throw BrokerError.limit }
        try Task.checkCancellation()
    }
    func encodeValue(_ value: JSONValue, message name: String, depth: Int, budget: inout Int) throws
        -> Data
    {
        try consume(depth, &budget)
        guard let descriptor = messages[name] else { throw ProtobufError.missingType }
        if let known = wellKnown(name) {
            let json = Data(try ResponseJSON.encoded(value).utf8)
            do { return try known.init(jsonUTF8Data: json).serializedData() } catch {
                throw ProtobufError.invalidJSON
            }
        }
        if name == "google.protobuf.Any" {
            return try encodeAny(value, depth: depth, budget: &budget)
        }
        guard case .object(let object) = value else { throw ProtobufError.invalidJSON }
        var accepted: Set<JSONKey> = []
        var chosen: Set<Int32> = []
        var output = Data()
        for field in descriptor.descriptor.field {
            let jsonName = field.jsonName.isEmpty ? Self.jsonName(field.name) : field.jsonName
            let protoKey = JSONKey(field.name)
            let jsonKey = JSONKey(jsonName)
            accepted.insert(protoKey)
            accepted.insert(jsonKey)
            let proto = object[protoKey]
            let json = object[jsonKey]
            guard protoKey == jsonKey || proto == nil || json == nil else {
                throw ProtobufError.invalidJSON
            }
            guard let current = json ?? proto,
                current != .null || field.typeName == ".google.protobuf.Value"
            else {
                guard field.label != .required else { throw ProtobufError.invalidJSON }
                continue
            }
            if field.hasOneofIndex {
                guard chosen.insert(field.oneofIndex).inserted else {
                    throw ProtobufError.invalidJSON
                }
            }
            if field.label == .repeated {
                if let entry = messages[String(field.typeName.dropFirst())],
                    entry.descriptor.options.mapEntry
                {
                    guard case .object(let map) = current else { throw ProtobufError.invalidJSON }
                    for key in map.keys.sorted(by: { $0.bytes.lexicographicallyPrecedes($1.bytes) })
                    {
                        try consume(depth + 1, &budget)
                        let entryFields = entry.descriptor.field
                        let keyValue: JSONValue =
                            entryFields[0].type == .string
                            ? .string(key.bytes)
                            : (entryFields[0].type == .bool
                                ? (key.text == "true"
                                    ? .bool(true) : key.text == "false" ? .bool(false) : .null)
                                : .string(key.bytes))
                        let encoded =
                            try scalar(
                                keyValue, field: entryFields[0], depth: depth + 1, budget: &budget)
                            + scalar(
                                map[key]!, field: entryFields[1], depth: depth + 1, budget: &budget)
                        output += ProtoWire.field(
                            field.number, wire: 2, ProtoWire.delimited(encoded))
                    }
                } else {
                    guard let array = current.array else { throw ProtobufError.invalidJSON }
                    for element in array {
                        guard element != .null else { throw ProtobufError.invalidJSON }
                        output += try scalar(
                            element, field: field, depth: depth + 1, budget: &budget)
                    }
                }
            } else {
                output += try scalar(current, field: field, depth: depth + 1, budget: &budget)
            }
            guard output.count <= 1024 * 1024 else { throw BrokerError.limit }
        }
        guard Set(object.keys).isSubset(of: accepted) else { throw ProtobufError.invalidJSON }
        return output
    }
    func scalar(
        _ value: JSONValue, field: Google_Protobuf_FieldDescriptorProto, depth: Int,
        budget: inout Int
    ) throws -> Data {
        try consume(depth, &budget)
        var wire: UInt64 = 0
        var payload: Data
        switch field.type {
        case .message:
            wire = 2
            payload = try ProtoWire.delimited(
                encodeValue(
                    value, message: String(field.typeName.dropFirst()), depth: depth + 1,
                    budget: &budget))
        case .string:
            guard case .string(let data) = value else { throw ProtobufError.invalidJSON }
            wire = 2
            payload = ProtoWire.delimited(data)
        case .bytes:
            guard let text = value.string,
                let data = Data(
                    base64Encoded: text.replacingOccurrences(of: "-", with: "+")
                        .replacingOccurrences(of: "_", with: "/").padding(
                            toLength: (text.utf8.count + 3) / 4 * 4, withPad: "=", startingAt: 0))
            else { throw ProtobufError.invalidJSON }
            wire = 2
            payload = ProtoWire.delimited(data)
        case .bool:
            guard case .bool(let flag) = value else { throw ProtobufError.invalidJSON }
            payload = ProtoWire.varint(flag ? 1 : 0)
        case .enum:
            guard let enumeration = enums[String(field.typeName.dropFirst())] else {
                throw ProtobufError.missingType
            }
            let number: Int32
            if let text = value.string,
                let known = enumeration.value.first(where: { $0.name == text })
            {
                number = known.number
            } else {
                guard let integer = Int32(try integerText(value)) else {
                    throw ProtobufError.invalidJSON
                }
                number = integer
            }
            payload = ProtoWire.varint(UInt64(bitPattern: Int64(number)))
        case .double, .float:
            let number: Double
            if let text = value.string, ["NaN", "Infinity", "-Infinity"].contains(text) {
                number = text == "NaN" ? .nan : (text == "Infinity" ? .infinity : -.infinity)
            } else {
                let text = try ResponseJSON.encoded(value)
                guard case .number = value, let parsed = Double(text), parsed.isFinite else {
                    throw ProtobufError.invalidJSON
                }
                number = parsed
            }
            if field.type == .float {
                let float = Float(number)
                guard !number.isFinite || float.isFinite else { throw ProtobufError.invalidJSON }
                wire = 5
                payload = ProtoWire.fixed(UInt64(float.bitPattern), count: 4)
            } else {
                wire = 1
                payload = ProtoWire.fixed(number.bitPattern, count: 8)
            }
        case .uint32, .uint64, .fixed32, .fixed64:
            guard let number = UInt64(try integerText(value)),
                ![Google_Protobuf_FieldDescriptorProto.TypeEnum.uint32, .fixed32].contains(
                    field.type) || number <= UInt64(UInt32.max)
            else { throw ProtobufError.invalidJSON }
            if field.type == .fixed32 {
                wire = 5
                payload = ProtoWire.fixed(number, count: 4)
            } else if field.type == .fixed64 {
                wire = 1
                payload = ProtoWire.fixed(number, count: 8)
            } else {
                payload = ProtoWire.varint(number)
            }
        case .int32, .int64, .sint32, .sint64, .sfixed32, .sfixed64:
            guard let number = Int64(try integerText(value)),
                ![Google_Protobuf_FieldDescriptorProto.TypeEnum.int32, .sint32, .sfixed32].contains(
                    field.type) || Int32(exactly: number) != nil
            else { throw ProtobufError.invalidJSON }
            if field.type == .sfixed32 {
                wire = 5
                payload = ProtoWire.fixed(UInt64(UInt32(bitPattern: Int32(number))), count: 4)
            } else if field.type == .sfixed64 {
                wire = 1
                payload = ProtoWire.fixed(UInt64(bitPattern: number), count: 8)
            } else if field.type == .sint32 || field.type == .sint64 {
                payload = ProtoWire.varint(
                    (UInt64(bitPattern: number) << 1) ^ UInt64(bitPattern: number >> 63))
            } else {
                payload = ProtoWire.varint(UInt64(bitPattern: number))
            }
        default: throw ProtobufError.unsupported
        }
        return ProtoWire.field(field.number, wire: wire, payload)
    }
    func integerText(_ value: JSONValue) throws -> String {
        if let string = value.string {
            guard string.utf8.count <= 64,
                let parsed = try? JSONValueParser(Data(string.utf8)).parse(), case .number = parsed
            else { throw ProtobufError.invalidJSON }
            return try integerText(parsed)
        }
        guard case .number(let normalized) = value else { throw ProtobufError.invalidJSON }
        if normalized == "0" { return "0" }
        let parts = normalized.split(separator: "e", omittingEmptySubsequences: false)
        guard parts.count == 2, let exponent = Int(parts[1]), exponent >= 0, exponent <= 20,
            parts[0].count + exponent <= 21
        else { throw ProtobufError.invalidJSON }
        return String(parts[0]) + String(repeating: "0", count: exponent)
    }
    func decodeValue(_ data: Data, message name: String, depth: Int, budget: inout Int) throws
        -> JSONValue
    {
        try consume(depth, &budget)
        guard let message = messages[name] else { throw ProtobufError.missingType }
        if let known = wellKnown(name) {
            var options = BinaryDecodingOptions()
            options.messageDepthLimit = 32
            do {
                let decoded = try known.init(serializedBytes: data, options: options)
                return try JSONValueParser(decoded.jsonUTF8Data()).parse()
            } catch { throw ProtobufError.malformed }
        }
        if name == "google.protobuf.Any" {
            return try decodeAny(data, depth: depth, budget: &budget)
        }
        let fields = Dictionary(
            uniqueKeysWithValues: message.descriptor.field.map { ($0.number, $0) })
        var reader = ProtoWireReader(data: data)
        var object: [JSONKey: JSONValue] = [:]
        var embedded: [Int32: Data] = [:]
        var oneofs: [Int32: Int32] = [:]
        while reader.remaining > 0 {
            try consume(depth, &budget)
            let tag = try reader.varint()
            let wire = Int(tag & 7)
            let number = tag >> 3
            guard number > 0, number <= 536870911 else { throw ProtobufError.malformed }
            guard let field = fields[Int32(number)] else {
                try reader.skip(wire, field: number)
                continue
            }
            let key = JSONKey(field.jsonName.isEmpty ? Self.jsonName(field.name) : field.jsonName)
            if field.hasOneofIndex {
                if let previous = oneofs[field.oneofIndex], previous != field.number,
                    let old = fields[previous]
                {
                    object[JSONKey(old.jsonName.isEmpty ? Self.jsonName(old.name) : old.jsonName)] =
                        nil
                    embedded[previous] = nil
                }
                oneofs[field.oneofIndex] = field.number
            }
            if field.type == .message && field.label != .repeated {
                guard wire == 2 else { throw ProtobufError.malformed }
                embedded[field.number, default: Data()] += try reader.delimited()
                continue
            }
            if field.label == .repeated, let entry = messages[String(field.typeName.dropFirst())],
                entry.descriptor.options.mapEntry
            {
                guard wire == 2 else { throw ProtobufError.malformed }
                let decoded = try decodeValue(
                    reader.delimited(), message: String(field.typeName.dropFirst()),
                    depth: depth + 1, budget: &budget)
                let mapFields = entry.descriptor.field
                let keyValue = decoded["key"] ?? defaultValue(mapFields[0])
                let mapKey: String
                if let text = keyValue.string {
                    mapKey = text
                } else {
                    mapKey = try ResponseJSON.encoded(keyValue)
                }
                var map: [JSONKey: JSONValue] = [:]
                if case .object(let existing) = object[key] { map = existing }
                map[JSONKey(mapKey)] = decoded["value"] ?? defaultValue(mapFields[1])
                object[key] = .object(map)
                continue
            }
            var values: [JSONValue] = []
            if wire == 2, field.label == .repeated,
                ![Google_Protobuf_FieldDescriptorProto.TypeEnum.string, .bytes, .message].contains(
                    field.type)
            {
                var packed = ProtoWireReader(data: try reader.delimited())
                while packed.remaining > 0 {
                    try consume(depth + 1, &budget)
                    values.append(
                        try decodedScalar(
                            &packed, wire: expectedWire(field), field: field, depth: depth + 1,
                            budget: &budget))
                }
            } else {
                values = [
                    try decodedScalar(
                        &reader, wire: wire, field: field, depth: depth + 1, budget: &budget)
                ]
            }
            if field.label == .repeated {
                object[key] = .array((object[key]?.array ?? []) + values)
            } else {
                object[key] = values.last
            }
        }
        for (number, bytes) in embedded {
            guard let field = fields[number] else { throw ProtobufError.malformed }
            object[JSONKey(field.jsonName.isEmpty ? Self.jsonName(field.name) : field.jsonName)] =
                try decodeValue(
                    bytes, message: String(field.typeName.dropFirst()), depth: depth + 1,
                    budget: &budget)
        }
        for field in message.descriptor.field where field.label == .required {
            guard
                object[JSONKey(field.jsonName.isEmpty ? Self.jsonName(field.name) : field.jsonName)]
                    != nil
            else { throw ProtobufError.malformed }
        }
        return .object(object)
    }
    func expectedWire(_ field: Google_Protobuf_FieldDescriptorProto) -> Int {
        switch field.type {
        case .double, .fixed64, .sfixed64: 1
        case .float, .fixed32, .sfixed32: 5
        case .string, .bytes, .message: 2
        default: 0
        }
    }
    func decodedScalar(
        _ reader: inout ProtoWireReader, wire: Int, field: Google_Protobuf_FieldDescriptorProto,
        depth: Int, budget: inout Int
    ) throws -> JSONValue {
        try consume(depth, &budget)
        guard wire == expectedWire(field) else { throw ProtobufError.malformed }
        switch field.type {
        case .message:
            return try decodeValue(
                reader.delimited(), message: String(field.typeName.dropFirst()), depth: depth + 1,
                budget: &budget)
        case .string:
            let bytes = try reader.delimited()
            guard String(data: bytes, encoding: .utf8) != nil else { throw ProtobufError.malformed }
            return .string(bytes)
        case .bytes: return .string(Data(try reader.delimited().base64EncodedString().utf8))
        case .bool: return .bool(try reader.varint() != 0)
        case .enum:
            let value = Int32(truncatingIfNeeded: try reader.varint())
            if let name = enums[String(field.typeName.dropFirst())]?.value.first(where: {
                $0.number == value
            })?.name {
                return .string(Data(name.utf8))
            }
            return try number(String(value))
        case .double, .float:
            let value =
                field.type == .double
                ? Double(bitPattern: try reader.fixed(8))
                : Double(Float(bitPattern: UInt32(try reader.fixed(4))))
            if value.isNaN { return .string(Data("NaN".utf8)) }
            if value.isInfinite {
                return .string(Data((value > 0 ? "Infinity" : "-Infinity").utf8))
            }
            return try number(String(value))
        case .fixed32: return try number(String(UInt32(try reader.fixed(4))))
        case .fixed64: return .string(Data(String(try reader.fixed(8)).utf8))
        case .sfixed32: return try number(String(Int32(bitPattern: UInt32(try reader.fixed(4)))))
        case .sfixed64: return .string(Data(String(Int64(bitPattern: try reader.fixed(8))).utf8))
        case .uint32: return try number(String(UInt32(truncatingIfNeeded: try reader.varint())))
        case .uint64: return .string(Data(String(try reader.varint()).utf8))
        case .int32: return try number(String(Int32(truncatingIfNeeded: try reader.varint())))
        case .int64: return .string(Data(String(Int64(bitPattern: try reader.varint())).utf8))
        case .sint32:
            let bits = UInt32(truncatingIfNeeded: try reader.varint())
            let value = Int32(bitPattern: (bits >> 1) ^ (0 &- (bits & 1)))
            return try number(String(value))
        case .sint64:
            let bits = try reader.varint()
            let value = Int64(bitPattern: (bits >> 1) ^ (0 &- (bits & 1)))
            return .string(Data(String(value).utf8))
        default: throw ProtobufError.unsupported
        }
    }
    func number(_ value: String) throws -> JSONValue {
        try JSONValueParser(Data(value.utf8)).parse()
    }
    func defaultValue(_ field: Google_Protobuf_FieldDescriptorProto) -> JSONValue {
        switch field.type {
        case .string, .bytes: .string(Data())
        case .bool: .bool(false)
        case .message: .object([:])
        case .int64, .uint64, .fixed64, .sfixed64, .sint64: .string(Data("0".utf8))
        case .enum:
            enums[String(field.typeName.dropFirst())]?.value.first.map {
                .string(Data($0.name.utf8))
            } ?? .number("0")
        default: .number("0")
        }
    }
    func encodeAny(_ value: JSONValue, depth: Int, budget: inout Int) throws -> Data {
        guard case .object(var object) = value else { throw ProtobufError.invalidJSON }
        if object.isEmpty { return Data() }
        guard let type = object[JSONKey("@type")]?.string, type.utf8.count <= 4096,
            let name = type.split(separator: "/").last.map(String.init), messages[name] != nil
        else { throw ProtobufError.invalidJSON }
        object[JSONKey("@type")] = nil
        let payload: JSONValue
        if wellKnown(name) != nil || name == "google.protobuf.Any" {
            guard object.count == 1, let value = object[JSONKey("value")] else {
                throw ProtobufError.invalidJSON
            }
            payload = value
        } else {
            payload = .object(object)
        }
        let bytes = try encodeValue(payload, message: name, depth: depth + 1, budget: &budget)
        return ProtoWire.field(1, wire: 2, ProtoWire.delimited(Data(type.utf8)))
            + ProtoWire.field(2, wire: 2, ProtoWire.delimited(bytes))
    }
    func decodeAny(_ data: Data, depth: Int, budget: inout Int) throws -> JSONValue {
        var reader = ProtoWireReader(data: data)
        var type = ""
        var bytes = Data()
        while reader.remaining > 0 {
            try consume(depth, &budget)
            let tag = try reader.varint()
            if tag == 10 {
                guard let text = String(data: try reader.delimited(), encoding: .utf8) else {
                    throw ProtobufError.malformed
                }
                type = text
            } else if tag == 18 {
                bytes = try reader.delimited()
            } else {
                guard tag >> 3 > 0 else { throw ProtobufError.malformed }
                try reader.skip(Int(tag & 7), field: tag >> 3)
            }
        }
        if type.isEmpty && bytes.isEmpty { return .object([:]) }
        guard type.utf8.count <= 4096, let name = type.split(separator: "/").last.map(String.init),
            messages[name] != nil
        else { throw ProtobufError.missingType }
        let decoded = try decodeValue(bytes, message: name, depth: depth + 1, budget: &budget)
        var object: [JSONKey: JSONValue]
        if wellKnown(name) != nil || name == "google.protobuf.Any" {
            object = [JSONKey("value"): decoded]
        } else {
            guard case .object(let value) = decoded else { throw ProtobufError.malformed }
            object = value
        }
        object[JSONKey("@type")] = .string(Data(type.utf8))
        return .object(object)
    }
}
