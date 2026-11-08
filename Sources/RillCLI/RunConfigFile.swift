import Foundation
import RillCore

enum FileRunOptions {
    static let values: Set<String> = Set([
        "environment-file", "env-var", "iterations", "delay", "retries", "retry-delay",
        "report", "report-format", "allure", "output", "timeout", "color", "folder",
        "format", "collection", "environment", "seed", "seed-time", "deadline", "comparison-output",
        "iteration-data", "iteration-data-format", "globals", "export-environment",
    ]).union(FileTLSOptions.values)
    static let flags: Set<String> = [
        "json", "quiet", "detail", "continue-on-failure", "fail-fast", "overwrite",
        "allow-insecure",
        "insecure", "include-system-roots", "cookies", "translate-scripts", "github-annotations",
        "dry-run",
    ]
    static let paths: Set<String> = Set([
        "environment-file", "iteration-data", "globals", "report", "allure", "output",
        "export-environment", "comparison-output",
    ]).union(FileTLSOptions.inputNames)
}
private struct RunConfigFile: Decodable {
    enum Option: Decodable {
        case one(String), many([String])
        init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer()
            if let text = try? value.decode(String.self) {
                self = .one(text)
            } else {
                self = .many(try value.decode([String].self))
            }
        }
        var strings: [String] {
            switch self {
            case .one(let text): [text]
            case .many(let rows): rows
            }
        }
    }
    let kind: String
    let schemaVersion: Int
    let options: [String: Option]?
    let flags: [String: Bool]?
}
extension Arguments {
    mutating func applyRunConfig() throws {
        guard let path = value("config") else { return }
        guard command == "run" else {
            throw CLIError.usage("--config is supported only by file runs.")
        }
        do {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            let data = try BoundedFileInput.read(url, limit: 65536)
            try WorkspaceFile.checkJSONBounds(data)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                Set(object.keys).isSubset(of: ["kind", "schemaVersion", "options", "flags"])
            else { throw WorkflowError.invalidConfiguration }
            let config = try JSONDecoder().decode(RunConfigFile.self, from: data)
            guard config.kind == "rill.run-config", config.schemaVersion == 1,
                Set((config.options ?? [:]).keys).isSubset(of: FileRunOptions.values),
                Set((config.flags ?? [:]).keys).isSubset(
                    of: FileRunOptions.flags.subtracting(["dry-run"]))
            else { throw WorkflowError.invalidConfiguration }
            let explicitFlags = flags
            var defaults = Set((config.flags ?? [:]).filter(\.value).map(\.key))
            guard !defaults.isSuperset(of: ["fail-fast", "continue-on-failure"]) else {
                throw WorkflowError.invalidConfiguration
            }
            if explicitFlags.contains("fail-fast") { defaults.remove("continue-on-failure") }
            if explicitFlags.contains("continue-on-failure") { defaults.remove("fail-fast") }
            flags.formUnion(defaults)
            for (key, option) in config.options ?? [:] {
                let rows = option.strings
                guard !rows.isEmpty, rows.count <= 512, key == "env-var" || rows.count == 1 else {
                    throw WorkflowError.invalidConfiguration
                }
                let resolved = rows.map { value in
                    FileRunOptions.paths.contains(key) && !value.hasPrefix("/")
                        ? url.deletingLastPathComponent().appendingPathComponent(value)
                            .standardizedFileURL.path : value
                }
                if key == "env-var" {
                    values[key] = resolved + (values[key] ?? [])
                } else if values[key] == nil {
                    values[key] = resolved
                }
            }
            guard values.values.reduce(0, { $0 + $1.count }) <= 512,
                values.values.flatMap({ $0 }).reduce(0, { $0 + $1.utf8.count }) <= 2 * 1024 * 1024
            else { throw WorkflowError.limit }
        } catch is CancellationError { throw CancellationError() } catch {
            throw CLIError.usage(
                "Invalid run config. Use version 1, supported option strings/arrays and boolean flags within 64 KiB. Paths and values omitted; no requests sent."
            )
        }
    }
}
