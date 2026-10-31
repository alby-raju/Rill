import XCTest

@testable import RillCore

@MainActor final class FileTLSCLITests: XCTestCase {
    private func cli(_ args: [String]) async throws -> ProcessRunResult {
        guard let executable = ProcessInfo.processInfo.environment["RILL_TEST_CLI_PATH"] else {
            throw XCTSkip("CLI fixture required")
        }
        return try await BoundedProcess.run(
            executable: URL(fileURLWithPath: executable), arguments: args)
    }
    private func root() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }
    private func fixture(_ name: String) throws -> URL {
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["RILL_TEST_TLS_DIR"])
        return URL(fileURLWithPath: path).appendingPathComponent(name)
    }
    private func endpoint(_ mtls: Bool = false) throws -> String {
        try XCTUnwrap(
            ProcessInfo.processInfo.environment[mtls ? "RILL_TEST_MTLS_URL" : "RILL_TEST_TLS_URL"])
    }
    private func input(format: String, url: String) throws -> Data {
        if format == "native" {
            var workspace = Workspace()
            var request = RequestDraft()
            request.url = url
            workspace.requests = [request]
            return try WorkspaceFile.encode(workspace)
        }
        return try JSONSerialization.data(withJSONObject: [
            "info": [
                "name": "Fixture",
                "schema": "https://schema.getpostman.com/json/collection/v2.1.0/collection.json",
            ],
            "item": [["name": "fixture", "request": ["method": "GET", "url": url]]],
        ])
    }
    func testBothFileFormatsUseScopedPEMAndPKCS12WithIterationData() async throws {
        let folder = try root()
        let rows = folder.appendingPathComponent("TLS data.json")
        let data = try JSONSerialization.data(withJSONObject: [
            ["endpoint": endpoint() + "/json"], ["endpoint": endpoint(true) + "/json"],
        ])
        try data.write(to: rows)
        let password = folder.appendingPathComponent("passphrase with spaces.txt")
        let phrase = Data("rill-fixture\r\n".utf8)
        try phrase.write(to: password)
        let ca = try fixture("ca.pem")
        let key = try fixture("client.key")
        let keyData = try Data(contentsOf: key)
        for format in ["postman", "native"] {
            for pkcs12 in [false, true] {
                let suffix = format + (pkcs12 ? "-p12" : "-pem")
                let source = folder.appendingPathComponent(suffix + ".json")
                let report = folder.appendingPathComponent(suffix + "-report.json")
                let output = folder.appendingPathComponent(suffix + "-raw.json")
                let collection = try input(format: format, url: "{{endpoint}}")
                try collection.write(to: source)
                var args = [
                    "run", source.path, "--format", format, "--iteration-data", rows.path,
                    "--ca-cert", ca.path, "--ssl-client-origin", try endpoint(true),
                    "--report", report.path, "--output", output.path, "--json",
                ]
                args +=
                    pkcs12
                    ? [
                        "--ssl-client-p12", try fixture("chained-client.p12").path,
                        "--ssl-passphrase-file", password.path,
                    ]
                    : [
                        "--ssl-client-cert", try fixture("client-bundle.pem").path,
                        "--ssl-client-key", key.path,
                    ]
                let result = try await cli(args)
                XCTAssertEqual(
                    result.status, 0, String(decoding: result.diagnostics, as: UTF8.self))
                let summary = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: result.output) as? [String: Any])
                XCTAssertEqual(summary["passed"] as? Bool, true)
                XCTAssertEqual(summary["attempts"] as? Int, 2)
                XCTAssertEqual(summary["clientIdentityConfigured"] as? Bool, true)
                XCTAssertEqual(summary["tlsPolicy"] as? String, TLSMode.custom.rawValue)
                let raw = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: Data(contentsOf: output)) as? [String: Any])
                XCTAssertEqual(raw["message"] as? String, "TLS fixture")
                let ordinary = try result.output + result.diagnostics + Data(contentsOf: report)
                XCTAssertFalse(String(decoding: ordinary, as: UTF8.self).contains("rill-fixture"))
                XCTAssertFalse(String(decoding: ordinary, as: UTF8.self).contains("-----BEGIN"))
                XCTAssertEqual(try Data(contentsOf: source), collection)
            }
        }
        XCTAssertEqual(try Data(contentsOf: rows), data)
        XCTAssertEqual(try Data(contentsOf: password), phrase)
        XCTAssertEqual(try Data(contentsOf: key), keyData)
    }
    func testSystemTrustHostnameAndInsecureModesHaveExplicitOutcomes() async throws {
        let folder = try root()
        let source = folder.appendingPathComponent("source.json")
        try input(format: "postman", url: endpoint() + "/json").write(to: source)
        let system = try await cli(["run", source.path, "--json"])
        XCTAssertEqual(system.status, 3)
        try input(
            format: "postman",
            url: endpoint().replacingOccurrences(of: "localhost", with: "127.0.0.1") + "/json"
        ).write(to: source)
        let hostname = try await cli([
            "run", source.path, "--ca-cert", try fixture("ca.pem").path, "--json",
        ])
        XCTAssertEqual(hostname.status, 3)
        let insecure = try await cli(["run", source.path, "--insecure", "--json"])
        XCTAssertEqual(insecure.status, 0)
        let summary = try XCTUnwrap(
            JSONSerialization.jsonObject(with: insecure.output) as? [String: Any])
        XCTAssertEqual(summary["tlsPolicy"] as? String, TLSMode.insecure.rawValue)
        let terminal = try await cli(["run", source.path, "--insecure"])
        XCTAssertTrue(String(decoding: terminal.output, as: UTF8.self).contains("TLS: insecure"))
        try input(format: "postman", url: endpoint(true) + "/json").write(to: source)
        let noIdentity = try await cli([
            "run", source.path, "--ca-cert", try fixture("ca.pem").path, "--json",
        ])
        XCTAssertEqual(noIdentity.status, 3)
    }
    func testInvalidTLSInputsAndOutputCollisionsBlockBeforeArtifacts() async throws {
        let folder = try root()
        let source = folder.appendingPathComponent("source.json")
        let report = folder.appendingPathComponent("report.json")
        let input = try input(format: "postman", url: "http://127.0.0.1:1")
        try input.write(to: source)
        let ca = folder.appendingPathComponent("ca.pem")
        let key = folder.appendingPathComponent("client.key")
        let cert = folder.appendingPathComponent("client.pem")
        let p12 = folder.appendingPathComponent("client.p12")
        for (name, destination) in [
            ("ca.pem", ca), ("client.key", key), ("client.pem", cert), ("client.p12", p12),
        ] {
            try Data(contentsOf: fixture(name)).write(to: destination)
        }
        let password = folder.appendingPathComponent("password.txt")
        try Data("private-wrong-password\n".utf8).write(to: password)
        let options = [
            ["--ca-cert", ca.path, "--insecure"], ["--include-system-roots"],
            ["--ssl-client-cert", cert.path], ["--ssl-client-key", key.path],
            ["--ssl-client-origin", "https://private-user:private-password@localhost"],
            ["--ssl-client-p12", p12.path], ["--ssl-passphrase-file", password.path],
            [
                "--ssl-client-p12", p12.path, "--ssl-passphrase-file", password.path,
                "--ssl-client-origin", try endpoint(true),
            ],
            [
                "--ssl-client-cert", cert.path, "--ssl-client-key", key.path, "--ssl-client-origin",
                try endpoint(true) + "/private-path",
            ],
            [
                "--ssl-client-cert", cert.path, "--ssl-client-key", try fixture("server.key").path,
                "--ssl-client-origin", try endpoint(true),
            ],
        ]
        for option in options {
            let result = try await cli(
                ["run", source.path, "--report", report.path, "--json"] + option)
            XCTAssertEqual(result.status, 2, "Invalid TLS option set: \(option.first ?? "missing")")
            XCTAssertTrue(result.output.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: report.path))
            XCTAssertFalse(String(decoding: result.diagnostics, as: UTF8.self).contains("private-"))
        }
        let originals = try [ca, key, cert, p12, password].map { try Data(contentsOf: $0) }
        let inputs = [
            "--ca-cert", ca.path, "--ssl-client-cert", cert.path, "--ssl-client-key", key.path,
            "--ssl-client-origin", try endpoint(true),
        ]
        for destination in [ca, key, cert] {
            for output in ["--report", "--output"] {
                let result = try await cli(
                    ["run", source.path] + inputs + [output, destination.path, "--overwrite"])
                XCTAssertEqual(result.status, 2)
            }
        }
        let p12Options = [
            "--ssl-client-p12", p12.path, "--ssl-passphrase-file", password.path,
            "--ssl-client-origin", try endpoint(true),
        ]
        for destination in [p12, password] {
            let result = try await cli(
                ["run", source.path] + p12Options + ["--report", destination.path, "--overwrite"])
            XCTAssertEqual(result.status, 2)
        }
        for (file, expected) in zip([ca, key, cert, p12, password], originals) {
            XCTAssertEqual(try Data(contentsOf: file), expected)
        }
        XCTAssertEqual(try Data(contentsOf: source), input)
        let wrongCommand = try await cli([
            "request", "GET", "http://127.0.0.1:1", "--ca-cert", ca.path,
        ])
        XCTAssertEqual(wrongCommand.status, 2)
    }
    func testPassphraseFileAcceptsOneEndingWithoutTrimmingPasswordSpaces() async throws {
        let folder = try root()
        let source = folder.appendingPathComponent("source.json")
        let password = folder.appendingPathComponent("password.txt")
        try input(format: "postman", url: endpoint(true) + "/json").write(to: source)
        let args = [
            "run", source.path, "--ssl-client-p12", try fixture("client.p12").path,
            "--ssl-passphrase-file", password.path, "--ssl-client-origin", try endpoint(true),
            "--ca-cert", try fixture("ca.pem").path, "--json",
        ]
        for phrase in ["rill-fixture", "rill-fixture\n", "rill-fixture\r\n"] {
            try Data(phrase.utf8).write(to: password)
            let result = try await cli(args)
            XCTAssertEqual(result.status, 0, String(decoding: result.diagnostics, as: UTF8.self))
        }
        for phrase in ["rill-fixture \n", "rill-fixture\r\r\n", "rill-fixture\n\n"] {
            try Data(phrase.utf8).write(to: password)
            let result = try await cli(args)
            XCTAssertEqual(result.status, 2)
        }
    }
}
