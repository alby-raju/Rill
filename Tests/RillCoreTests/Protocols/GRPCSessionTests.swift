import GRPCCore
import GRPCNIOTransportHTTP2TransportServices
import SwiftProtobuf
import XCTest

@testable import RillCore

@MainActor final class GRPCSessionTests: XCTestCase {
    func server() throws -> (
        GRPCServer<HTTP2ServerTransport.TransportServices>, HTTP2ServerTransport.TransportServices
    ) {
        let transport = HTTP2ServerTransport.TransportServices(
            address: .ipv4(host: "127.0.0.1", port: 0), transportSecurity: .plaintext)
        var router = RPCRouter<HTTP2ServerTransport.TransportServices>()
        for mode in GRPCCallMode.allCases {
            let descriptor = MethodDescriptor(
                fullyQualifiedService: "rill.tests.Echo", method: mode.rawValue)
            router.registerHandler(
                forMethod: descriptor, deserializer: GRPCDataSerializer(),
                serializer: GRPCDataSerializer()
            ) { request, _ in
                StreamingServerResponse(
                    of: Data.self, metadata: ["fixture-mode": .string(mode.rawValue)]
                ) { writer in
                    var collected = Data()
                    for try await message in request.messages {
                        if mode == .clientStreaming {
                            collected += message
                        } else {
                            try await writer.write(message)
                            if mode == .serverStreaming { try await writer.write(message) }
                        }
                    }
                    if mode == .clientStreaming { try await writer.write(collected) }
                    return ["fixture-trailer": "complete"]
                }
            }
        }
        var message = Google_Protobuf_DescriptorProto()
        message.name = "Message"
        var field = Google_Protobuf_FieldDescriptorProto()
        field.name = "text"
        field.number = 1
        field.type = .string
        field.label = .optional
        message.field = [field]
        var service = Google_Protobuf_ServiceDescriptorProto()
        service.name = "Echo"
        for mode in GRPCCallMode.allCases {
            var method = Google_Protobuf_MethodDescriptorProto()
            method.name = mode.rawValue
            method.inputType = ".rill.tests.Message"
            method.outputType = method.inputType
            method.clientStreaming = mode == .clientStreaming || mode == .bidirectional
            method.serverStreaming = mode == .serverStreaming || mode == .bidirectional
            service.method.append(method)
        }
        var file = Google_Protobuf_FileDescriptorProto()
        file.name = "fixture.proto"
        file.package = "rill.tests"
        file.syntax = "proto3"
        file.messageType = [message]
        file.service = [service]
        let descriptorBytes = try file.serializedData()
        router.registerHandler(
            forMethod: MethodDescriptor(
                fullyQualifiedService: "grpc.reflection.v1alpha.ServerReflection",
                method: "ServerReflectionInfo"), deserializer: GRPCDataSerializer(),
            serializer: GRPCDataSerializer()
        ) { request, _ in
            StreamingServerResponse(of: Data.self, metadata: [:]) { writer in
                for try await message in request.messages {
                    var reader = ProtoWireReader(data: message)
                    let tag = try reader.varint()
                    let response: Data
                    if tag >> 3 == 7 {
                        let service = ProtoWire.field(
                            1, wire: 2, ProtoWire.delimited(Data("rill.tests.Echo".utf8)))
                        response = ProtoWire.field(
                            6, wire: 2,
                            ProtoWire.delimited(
                                ProtoWire.field(1, wire: 2, ProtoWire.delimited(service))))
                    } else {
                        response = ProtoWire.field(
                            4, wire: 2,
                            ProtoWire.delimited(
                                ProtoWire.field(1, wire: 2, ProtoWire.delimited(descriptorBytes))))
                    }
                    try await writer.write(response)
                }
                return [:]
            }
        }
        return (GRPCServer(transport: transport, router: router), transport)
    }
    func testAllFourModesOnActualHTTP2AndHalfClose() async throws {
        let (server, transport) = try server()
        let worker = Task { try await server.serve() }
        defer {
            server.beginGracefulShutdown()
            worker.cancel()
        }
        let address = try await transport.listeningAddress
        guard let port = address.ipv4?.port else { return XCTFail("Expected IPv4") }
        for mode in GRPCCallMode.allCases {
            let session = GRPCSession()
            let records = LiveRecords()
            var configuration = GRPCConfiguration()
            configuration.endpoint = "grpc://127.0.0.1:\(port)"
            configuration.timeout = 3
            configuration.metadata = [Field(name: "fixture-bin", value: "AP8=")]
            let method = ProtobufMethod(
                service: "rill.tests.Echo", name: mode.rawValue, inputType: "Message",
                outputType: "Message", mode: mode)
            try await session.start(
                configuration, method: method, initialMessage: Data([1]),
                onRecord: { await records.add($0) })
            if mode == .clientStreaming || mode == .bidirectional {
                try await session.send(Data([2]))
                try await session.finishSending()
            }
            for _ in 0..<400 {
                if await records.snapshot().contains(where: {
                    $0.kind == .close || $0.kind == .error
                }) {
                    break
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            let received = await records.snapshot()
            XCTAssertFalse(
                received.contains { $0.kind == .error }, "\(mode): \(received.map(\.text))")
            XCTAssertTrue(received.contains { $0.kind == .close }, "\(mode)")
            let messages = received.filter { $0.direction == .inbound }.map(\.data)
            switch mode {
            case .unary: XCTAssertEqual(messages, [Data([1])])
            case .serverStreaming: XCTAssertEqual(messages, [Data([1]), Data([1])])
            case .clientStreaming: XCTAssertEqual(messages, [Data([1, 2])])
            case .bidirectional: XCTAssertEqual(messages, [Data([1]), Data([2])])
            }
            await session.stop()
        }
    }
    func testReflectionFallsBackToAlphaAndReturnsOfflineDescriptors() async throws {
        let (server, transport) = try server()
        let worker = Task { try await server.serve() }
        defer {
            server.beginGracefulShutdown()
            worker.cancel()
        }
        let address = try await transport.listeningAddress
        guard let port = address.ipv4?.port else { return XCTFail("Expected IPv4") }
        var configuration = GRPCConfiguration()
        configuration.endpoint = "grpc://127.0.0.1:\(port)"
        configuration.timeout = 2
        let schema = try await GRPCReflection.discover(configuration)
        XCTAssertEqual(schema.methods.count, 4)
        let offline = try ProtobufSchema(descriptorSet: schema.snapshot)
        XCTAssertEqual(offline.methods, schema.methods)
        let data = try offline.encode(
            json: #"{"text":"reflection"}"#, message: "rill.tests.Message")
        XCTAssertEqual(
            try offline.decode(data: data, message: "rill.tests.Message"), #"{"text":"reflection"}"#
        )
    }
    func testDeadlineAndImmediateCancelThenNewSession() async throws {
        let (server, transport) = try server()
        let worker = Task { try await server.serve() }
        defer {
            server.beginGracefulShutdown()
            worker.cancel()
        }
        let address = try await transport.listeningAddress
        guard let port = address.ipv4?.port else { return XCTFail("Expected IPv4") }
        var configuration = GRPCConfiguration()
        configuration.endpoint = "grpc://127.0.0.1:\(port)"
        configuration.timeout = 1
        let session = GRPCSession()
        let records = LiveRecords()
        let method = ProtobufMethod(
            service: "rill.tests.Echo", name: "bidirectional", inputType: "Message",
            outputType: "Message", mode: .bidirectional)
        try await session.start(
            configuration, method: method, initialMessage: Data([1]),
            onRecord: { await records.add($0) })
        for _ in 0..<200 {
            if await records.snapshot().contains(where: { $0.kind == .error }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let timedOut = await records.snapshot()
        XCTAssertTrue(
            timedOut.contains { $0.kind == .error && $0.text.contains("deadlineExceeded") })
        await session.stop()
        try await session.start(
            configuration, method: method, initialMessage: Data([2]), onRecord: { _ in })
        await session.stop()
        let fresh = LiveRecords()
        try await session.start(
            configuration, method: method, initialMessage: Data([3]),
            onRecord: { await fresh.add($0) })
        try await session.finishSending()
        for _ in 0..<200 {
            if await fresh.snapshot().contains(where: { $0.kind == .close || $0.kind == .error }) {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let completed = await fresh.snapshot()
        XCTAssertTrue(completed.contains { $0.kind == .close })
        XCTAssertFalse(completed.contains { $0.kind == .error })
        await session.stop()
    }
    func testMetadataValidationAndExplicitPlaintextBoundary() throws {
        XCTAssertNoThrow(try GRPCSession.metadata([Field(name: "valid-bin", value: "AP8=")]))
        XCTAssertThrowsError(try GRPCSession.metadata([Field(name: "grpc-timeout", value: "1S")]))
        XCTAssertThrowsError(try GRPCSession.metadata([Field(name: "bad-bin", value: "invalid")]))
        XCTAssertThrowsError(try GRPCSession.metadata([Field(name: "upperCase", value: "value")]))
        var configuration = GRPCConfiguration()
        configuration.endpoint = "localhost:50051"
        XCTAssertThrowsError(try GRPCSession.transport(configuration))
        configuration.endpoint = "grpcs://example.com/path"
        XCTAssertThrowsError(try GRPCSession.transport(configuration))
    }
}
