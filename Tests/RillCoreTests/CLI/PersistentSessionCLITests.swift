import Darwin
import XCTest

@testable import RillCore

@MainActor final class PersistentSessionCLITests: XCTestCase {
    private func cli(_ args: [String]) async throws -> ProcessRunResult {
        guard let path = ProcessInfo.processInfo.environment["RILL_TEST_CLI_PATH"] else {
            throw XCTSkip("Built CLI required")
        }
        return try await BoundedProcess.run(executable: URL(fileURLWithPath: path), arguments: args)
    }

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func key(_ url: URL, character: Character = "a") throws {
        try Data((String(repeating: character, count: 64) + "\n").utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func echo(
        _ base: String, path: String = "/echo", root: URL, options: [String]
    ) async throws -> [String: String] {
        let output = root.appendingPathComponent(UUID().uuidString + ".json")
        let result = try await cli(
            ["request", "GET", base + path, "--output", output.path] + options)
        XCTAssertEqual(result.status, 0, String(decoding: result.diagnostics, as: UTF8.self))
        let document = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: output)) as? [String: Any])
        let headers = try XCTUnwrap(document["headers"] as? [String: String])
        return Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) })
    }

    func testEncryptedSessionPersistsScopedCookiesAcrossProcessesAndExpiresThem() async throws {
        let base = try XCTUnwrap(ProcessInfo.processInfo.environment["RILL_TEST_BASE_URL"])
        let root = try directory()
        let session = root.appendingPathComponent("session.rill")
        let key = root.appendingPathComponent("key.txt")
        try self.key(key)
        let options = ["--session", session.path, "--session-key-file", key.path]
        let first = try await cli(
            [
                "request", "GET", base + "/cookie/set", "-H", "Authorization: Bearer private-token",
                "--download", root.appendingPathComponent("empty.bin").path, "--json",
            ] + options)
        XCTAssertEqual(first.status, 0, String(decoding: first.diagnostics, as: UTF8.self))
        let encrypted = try Data(contentsOf: session)
        XCTAssertNil(encrypted.range(of: Data("fixture".utf8)))
        XCTAssertNil(encrypted.range(of: Data("private-token".utf8)))
        let permissions = try FileManager.default.attributesOfItem(atPath: session.path)[
            .posixPermissions]
        XCTAssertEqual(permissions as? NSNumber, 0o600)
        XCTAssertFalse(
            String(decoding: first.output + first.diagnostics, as: UTF8.self).contains("fixture"))

        let regular = try await echo(base, root: root, options: options)
        XCTAssertEqual(regular["cookie"], "session=fixture")
        XCTAssertNil(regular["authorization"])
        let scoped = try await echo(base, path: "/echo/scoped", root: root, options: options)
        XCTAssertEqual(
            Set(
                (scoped["cookie"] ?? "").split(separator: ";").map {
                    $0.trimmingCharacters(in: .whitespaces)
                }),
            ["scoped=fixture", "session=fixture"])
        let isolated = try await echo(base, root: root, options: [])
        XCTAssertNil(isolated["cookie"])
        let redirect = try await cli(["request", "GET", base + "/cookie/redirect"] + options)
        XCTAssertEqual(redirect.status, 0)
        let expired = try await cli(["request", "GET", base + "/cookie/expire"] + options)
        XCTAssertEqual(expired.status, 0)
        let remaining = try await echo(base, root: root, options: options)
        XCTAssertEqual(remaining["cookie"], "redirect=fixture")
    }

    func testSessionRejectsWrongKeyOriginUnsafeOptionsAndConcurrentAccess() async throws {
        let base = try XCTUnwrap(ProcessInfo.processInfo.environment["RILL_TEST_BASE_URL"])
        let root = try directory()
        let session = root.appendingPathComponent("session.rill")
        let key = root.appendingPathComponent("key.txt")
        let wrongKey = root.appendingPathComponent("wrong-key.txt")
        try self.key(key)
        try self.key(wrongKey, character: "b")
        let options = ["--session", session.path, "--session-key-file", key.path]
        let setup = try await cli(["request", "GET", base + "/cookie/set"] + options)
        XCTAssertEqual(setup.status, 0)
        let original = try Data(contentsOf: session)
        let request = ["request", "GET", base + "/echo"]
        let invalid: [[String]] = [
            request + ["--session", session.path, "--session-key-file", wrongKey.path],
            ["request", "GET", "http://127.0.0.1:1/echo"] + options,
            request + options + ["--insecure"],
            request + options + ["-H", "Cookie: private=value"],
            request + options + ["--output", session.path, "--overwrite"],
            request + options + ["--download", key.path, "--overwrite"],
        ]
        for command in invalid {
            let result = try await cli(command)
            XCTAssertEqual(result.status, 2, String(decoding: result.diagnostics, as: UTF8.self))
            XCTAssertFalse(
                String(decoding: result.diagnostics, as: UTF8.self).contains("private=value"))
            XCTAssertEqual(try Data(contentsOf: session), original)
        }

        let descriptor = Darwin.open(
            session.appendingPathExtension("lock").path, O_RDWR | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { Darwin.close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
        let busy = try await cli(request + options)
        XCTAssertEqual(busy.status, 2)
        XCTAssertTrue(String(decoding: busy.diagnostics, as: UTF8.self).contains("in use"))
        XCTAssertEqual(flock(descriptor, LOCK_UN), 0)

        var tampered = original
        tampered[tampered.index(before: tampered.endIndex)] ^= 1
        try tampered.write(to: session)
        let authenticationFailed = try await cli(request + options)
        XCTAssertEqual(authenticationFailed.status, 2)
        XCTAssertEqual(try Data(contentsOf: session), tampered)
        try original.write(to: session)

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: key.path)
        let exposed = try await cli(request + options)
        XCTAssertEqual(exposed.status, 2)
        XCTAssertEqual(try Data(contentsOf: session), original)
    }
}
