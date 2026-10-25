import Foundation

/// Review material only. This type has no execution or enablement API.
public struct ForeignScriptSource: Codable, Equatable, Sendable {
    public let origin: String
    public let stage: String
    public let source: String
    public var enabled: Bool { false }
    public init(origin: String, stage: String, source: String) {
        self.origin = origin
        self.stage = stage
        self.source = source
    }
}
