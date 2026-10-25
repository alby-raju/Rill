import XCTest

@testable import RillCore

final class UploadTests: XCTestCase {
    private func withFile(_ body: Data, _ operation: (URL) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try body.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        try operation(url)
    }
    func testBinarySnapshotUsesStreamAndCleanupAndDoesNotLoadHTTPBody() throws {
        try withFile(Data(repeating: 7, count: 150_000)) { url in
            var draft = RequestDraft()
            draft.url = "https://example.test"
            draft.method = .PUT
            draft.bodyMode = .binary
            draft.binaryFile = try UploadFileReference.capture(url)
            let frozen = try RequestEngine.freeze(draft, environment: nil)
            XCTAssertNil(frozen.request.httpBody)
            XCTAssertNotNil(frozen.request.httpBodyStream)
            XCTAssertEqual(frozen.request.value(forHTTPHeaderField: "Content-Length"), "150000")
            let temporary = try XCTUnwrap(frozen.temporaryBody)
            XCTAssertEqual(try Data(contentsOf: temporary), Data(repeating: 7, count: 150_000))
            let permissions =
                try FileManager.default.attributesOfItem(atPath: temporary.path)[.posixPermissions]
                as? NSNumber
            XCTAssertEqual(permissions?.intValue, 0o600)
            frozen.removeTemporaryBody()
            XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path))
        }
    }
    func testMissingAndChangedFilesRejectBeforeTransport() throws {
        try withFile(Data("first".utf8)) { url in
            var draft = RequestDraft()
            draft.url = "https://example.test"
            draft.method = .POST
            draft.bodyMode = .binary
            draft.binaryFile = try UploadFileReference.capture(url)
            try Data("changed".utf8).write(to: url)
            XCTAssertThrowsError(try RequestEngine.freeze(draft, environment: nil))
            try FileManager.default.removeItem(at: url)
            XCTAssertThrowsError(try RequestEngine.freeze(draft, environment: nil))
        }
    }
    func testMultipartBoundaryMetadataOrderDisabledPartsAndNestedVariables() throws {
        try withFile(Data([0, 1, 255])) { url in
            var draft = RequestDraft()
            draft.url = "https://example.test"
            draft.method = .POST
            draft.bodyMode = .multipart
            var text = MultipartPart()
            text.name = "{{key}}"
            text.value = "hello {{name}}"
            var file = MultipartPart()
            file.name = "upload"
            file.kind = .file
            file.file = try UploadFileReference.capture(url)
            file.filename = "quoted\"name.bin"
            file.contentType = "application/octet-stream"
            var json = MultipartPart()
            json.name = "payload"
            json.kind = .json
            json.value = "{\"ok\":true}"
            var disabled = MultipartPart()
            disabled.name = "DISABLED"
            disabled.value = "NOT_SENT"
            disabled.enabled = false
            draft.multipartParts = [text, file, json, disabled]
            draft.headers = [Field(name: "Content-Type", value: "wrong")]
            var environment = Environment(name: "Test")
            environment.variables = [
                Field(name: "key", value: "greeting"), Field(name: "name", value: "world"),
            ]
            let frozen = try RequestEngine.freeze(draft, environment: environment)
            let data = try Data(contentsOf: XCTUnwrap(frozen.temporaryBody))
            let type = try XCTUnwrap(frozen.request.value(forHTTPHeaderField: "Content-Type"))
            let boundary = try XCTUnwrap(type.components(separatedBy: "boundary=").last)
            XCTAssertTrue(data.starts(with: Data(("--" + boundary + "\r\n").utf8)))
            XCTAssertTrue(
                data.suffix(boundary.utf8.count + 6).elementsEqual(
                    Data(("--" + boundary + "--\r\n").utf8)))
            let body = String(decoding: data, as: UTF8.self)
            XCTAssertTrue(body.contains("name=\"greeting\""))
            XCTAssertTrue(body.contains("hello world"))
            XCTAssertTrue(body.contains("filename=\"quoted\\\"name.bin\""))
            XCTAssertTrue(body.contains("Content-Type: application/json"))
            XCTAssertFalse(body.contains("NOT_SENT"))
            XCTAssertLessThan(
                body.range(of: "hello world")!.lowerBound,
                body.range(of: "application/octet-stream")!.lowerBound)
            XCTAssertEqual(
                Int(frozen.request.value(forHTTPHeaderField: "Content-Length")!), data.count)
        }
    }
    func testMultipartInjectionAndGETUploadAreRejected() throws {
        var draft = RequestDraft()
        draft.url = "https://example.test"
        draft.method = .POST
        draft.bodyMode = .multipart
        var part = MultipartPart()
        part.name = "bad\r\nname"
        draft.multipartParts = [part]
        XCTAssertThrowsError(try RequestEngine.freeze(draft, environment: nil))
        part.name = "valid"
        part.contentType = "bad\nMIME"
        draft.multipartParts = [part]
        XCTAssertThrowsError(try RequestEngine.freeze(draft, environment: nil))
        draft.method = .GET
        XCTAssertThrowsError(try RequestEngine.freeze(draft, environment: nil))
    }
    func testSavedDuplicateAndBackupRetainFileReferenceAndPartSettings() throws {
        try withFile(Data("payload".utf8)) { url in
            var draft = RequestDraft()
            draft.method = .POST
            draft.bodyMode = .multipart
            var part = MultipartPart()
            part.name = "upload"
            part.kind = .file
            part.file = try UploadFileReference.capture(url)
            part.filename = "selected.txt"
            draft.multipartParts = [part]
            draft.binaryFile = part.file
            var workspace = Workspace()
            workspace.requests = [draft]
            XCTAssertEqual(
                try WorkspaceFile.decode(WorkspaceFile.encode(workspace)).requests[0], draft)
            let copy = try WorkspaceOperations.duplicate(draft.id, in: &workspace)
            XCTAssertEqual(copy.multipartParts, draft.multipartParts)
            XCTAssertEqual(
                try WorkspaceBackup.decode(
                    WorkspaceBackup.encode(workspace: workspace, editor: nil)
                ).workspace.requests[0].multipartParts, draft.multipartParts)
        }
    }
    func testExactStreamingBudgetAndOneByteOverflow() throws {
        try withFile(Data(repeating: 1, count: 8)) { url in
            var draft = RequestDraft()
            draft.bodyMode = .binary
            draft.binaryFile = try UploadFileReference.capture(url)
            let exact = try UploadBody.create(draft, environment: nil, limit: 8)
            defer { try? FileManager.default.removeItem(at: exact.url) }
            XCTAssertEqual(exact.count, 8)
            XCTAssertThrowsError(try UploadBody.create(draft, environment: nil, limit: 7))
        }
    }

}
