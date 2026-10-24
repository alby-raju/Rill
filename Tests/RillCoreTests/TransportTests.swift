import XCTest
@testable import RillCore

@MainActor final class TransportTests: XCTestCase {
    private func draft(_ path: String) throws -> RequestDraft {
        guard let base = ProcessInfo.processInfo.environment["RILL_TEST_BASE_URL"] else {
            throw XCTSkip("Start scripts/http-fixture.py and set RILL_TEST_BASE_URL to run loopback transport checks.")
        }
        var request = RequestDraft(); request.url = base + path
        return request
    }
    func testRealResponseAndChecks() async throws {
        var request = try draft("/json")
        request.expectedStatus = "200"; request.bodyContains = "hello from fixture"
        let exchange = try await RequestEngine.execute(request, environment: nil)
        XCTAssertEqual(exchange.status, 200)
        XCTAssertTrue(exchange.checks.allSatisfy(\.passed))
        XCTAssertTrue(exchange.headers.contains { $0.name.lowercased() == "x-fixture" && $0.value == "Rill" })
    }
    func testOversizedResponseIsRejected() async throws {
        let request = try draft("/large")
        do { _ = try await RequestEngine.execute(request, environment: nil); XCTFail("Oversized response was accepted") }
        catch RillError.responseTooLarge { }
    }
    func testCancellationInterruptsTransport() async throws {
        let request = try draft("/slow")
        let started = Date()
        let task = Task { try await RequestEngine.execute(request, environment: nil) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        do { _ = try await task.value; XCTFail("Request was not cancelled") }
        catch is CancellationError { }
        catch let error as URLError { XCTAssertEqual(error.code, .cancelled) }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }
    func testExactDownloadBudgetSucceedsForKnownUnknownAndChunkedLengths() async throws {
        let budget = try ResponseBudget(downloadBytes: 4096)
        for mode in ["bytes", "unknown", "chunked"] {
            let request = try draft("/\(mode)/4096")
            let exchange = try await RequestEngine.execute(request, environment: nil, budget: budget)
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
            } catch RillError.responseTooLarge { }
        }
    }

}
