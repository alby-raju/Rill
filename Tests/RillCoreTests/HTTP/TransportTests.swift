import XCTest

@testable import RillCore

@MainActor final class TransportTests: XCTestCase {
    private func draft(_ path: String) throws -> RequestDraft {
        guard let base = ProcessInfo.processInfo.environment["RILL_TEST_BASE_URL"] else {
            throw XCTSkip(
                "Start scripts/http-fixture.py and set RILL_TEST_BASE_URL to run loopback transport checks."
            )
        }
        var request = RequestDraft()
        request.url = base + path
        return request
    }
    func testRealResponseAndChecks() async throws {
        var request = try draft("/json")
        request.expectedStatus = "200"
        request.bodyContains = "hello from fixture"
        let exchange = try await RequestEngine.execute(request, environment: nil)
        XCTAssertEqual(exchange.status, 200)
        XCTAssertTrue(exchange.checks.allSatisfy(\.passed))
        XCTAssertTrue(
            exchange.headers.contains { $0.name.lowercased() == "x-fixture" && $0.value == "Rill" })
    }
    func testOversizedResponseIsRejected() async throws {
        let request = try draft("/large")
        do {
            _ = try await RequestEngine.execute(request, environment: nil)
            XCTFail("Oversized response was accepted")
        } catch RillError.responseTooLarge {}
    }
    func testCancellationInterruptsTransport() async throws {
        let request = try draft("/slow")
        let started = Date()
        let task = Task { try await RequestEngine.execute(request, environment: nil) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Request was not cancelled")
        } catch is CancellationError {} catch let error as URLError {
            XCTAssertEqual(error.code, .cancelled)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }
    func testExactDownloadBudgetSucceedsForKnownUnknownAndChunkedLengths() async throws {
        let budget = try ResponseBudget(downloadBytes: 4096)
        for mode in ["bytes", "unknown", "chunked"] {
            let request = try draft("/\(mode)/4096")
            let exchange = try await RequestEngine.execute(
                request, environment: nil, budget: budget)
            XCTAssertEqual(exchange.body.count, 4096, mode)
        }
    }
    func testKnownUnknownAndChunkedOverflowNeverReturnsPartialSuccess() async throws {
        let budget = try ResponseBudget(downloadBytes: 4096)
        for mode in ["bytes", "unknown", "chunked"] {
            let request = try draft("/\(mode)/4097")
            do {
                _ = try await RequestEngine.execute(request, environment: nil, budget: budget)
                XCTFail("Oversized \(mode) response was accepted")
            } catch RillError.responseTooLarge {}
        }
    }

    func testStructuredFormAndAuthMatchPreparedWireRequest() async throws {
        var request = try draft("/echo?existing=%2f")
        request.method = .POST
        request.bodyMode = .form
        request.formFields = [Field(name: "name", value: "a+b c")]
        request.auth = .apiKey
        request.apiKeyName = "X-Key"
        request.credential = "fixture-token"
        let exchange = try await RequestEngine.execute(request, environment: nil)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: exchange.body) as? [String: Any])
        XCTAssertEqual(object["method"] as? String, "POST")
        XCTAssertEqual(object["path"] as? String, "/echo?existing=%2f")
        let body = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(object["body"] as? String)))
        XCTAssertEqual(String(decoding: body, as: UTF8.self), "name=a%2Bb+c")
        let headers = try XCTUnwrap(object["headers"] as? [String: String])
        XCTAssertEqual(headers.first { $0.key.lowercased() == "x-key" }?.value, "fixture-token")
        XCTAssertEqual(exchange.preparedRequest?.bodyBytes, body.count)
        XCTAssertEqual(
            exchange.preparedRequest?.headers.first { $0.name.lowercased() == "x-key" }?.value,
            "[redacted]")
    }

    func testBinaryStreamReplaysOnSameOriginRedirectAndStopsAtCrossOrigin() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let payload = Data(repeating: 42, count: 150_000)
        try payload.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        var request = try draft("/redirect-same")
        request.method = .POST
        request.bodyMode = .binary
        request.binaryFile = try UploadFileReference.capture(file)
        let exchange = try await RequestEngine.execute(request, environment: nil)
        XCTAssertEqual(exchange.status, 200)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: exchange.body) as? [String: Any])
        XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(object["body"] as? String)), payload)
        XCTAssertTrue(exchange.url.hasSuffix("/echo"))
        request.url = try draft("/redirect-cross").url
        let redirect = try await RequestEngine.execute(request, environment: nil)
        XCTAssertEqual(redirect.status, 307)
    }
    func testMultipartWireBoundaryAndFileBytes() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([0, 255, 13, 10]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        var request = try draft("/echo")
        request.method = .POST
        request.bodyMode = .multipart
        var part = MultipartPart()
        part.name = "file"
        part.kind = .file
        part.file = try UploadFileReference.capture(file)
        part.filename = "fixture.bin"
        part.contentType = "application/octet-stream"
        request.multipartParts = [part]
        let exchange = try await RequestEngine.execute(request, environment: nil)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: exchange.body) as? [String: Any])
        let data = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(object["body"] as? String)))
        let headers = try XCTUnwrap(object["headers"] as? [String: String])
        let type = try XCTUnwrap(headers.first { $0.key.lowercased() == "content-type" }?.value)
        let boundary = try XCTUnwrap(type.components(separatedBy: "boundary=").last)
        XCTAssertTrue(data.starts(with: Data(("--" + boundary + "\r\n").utf8)))
        XCTAssertNotNil(data.range(of: Data([0, 255, 13, 10])))
        XCTAssertEqual(exchange.preparedRequest?.bodyBytes, data.count)
    }

    func testDecompressedBytesRespectDownloadAndIndependentPreviewLimits() async throws {
        let budget = try ResponseBudget(downloadBytes: 4096, previewBytes: 128)
        let exact = try await RequestEngine.execute(
            draft("/gzip/4096"), environment: nil, budget: budget)
        XCTAssertEqual(exact.body.count, 4096)
        XCTAssertTrue(exact.previewIsTruncated)
        XCTAssertEqual(exact.previewText(pretty: false).count, 128)
        XCTAssertEqual(exact.events?.count, 3)
        do {
            _ = try await RequestEngine.execute(
                draft("/gzip/4097"), environment: nil, budget: budget)
            XCTFail("Decompression exceeded budget")
        } catch RillError.responseTooLarge {}
    }
    func testTimeoutDiffersFromCancellationAndChunkedBodyCancels() async throws {
        var timeout = try draft("/slow")
        timeout.timeout = 1
        do {
            _ = try await RequestEngine.execute(timeout, environment: nil)
            XCTFail("Stalled headers did not time out")
        } catch let error as URLError { XCTAssertEqual(error.code, .timedOut) }
        let chunks = try draft("/slow-chunks")
        let started = Date()
        let task = Task { try await RequestEngine.execute(chunks, environment: nil) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Stalled body was not cancelled")
        } catch is CancellationError {} catch let error as URLError {
            XCTAssertEqual(error.code, .cancelled)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }

}
