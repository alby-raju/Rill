import Foundation
import XCTest

@testable import RillCore

@MainActor final class DiscoveryTests: XCTestCase {
    private func cli(_ arguments: [String]) async throws -> ProcessRunResult {
        guard let path = ProcessInfo.processInfo.environment["RILL_TEST_CLI_PATH"] else {
            throw XCTSkip("CLI fixture required")
        }
        return try await BoundedProcess.run(
            executable: URL(fileURLWithPath: path), arguments: arguments)
    }
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testDoctorOnlyReadsExplicitWorkspaceAndOmitsPathsAndContents() async throws {
        let root = try root()
        let workspace = root.appendingPathComponent("private-path.json")
        let plain = try await cli(["doctor", "--json"])
        XCTAssertEqual(plain.status, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.path))
        var model = Workspace()
        var request = RequestDraft()
        request.name = "private-content"
        model.requests = [request]
        let bytes = try JSONEncoder().encode(model)
        try bytes.write(to: workspace)
        let valid = try await cli(["doctor", "--workspace", workspace.path, "--json"])
        XCTAssertEqual(valid.status, 0)
        XCTAssertEqual(try Data(contentsOf: workspace), bytes)
        try Data("private-invalid-content".utf8).write(to: workspace)
        let invalid = try await cli(["doctor", "--workspace", workspace.path, "--json"])
        XCTAssertEqual(invalid.status, 2)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: invalid.output) as? [String: Any])
        XCTAssertEqual(object["passed"] as? Bool, false)
        for result in [plain, valid, invalid] {
            let text = String(decoding: result.output + result.diagnostics, as: UTF8.self)
            XCTAssertFalse(text.contains("private-"))
            XCTAssertFalse(text.contains(root.path))
        }
    }

    func testCompletionsParseAndBashCompletesCommandsAndPathsWithSpaces() async throws {
        let root = try root()
        for shell in ["bash", "zsh", "fish"] {
            let result = try await cli(["completion", shell])
            XCTAssertEqual(result.status, 0)
            let file = root.appendingPathComponent(shell)
            try result.output.write(to: file)
            if shell != "fish" {
                let parsed = try await BoundedProcess.run(
                    executable: URL(fileURLWithPath: "/bin/" + shell), arguments: ["-n", file.path])
                XCTAssertEqual(
                    parsed.status, 0, String(decoding: parsed.diagnostics, as: UTF8.self))
            }
        }
        let spaced = root.appendingPathComponent("input with spaces.json")
        try Data().write(to: spaced)
        let script = """
            source "$1"
            COMP_WORDS=(rill ru); COMP_CWORD=1; _rill_complete
            [[ " ${COMPREPLY[*]} " == *" run "* ]] || exit 10
            COMP_WORDS=(rill run "$2/input "); COMP_CWORD=2; _rill_complete
            [[ "${COMPREPLY[0]}" == "$2/input with spaces.json" ]] || exit 11
            """
        let completed = try await BoundedProcess.run(
            executable: URL(fileURLWithPath: "/bin/bash"),
            arguments: [
                "-c", script, "rill-completion-test", root.appendingPathComponent("bash").path,
                root.path,
            ])
        XCTAssertEqual(completed.status, 0)
        let invalid = try await cli(["completion", "unknown"])
        XCTAssertEqual(invalid.status, 2)
    }

    func testCommandHelpDoesNotRequireRunInputs() async throws {
        for arguments in [["run", "--help"], ["help", "run"], ["doctor", "--help"]] {
            let result = try await cli(arguments)
            XCTAssertEqual(result.status, 0)
            XCTAssertFalse(result.output.isEmpty)
        }
        let unknown = try await cli(["help", "unknown"])
        XCTAssertEqual(unknown.status, 2)
    }
}
