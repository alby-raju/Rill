import Foundation
import SwiftProtobuf

public enum ProtobufError: LocalizedError {
    case malformed, unsupported, invalidJSON, missingType, compilerUnavailable, compilerFailed
    case missingImport(String), compilationLocation(Int, Int)
    public var errorDescription: String? {
        switch self {
        case .malformed:
            "Malformed or incomplete Protobuf descriptors; include imported files and unique valid type/field names."
        case .unsupported:
            "This descriptor uses an unsupported Protobuf feature (extensions, groups or Editions)."
        case .invalidJSON: "The JSON does not match the selected Protobuf message type."
        case .missingType:
            "The selected Protobuf message or method is missing from the loaded descriptors."
        case .compilerUnavailable:
            "The bundled Protobuf compiler is unavailable. Build/package its native resource or load an existing descriptor set."
        case .compilerFailed:
            "Protobuf compilation failed. Check syntax, explicit import roots and missing imports."
        case .missingImport(let name):
            "Protobuf import not found in the explicit import roots: " + name
        case .compilationLocation(let line, let column):
            "Protobuf compilation failed at line \(line), column \(column). Check the selected source syntax and imports."
        }
    }
}
public enum GRPCCallMode: String, CaseIterable, Sendable {
    case unary, clientStreaming, serverStreaming, bidirectional
}
public struct ProtobufMethod: Identifiable, Equatable, Sendable {
    public let service: String, name: String, inputType: String, outputType: String
    public let mode: GRPCCallMode
    public var id: String { service + "/" + name }
}
struct ProtoMessage: Sendable {
    let descriptor: Google_Protobuf_DescriptorProto
    let syntax: String
}
public struct ProtobufSchema: Sendable {
    public let methods: [ProtobufMethod]
    public let snapshot: Data
    let messages: [String: ProtoMessage]
    let enums: [String: Google_Protobuf_EnumDescriptorProto]
    public init(descriptorSet data: Data) throws {
        guard !data.isEmpty, data.count <= 8 * 1024 * 1024 else { throw BrokerError.limit }
        var options = BinaryDecodingOptions()
        options.messageDepthLimit = 64
        let set: Google_Protobuf_FileDescriptorSet
        do {
            set = try Google_Protobuf_FileDescriptorSet(serializedBytes: data, options: options)
        } catch { throw ProtobufError.malformed }
        guard !set.file.isEmpty, set.file.count <= 128 else { throw BrokerError.limit }
        var files: Set<String> = []
        var symbols: Set<String> = []
        var messages: [String: ProtoMessage] = [:]
        var enums: [String: Google_Protobuf_EnumDescriptorProto] = [:]
        var methods: [ProtobufMethod] = []
        var fieldCount = 0
        func identifier(_ name: String) -> Bool { GraphQL.isName(name) }
        func fullName(_ name: String) -> Bool {
            !name.isEmpty
                && name.split(separator: ".", omittingEmptySubsequences: false).allSatisfy {
                    identifier(String($0))
                }
        }
        func register(_ name: String) throws {
            guard fullName(name), symbols.count < 20000, symbols.insert(name).inserted else {
                throw ProtobufError.malformed
            }
        }
        func enumeration(_ descriptor: Google_Protobuf_EnumDescriptorProto, prefix: String) throws {
            guard identifier(descriptor.name), !descriptor.value.isEmpty,
                descriptor.value.count <= 10000
            else { throw ProtobufError.malformed }
            let name = prefix + descriptor.name
            try register(name)
            var names: Set<String> = []
            for value in descriptor.value {
                guard identifier(value.name), names.insert(value.name).inserted else {
                    throw ProtobufError.malformed
                }
            }
            enums[name] = descriptor
        }
        func message(
            _ descriptor: Google_Protobuf_DescriptorProto, prefix: String, syntax: String,
            depth: Int
        ) throws {
            guard depth <= 32, identifier(descriptor.name), descriptor.oneofDecl.count <= 1000
            else { throw ProtobufError.malformed }
            guard descriptor.extension.isEmpty, descriptor.extensionRange.isEmpty else {
                throw ProtobufError.unsupported
            }
            let name = prefix + descriptor.name
            try register(name)
            messages[name] = ProtoMessage(descriptor: descriptor, syntax: syntax)
            var aliases: [String: Int32] = [:]
            var names: Set<String> = []
            var jsonNames: Set<String> = []
            var numbers: Set<Int32> = []
            var oneofs: Set<String> = []
            for oneof in descriptor.oneofDecl {
                guard identifier(oneof.name), oneofs.insert(oneof.name).inserted else {
                    throw ProtobufError.malformed
                }
            }
            for field in descriptor.field {
                fieldCount += 1
                guard fieldCount <= 100000, identifier(field.name),
                    names.insert(field.name).inserted,
                    field.number > 0, field.number <= 536870911,
                    !(19000...19999).contains(field.number), numbers.insert(field.number).inserted,
                    field.type != .group, (1...3).contains(field.label.rawValue),
                    (1...18).contains(field.type.rawValue)
                else { throw ProtobufError.malformed }
                let jsonName = field.jsonName.isEmpty ? Self.jsonName(field.name) : field.jsonName
                guard !jsonName.isEmpty, jsonName.utf8.count <= 1024,
                    jsonNames.insert(jsonName).inserted
                else { throw ProtobufError.malformed }
                for alias in [field.name, jsonName] {
                    guard aliases[alias] == nil || aliases[alias] == field.number else {
                        throw ProtobufError.malformed
                    }
                    aliases[alias] = field.number
                }
                if field.hasOneofIndex {
                    guard field.oneofIndex >= 0, field.oneofIndex < descriptor.oneofDecl.count,
                        field.label != .repeated
                    else { throw ProtobufError.malformed }
                }
                if syntax == "proto3" && field.label == .required { throw ProtobufError.malformed }
                if field.type == .message || field.type == .enum {
                    guard field.typeName.hasPrefix("."),
                        fullName(String(field.typeName.dropFirst()))
                    else { throw ProtobufError.malformed }
                }
                if !field.extendee.isEmpty { throw ProtobufError.unsupported }
            }
            for child in descriptor.nestedType {
                try message(child, prefix: name + ".", syntax: syntax, depth: depth + 1)
            }
            for child in descriptor.enumType { try enumeration(child, prefix: name + ".") }
        }
        for file in set.file {
            guard !file.name.isEmpty, file.name.utf8.count <= 4096, files.insert(file.name).inserted
            else { throw ProtobufError.malformed }
            guard file.syntax.isEmpty || file.syntax == "proto2" || file.syntax == "proto3",
                !file.hasEdition, file.extension.isEmpty
            else { throw ProtobufError.unsupported }
            guard file.package.isEmpty || fullName(file.package) else {
                throw ProtobufError.malformed
            }
            let prefix = file.package.isEmpty ? "" : file.package + "."
            let syntax = file.syntax.isEmpty ? "proto2" : file.syntax
            for descriptor in file.messageType {
                try message(descriptor, prefix: prefix, syntax: syntax, depth: 0)
            }
            for descriptor in file.enumType { try enumeration(descriptor, prefix: prefix) }
            for service in file.service {
                let name = prefix + service.name
                guard identifier(service.name) else { throw ProtobufError.malformed }
                try register(name)
                var names: Set<String> = []
                for method in service.method {
                    guard methods.count < 2000, identifier(method.name),
                        names.insert(method.name).inserted, method.inputType.hasPrefix("."),
                        method.outputType.hasPrefix(".")
                    else { throw ProtobufError.malformed }
                    let mode: GRPCCallMode =
                        method.clientStreaming
                        ? (method.serverStreaming ? .bidirectional : .clientStreaming)
                        : (method.serverStreaming ? .serverStreaming : .unary)
                    methods.append(
                        ProtobufMethod(
                            service: name, name: method.name,
                            inputType: String(method.inputType.dropFirst()),
                            outputType: String(method.outputType.dropFirst()), mode: mode))
                }
            }
        }
        for file in set.file {
            for dependency in file.dependency {
                guard files.contains(dependency) else { throw ProtobufError.malformed }
            }
        }
        for message in messages.values {
            for field in message.descriptor.field {
                let typeName = String(field.typeName.dropFirst())
                if field.type == .message && messages[typeName] == nil {
                    throw ProtobufError.missingType
                }
                if field.type == .enum && enums[typeName] == nil { throw ProtobufError.missingType }
            }
            if message.descriptor.options.mapEntry {
                let fields = message.descriptor.field
                guard fields.count == 2, fields[0].number == 1, fields[1].number == 2,
                    fields[0].name == "key", fields[1].name == "value",
                    fields.allSatisfy({ $0.label == .optional && !$0.hasOneofIndex }),
                    ![
                        Google_Protobuf_FieldDescriptorProto.TypeEnum.message, .bytes, .float,
                        .double, .enum, .group,
                    ].contains(fields[0].type)
                else { throw ProtobufError.malformed }
            }
        }
        for method in methods {
            guard messages[method.inputType] != nil, messages[method.outputType] != nil else {
                throw ProtobufError.missingType
            }
        }
        self.messages = messages
        self.enums = enums
        self.methods = methods.sorted { $0.id < $1.id }
        snapshot = data
    }
    static func jsonName(_ name: String) -> String {
        var upper = false
        var result = ""
        for character in name {
            if character == "_" {
                upper = true
            } else {
                result += upper ? String(character).uppercased() : String(character)
                upper = false
            }
        }
        return result
    }
    public func sample(message: String) throws -> String {
        guard messages[message] != nil else { throw ProtobufError.missingType }
        return "{}"
    }
}
