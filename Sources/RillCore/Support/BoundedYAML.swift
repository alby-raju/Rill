import CYaml
import Foundation
import Yams

public enum YAMLImportError: LocalizedError {
    case invalid, unsupported
    public var errorDescription: String? {
        switch self {
        case .invalid:
            "Invalid or non-JSON-compatible YAML. Source text is omitted from diagnostics."
        case .unsupported:
            "YAML exceeds the supported limits or uses anchors, aliases, custom tags or multiple documents."
        }
    }
}
enum BoundedYAML {
    static func object(_ data: Data, allowAliases: Bool = false, exactNumbers: Bool = false) throws
        -> [String: Any]
    {
        guard data.count <= 8 * 1024 * 1024, let text = String(data: data, encoding: .utf8) else {
            throw YAMLImportError.unsupported
        }
        try YAMLPreflight.validate(data, allowAliases: allowAliases, exactNumbers: exactNumbers)
        do {
            let resolver = try Resolver.basic
                .appending(.bool, "^(?:true|True|TRUE|false|False|FALSE)$")
                .appending(.int, #"^-?(?:0|[1-9][0-9]*)$"#)
                .appending(.float, #"^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?$"#)
                .appending(.null, "^(?:null|Null|NULL|~|)$")
            guard let result = try Yams.load(yaml: text, resolver) as? [String: Any],
                JSONSerialization.isValidJSONObject(result)
            else { throw YAMLImportError.invalid }
            return result
        } catch { throw YAMLImportError.invalid }
    }
}
