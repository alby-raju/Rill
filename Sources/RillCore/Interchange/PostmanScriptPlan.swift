import Foundation

public struct ScriptTranslationSummary: Encodable, Sendable {
    public let subsetVersion = 1
    public let strategy = "bounded-native-translation"
    public let foreignRuntime = false
    public let sourceBlocks: Int
    public let translatedOperations: Int
}

struct PostmanScriptPlan: Sendable {
    struct RequestScripts: Sendable {
        let pre: [Int]
        let post: [Int]
        let name: String
        let originalID: String?
    }
    let programs: [ScriptProgram]
    let sourceLocations: [String]
    let requests: [RequestScripts]
    let writes: Set<String>
    let targetIndices: [Data: Int]

    static func prepare(_ selection: PostmanFolderSelection) throws -> Self {
        var programs: [ScriptProgram] = []
        var sourceLocations: [String] = []
        var programCosts: [Int] = []
        var totalCost = 0
        var requests: [RequestScripts] = []
        var writes: Set<String> = []
        var remainingBytes = 4 * 1024 * 1024
        var remainingReferences = 100_000
        var remainingNodes = 100_000
        func failure(_ code: String, _ path: String, _ point: ScriptSyntaxFailure? = nil)
            -> PostmanScriptPlanError
        {
            .init(
                code: code, location: path, line: point?.line ?? 1,
                byteColumn: point?.byteColumn ?? 1)
        }
        func walk(
            _ row: [String: Any], path: String, depth: Int, inheritedPre: [Int],
            inheritedPost: [Int]
        ) throws {
            try Task.checkCancellation()
            remainingNodes -= 1
            guard depth <= 33, remainingNodes >= 0 else { throw failure("script.limit", path) }
            var pre = inheritedPre
            var post = inheritedPost
            if let events = row["event"] {
                guard let events = events as? [[String: Any]] else {
                    throw failure("script.invalidEvents", path + "/event")
                }
                for (index, event) in events.enumerated() {
                    let location = path + "/event/\(index)"
                    guard let script = event["script"] as? [String: Any],
                        let lines = script["exec"] as? [String],
                        script["src"] == nil
                    else { throw failure("script.invalidOrExternalSource", location) }
                    if lines.allSatisfy({
                        $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    }) {
                        continue
                    }
                    guard event["disabled"] as? Bool != true, script["disabled"] as? Bool != true
                    else { throw failure("script.declaredDisabled", location) }
                    guard
                        script["type"] == nil
                            || ["text/javascript", "application/javascript", "javascript"].contains(
                                script["type"] as? String ?? "")
                    else { throw failure("script.unsupportedLanguage", location) }
                    guard
                        let phase = (event["listen"] as? String).flatMap(
                            ScriptCompatibilityInventory.Phase.init(rawValue:)), phase != .other
                    else { throw failure("script.unsupportedPhase", location) }
                    let size = lines.reduce(0) { $0 + $1.utf8.count } + max(0, lines.count - 1)
                    guard programs.count < 1000, lines.count <= 10_000, size <= 1024 * 1024,
                        size <= remainingBytes
                    else { throw failure("script.limit", location) }
                    remainingBytes -= size
                    let program: ScriptProgram
                    do {
                        var parser = try ScriptParser(lines.joined(separator: "\n"), phase: phase)
                        program = try parser.parse()
                    } catch let error as ScriptSyntaxFailure {
                        throw failure(error.code, location, error)
                    }
                    if phase == .prerequest {
                        pre.append(programs.count)
                    } else {
                        post.append(programs.count)
                    }
                    totalCost += program.estimatedCost
                    guard totalCost <= 100_000 else { throw failure("script.limit", location) }
                    programs.append(program)
                    sourceLocations.append(location)
                    programCosts.append(program.estimatedCost)
                    writes.formUnion(program.writes)
                    guard writes.count <= 1024 else { throw failure("script.limit", location) }
                }
            }
            if let children = row["item"] as? [[String: Any]] {
                for (index, child) in children.enumerated() {
                    let original =
                        selection.originalIndices.indices.contains(depth)
                        ? selection.originalIndices[depth] : index
                    try walk(
                        child, path: path + "/item/\(original)", depth: depth + 1,
                        inheritedPre: pre, inheritedPost: post)
                }
            } else if row["request"] != nil {
                guard row["disabled"] as? Bool != true,
                    (row["request"] as? [String: Any])?["event"] == nil
                else { throw failure("script.unsupportedRequestSettings", path) }
                remainingReferences -= pre.count + post.count
                guard requests.count < 10_000, remainingReferences >= 0 else {
                    throw failure("script.limit", path)
                }
                guard (pre + post).reduce(0, { $0 + programCosts[$1] }) <= 1024 else {
                    throw failure("script.limit", path)
                }
                requests.append(
                    RequestScripts(
                        pre: pre, post: post, name: row["name"] as? String ?? "Imported request",
                        originalID: row["id"] as? String))
            }
        }
        try walk(selection.root, path: "", depth: 0, inheritedPre: [], inheritedPost: [])
        var names: [Data: [Int]] = [:]
        var identifiers: [Data: [Int]] = [:]
        for (index, request) in requests.enumerated() {
            guard request.name.utf8.count <= 4096, (request.originalID?.utf8.count ?? 0) <= 4096
            else { throw failure("script.limit", "/item") }
            names[Data(request.name.utf8), default: []].append(index)
            if let id = request.originalID { identifiers[Data(id.utf8), default: []].append(index) }
        }
        var targets: [Data: Int] = [:]
        for program in programs {
            for target in program.branches {
                let key = Data(target.utf8)
                let matches = identifiers[key] ?? names[key] ?? []
                guard matches.count == 1 else { throw failure("script.invalidBranch", "/item") }
                targets[key] = matches[0]
            }
        }
        return Self(
            programs: programs, sourceLocations: sourceLocations, requests: requests,
            writes: writes, targetIndices: targets
        )
    }
}

public struct PostmanScriptPlanError: Error, Sendable {
    public let code: String
    public let location: String
    public let line: Int
    public let byteColumn: Int
}
