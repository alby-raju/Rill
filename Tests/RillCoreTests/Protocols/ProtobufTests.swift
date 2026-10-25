import XCTest
import SwiftProtobuf
@testable import RillCore

@MainActor final class ProtobufTests: XCTestCase {
    func schema() throws -> ProtobufSchema {
        func field(_ name: String, _ number: Int32, _ type: Google_Protobuf_FieldDescriptorProto.TypeEnum, repeated: Bool = false, typeName: String = "") -> Google_Protobuf_FieldDescriptorProto {
            var value = Google_Protobuf_FieldDescriptorProto(); value.name = name; value.number = number; value.type = type; value.label = repeated ? .repeated : .optional; value.typeName = typeName; return value
        }
        var body = Google_Protobuf_DescriptorProto(); body.name = "Message"
        body.field = [field("text", 1, .string), field("signed_value", 2, .int64), field("unsigned_value", 3, .uint64), field("numbers", 4, .sint32, repeated: true), field("blob", 5, .bytes), field("ratio", 6, .double)]
        var entry = Google_Protobuf_DescriptorProto(); entry.name = "LabelsEntry"; entry.options.mapEntry = true
        entry.field = [field("key", 1, .string), field("value", 2, .int64)]
        body.nestedType = [entry]; body.field.append(field("labels", 7, .message, repeated: true, typeName: ".rill.tests.Message.LabelsEntry"))
        var choice = Google_Protobuf_OneofDescriptorProto(); choice.name = "choice"; body.oneofDecl = [choice]
        var left = field("left", 8, .string); left.oneofIndex = 0; var right = field("right", 9, .int32); right.oneofIndex = 0; body.field += [left,right]
        var service = Google_Protobuf_ServiceDescriptorProto(); service.name = "Echo"
        for mode in GRPCCallMode.allCases { var method = Google_Protobuf_MethodDescriptorProto(); method.name = mode.rawValue; method.inputType = ".rill.tests.Message"; method.outputType = method.inputType; method.clientStreaming = mode == .clientStreaming || mode == .bidirectional; method.serverStreaming = mode == .serverStreaming || mode == .bidirectional; service.method.append(method) }
        var file = Google_Protobuf_FileDescriptorProto(); file.name = "rill-test.proto"; file.package = "rill.tests"; file.syntax = "proto3"; file.messageType = [body]; file.service = [service]
        var set = Google_Protobuf_FileDescriptorSet(); set.file = [file]
        return try ProtobufSchema(descriptorSet: set.serializedData())
    }
    func testExactIntegerBytesMapAndCardinalityDescriptors() throws {
        let schema = try schema(); XCTAssertEqual(Set(schema.methods.map(\.mode)), Set(GRPCCallMode.allCases))
        let json = #"{"text":"🐟","signedValue":"-9223372036854775808","unsignedValue":"18446744073709551615","numbers":[-1,0,2147483647],"blob":"AP8q","ratio":1.25,"labels":{"x":"9007199254740993"},"left":"selected"}"#
        let wire = try schema.encode(json: json, message: "rill.tests.Message")
        let decoded = try schema.decode(data: wire, message: "rill.tests.Message")
        XCTAssertEqual(try JSONValueParser(Data(decoded.utf8)).parse(), try JSONValueParser(Data(json.utf8)).parse())
        XCTAssertThrowsError(try schema.encode(json: #"{"left":"x","right":1}"#, message: "rill.tests.Message"))
        XCTAssertThrowsError(try schema.encode(json: #"{"signedValue":"9223372036854775808"}"#, message: "rill.tests.Message"))
        XCTAssertThrowsError(try schema.encode(json: #"{"text":"a","unknown":1}"#, message: "rill.tests.Message"))
        XCTAssertThrowsError(try schema.encode(json: #"{"signed_value":1,"signedValue":2}"#, message: "rill.tests.Message"))
    }
    func testPackedFieldsUnknownFieldsAndMalformedWire() throws {
        let schema = try schema()
        let packed = ProtoWire.field(4, wire: 2, ProtoWire.delimited(ProtoWire.varint(1) + ProtoWire.varint(2)))
        let unknown = ProtoWire.field(100, wire: 2, ProtoWire.delimited(Data([1,2,3])))
        let result = try schema.decode(data: packed + unknown, message: "rill.tests.Message")
        XCTAssertEqual(try JSONValueParser(Data(result.utf8)).parse()["numbers"]?.array, [.number("-1e0"), .number("1e0")])
        XCTAssertThrowsError(try schema.decode(data: Data([0]), message: "rill.tests.Message"))
        XCTAssertThrowsError(try schema.decode(data: Data([10, 255]), message: "rill.tests.Message"))
        var reader = ProtoWireReader(data: Data(repeating: 255, count: 10)); XCTAssertThrowsError(try reader.varint())
    }
    func testMalformedDescriptorAndMissingImportsDoNotCrash() throws {
        let schema = try schema()
        var set = try Google_Protobuf_FileDescriptorSet(serializedBytes: schema.snapshot)
        set.file[0].messageType[0].field[1].number = 1
        XCTAssertThrowsError(try ProtobufSchema(descriptorSet: set.serializedData()))
        set = try Google_Protobuf_FileDescriptorSet(serializedBytes: schema.snapshot); set.file[0].dependency = ["missing.proto"]
        XCTAssertThrowsError(try ProtobufSchema(descriptorSet: set.serializedData()))
        XCTAssertThrowsError(try ProtobufSchema(descriptorSet: Data([255])))
    }
    func testWellKnownTimestampUsesOfficialJSONEncoding() throws {
        var timestamp = Google_Protobuf_DescriptorProto(); timestamp.name = "Timestamp"
        var seconds = Google_Protobuf_FieldDescriptorProto(); seconds.name = "seconds"; seconds.number = 1; seconds.type = .int64; seconds.label = .optional
        var nanos = seconds; nanos.name = "nanos"; nanos.number = 2; nanos.type = .int32; timestamp.field = [seconds,nanos]
        var file = Google_Protobuf_FileDescriptorProto(); file.name = "google/protobuf/timestamp.proto"; file.package = "google.protobuf"; file.syntax = "proto3"; file.messageType = [timestamp]
        var set = Google_Protobuf_FileDescriptorSet(); set.file = [file]
        let schema = try ProtobufSchema(descriptorSet: set.serializedData())
        let wire = try schema.encode(json: #""2026-10-24T00:00:00Z""#, message: "google.protobuf.Timestamp")
        let official = try Google_Protobuf_Timestamp(serializedBytes: wire)
        XCTAssertEqual(official.seconds, 1792800000)
        XCTAssertEqual(try schema.decode(data: wire, message: "google.protobuf.Timestamp"), #""2026-10-24T00:00:00Z""#)
    }
}
