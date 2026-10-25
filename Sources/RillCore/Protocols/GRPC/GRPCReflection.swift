import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2TransportServices
import SwiftProtobuf

public enum GRPCReflection {
    public static func discover(_ configuration: GRPCConfiguration) async throws -> ProtobufSchema {
        let worker = Task {
            do {
                return try await discover(configuration, namespace: "grpc.reflection.v1")
            } catch let error as RPCError where error.code == .unimplemented {
                return try await discover(configuration, namespace: "grpc.reflection.v1alpha")
            }
        }
        let timer = Task {
            do {
                try await Task.sleep(for: .seconds(60))
                worker.cancel()
            } catch {}
        }
        defer { timer.cancel() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }
    private static func discover(_ configuration: GRPCConfiguration, namespace: String) async throws
        -> ProtobufSchema
    {
        let listed = try await exchange(
            configuration, namespace: namespace,
            request: ProtoWire.field(7, wire: 2, ProtoWire.delimited(Data())))
        let services = try names(listed)
        guard services.count <= 128 else { throw BrokerError.limit }
        var files: [String: Google_Protobuf_FileDescriptorProto] = [:]
        var bytes = 0
        var options = BinaryDecodingOptions()
        options.messageDepthLimit = 64
        func add(_ response: Data) throws {
            for data in try descriptors(response) {
                bytes += data.count
                guard bytes <= 8 * 1024 * 1024 else { throw BrokerError.limit }
                let file = try Google_Protobuf_FileDescriptorProto(
                    serializedBytes: data, options: options)
                guard !file.name.isEmpty, file.name.utf8.count <= 4096 else {
                    throw ProtobufError.malformed
                }
                if let previous = files[file.name] {
                    guard previous == file else { throw ProtobufError.malformed }
                } else {
                    guard files.count < 128 else { throw BrokerError.limit }
                    files[file.name] = file
                }
            }
        }
        for service in services {
            try Task.checkCancellation()
            // Reflection implementations may expose their own descriptor.proto extension graph;
            // request application symbols and their actual imports instead.
            if service.hasPrefix("grpc.reflection.") { continue }
            try add(
                await exchange(
                    configuration, namespace: namespace,
                    request: ProtoWire.field(4, wire: 2, ProtoWire.delimited(Data(service.utf8)))))
        }
        var requested: Set<String> = []
        while let missing = files.values.flatMap(\.dependency).first(where: { files[$0] == nil }) {
            guard requested.insert(missing).inserted, requested.count <= 128,
                missing.utf8.count <= 4096
            else { throw ProtobufError.malformed }
            try add(
                await exchange(
                    configuration, namespace: namespace,
                    request: ProtoWire.field(3, wire: 2, ProtoWire.delimited(Data(missing.utf8)))))
        }
        var set = Google_Protobuf_FileDescriptorSet()
        set.file = files.values.sorted { $0.name < $1.name }
        return try ProtobufSchema(descriptorSet: set.serializedData())
    }
    private static func exchange(
        _ configuration: GRPCConfiguration, namespace: String, request: Data
    ) async throws -> Data {
        let transport = try GRPCSession.transport(configuration)
        let metadata = try GRPCSession.metadata(configuration.metadata)
        var options = CallOptions.defaults
        options.timeout = .seconds(configuration.timeout)
        options.waitForReady = false
        options.maxRequestMessageBytes = 1024 * 1024
        options.maxResponseMessageBytes = 8 * 1024 * 1024
        let callOptions = options
        return try await withGRPCClient(transport: transport) { client in
            let stream = StreamingClientRequest(of: Data.self, metadata: metadata) { writer in
                try await writer.write(request)
            }
            return try await client.bidirectionalStreaming(
                request: stream,
                descriptor: MethodDescriptor(
                    fullyQualifiedService: namespace + ".ServerReflection",
                    method: "ServerReflectionInfo"), serializer: GRPCDataSerializer(),
                deserializer: ReflectionDeserializer(), options: callOptions
            ) { response in
                var result: Data?
                for try await message in response.messages {
                    guard result == nil else { throw ProtobufError.malformed }
                    result = message
                }
                guard let result else { throw ProtobufError.malformed }
                return result
            }
        }
    }
    private static func payload(_ data: Data, expected: UInt64) throws -> Data {
        var reader = ProtoWireReader(data: data)
        var result: Data?
        var fields = 0
        while reader.remaining > 0 {
            fields += 1
            guard fields <= 1000 else { throw BrokerError.limit }
            let tag = try reader.varint()
            guard tag >> 3 > 0 else { throw ProtobufError.malformed }
            if tag >> 3 == 7 {
                guard tag & 7 == 2 else { throw ProtobufError.malformed }
                var error = ProtoWireReader(data: try reader.delimited(limit: 8 * 1024 * 1024))
                var code: UInt64 = 0
                while error.remaining > 0 {
                    let tag = try error.varint()
                    if tag == 8 {
                        code = try error.varint()
                    } else {
                        try error.skip(Int(tag & 7), field: tag >> 3)
                    }
                }
                if code == 12 {
                    throw RPCError(code: .unimplemented, message: "Reflection unavailable")
                }
                throw BrokerError.rejected(Int(clamping: code))
            }
            if tag >> 3 == expected {
                guard result == nil, tag & 7 == 2 else { throw ProtobufError.malformed }
                result = try reader.delimited(limit: 8 * 1024 * 1024)
            } else {
                try reader.skip(Int(tag & 7), field: tag >> 3)
            }
        }
        guard let result else { throw ProtobufError.malformed }
        return result
    }
    private static func names(_ response: Data) throws -> [String] {
        var reader = ProtoWireReader(data: try payload(response, expected: 6))
        var names: Set<String> = []
        while reader.remaining > 0 {
            let tag = try reader.varint()
            guard tag == 10 else { throw ProtobufError.malformed }
            var service = ProtoWireReader(data: try reader.delimited(limit: 8 * 1024 * 1024))
            guard try service.varint() == 10,
                let name = String(
                    data: try service.delimited(limit: 8 * 1024 * 1024), encoding: .utf8),
                service.remaining == 0,
                !name.isEmpty, name.utf8.count <= 1024,
                name.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({
                    GraphQL.isName(String($0))
                }), names.insert(name).inserted, names.count <= 128
            else { throw ProtobufError.malformed }
        }
        return names.sorted()
    }
    private static func descriptors(_ response: Data) throws -> [Data] {
        var reader = ProtoWireReader(data: try payload(response, expected: 4))
        var files: [Data] = []
        while reader.remaining > 0 {
            guard try reader.varint() == 10, files.count < 128 else {
                throw ProtobufError.malformed
            }
            files.append(try reader.delimited(limit: 8 * 1024 * 1024))
        }
        guard !files.isEmpty else { throw ProtobufError.malformed }
        return files
    }
}
private struct ReflectionDeserializer: MessageDeserializer {
    func deserialize<Bytes: GRPCContiguousBytes>(_ bytes: Bytes) throws -> Data {
        guard bytes.count <= 8 * 1024 * 1024 else { throw BrokerError.limit }
        return bytes.withUnsafeBytes { Data($0) }
    }
}
