import XCTest

@testable import RillCore

@MainActor final class NativeProcessTests: XCTestCase {
    func testBoundedProcessDoesNotInterpretArgumentsAndLimitsOutput() async throws {
        let literal = Data("literal $(no-shell) 🐟".utf8)
        let result = try await BoundedProcess.run(
            executable: URL(fileURLWithPath: "/bin/cat"), arguments: [], input: literal)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output, literal)
        do {
            _ = try await BoundedProcess.run(
                executable: URL(fileURLWithPath: "/usr/bin/yes"), arguments: [], outputLimit: 65536)
            XCTFail("Output must be bounded")
        } catch { XCTAssertTrue(error is ProcessRunError) }
        do {
            _ = try await BoundedProcess.run(
                executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"], timeout: 0.1)
            XCTFail("Deadline must stop child")
        } catch { XCTAssertTrue(error is ProcessRunError) }
        let task = Task {
            try await BoundedProcess.run(
                executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"])
        }
        try await Task.sleep(for: .milliseconds(30))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancellation must stop child")
        } catch { XCTAssertTrue(error is CancellationError) }
    }
    func testBundledProtocImportsAndMissingImportBoundary() async throws {
        guard let path = ProcessInfo.processInfo.environment["RILL_TEST_PROTOC_PATH"],
            let includes = ProcessInfo.processInfo.environment["RILL_TEST_PROTO_INCLUDE"]
        else { throw XCTSkip("Selected Protobuf compiler required") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "rill-proto-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("independent.proto")
        try
            #"syntax = "proto3"; package rill.fixture; import "google/protobuf/timestamp.proto"; message Payload { string message = 1; google.protobuf.Timestamp time = 2; } service Echo { rpc One(Payload) returns(Payload); rpc Stream(stream Payload) returns(stream Payload); }"#
            .write(to: source, atomically: false, encoding: .utf8)
        let schema = try await ProtobufCompiler.compile(
            source, compiler: URL(fileURLWithPath: path),
            wellKnownRoot: URL(fileURLWithPath: includes))
        XCTAssertEqual(schema.methods.count, 2)
        let encoded = try schema.encode(
            json: #"{"message":"new fixture","time":"2026-10-24T00:00:00Z"}"#,
            message: "rill.fixture.Payload")
        XCTAssertTrue(
            try schema.decode(data: encoded, message: "rill.fixture.Payload").contains(
                "new fixture"))
        try #"syntax = "proto3"; import "missing.proto";"#.write(
            to: source, atomically: false, encoding: .utf8)
        do {
            _ = try await ProtobufCompiler.compile(source, compiler: URL(fileURLWithPath: path))
            XCTFail("Missing import must fail")
        } catch {}
        try #"syntax = "proto3"; import "../outside.proto";"#.write(
            to: source, atomically: false, encoding: .utf8)
        do {
            _ = try await ProtobufCompiler.compile(source, compiler: URL(fileURLWithPath: path))
            XCTFail("Escaping import must fail")
        } catch {}
    }
}
