import Foundation

public enum WorkspaceGit {
    private static func run(_ arguments: [String], directory: URL, timeout: Double = 10) async throws -> ProcessRunResult {
        // Operates only on the explicitly selected checkout. No hooks, automatic signing,
        // remote fetch/push or credential helpers execute as a side effect of these commands.
        let environment = ["PATH": "/usr/bin:/bin", "HOME": FileManager.default.homeDirectoryForCurrentUser.path, "GIT_TERMINAL_PROMPT": "0", "GIT_CONFIG_NOSYSTEM": "1", "GIT_NO_LAZY_FETCH": "1"]
        let result = try await BoundedProcess.run(executable: URL(fileURLWithPath: "/usr/bin/git"), arguments: ["-c", "core.hooksPath=/dev/null", "-c", "commit.gpgSign=false", "-c", "core.fsmonitor=false", "-c", "gc.auto=0"] + arguments, directory: directory, timeout: timeout, environment: environment)
        guard result.status == 0 else { throw WorkspaceError.unavailable }; return result
    }
    private static func root(_ directory: URL) throws -> URL {
        guard directory.isFileURL, !directory.path.contains("\0"), !directory.path.contains("\n"), directory.path.utf8.count <= 4096 else { throw WorkspaceError.invalidStructure }
        let result = directory.resolvingSymlinksInPath()
        let runtime = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("Rill").path
        guard runtime.map({ result.path != $0 && !result.path.hasPrefix($0 + "/") }) ?? true else { throw WorkspaceError.invalidStructure }
        return result
    }
    public static func initialize(_ directory: URL) async throws {
        let directory = try root(directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard !FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path) else { throw WorkspaceError.conflict }
        _ = try await run(["init", "--initial-branch=main"], directory: directory)
    }
    public static func status(_ directory: URL) async throws -> String {
        let directory = try root(directory)
        let top = try await run(["rev-parse", "--show-toplevel"], directory: directory)
        let reported = URL(fileURLWithPath: String(decoding: top.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)).resolvingSymlinksInPath()
        guard reported.path == directory.path else { throw WorkspaceError.invalidStructure }
        return String(decoding: try await run(["status", "--short", "--untracked-files=normal"], directory: directory).output, as: UTF8.self)
    }
    public static func export(_ workspace: Workspace, to directory: URL) throws {
        let directory = try root(directory); var portable = workspace
        portable.history = []; portable.storageRevision = nil
        for index in portable.requests.indices { portable.requests[index].credential = "" }
        // Runtime files never enter this explicit portable checkout. Entered request/header/body/
        // environment content remains as entered: review it before an explicit commit.
        try WorkspaceFile.save(portable, to: directory.appendingPathComponent("workspace.json"))
        let ignore = directory.appendingPathComponent(".gitignore")
        if !FileManager.default.fileExists(atPath: ignore.path) { try WorkspaceFile.createNew(Data(".DS_Store\neditor-session.json\nexchange-history.json\n*.rillbackup\n*.token\n".utf8), at: ignore) }
    }
    public static func commit(_ directory: URL, message: String) async throws -> String {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, message.utf8.count <= 4096, !message.contains("\0") else { throw WorkspaceError.invalidStructure }
        let directory = try root(directory); _ = try await status(directory)
        let staged = try await run(["diff", "--cached", "--name-only", "-z"], directory: directory)
        let paths = staged.output.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        guard paths.allSatisfy({ ["workspace.json", ".gitignore"].contains($0) }) else { throw WorkspaceError.conflict }
        _ = try await run(["add", "--", "workspace.json", ".gitignore"], directory: directory)
        _ = try await run(["commit", "--no-verify", "-m", message, "--", "workspace.json", ".gitignore"], directory: directory)
        return String(decoding: try await run(["rev-parse", "HEAD"], directory: directory).output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
