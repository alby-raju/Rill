import Foundation

public enum PostmanAttachmentError: Error {
    case tooMany
    case missing(String)
    case unknownSlot
    case unavailable(String)
}

public struct PostmanAttachmentSlot: Encodable, Sendable {
    public let slot: String
    public let bound: Bool
}

/// Bind only explicit files to structural slots. Exported paths are never consulted.
enum PostmanAttachments {
    private struct Target {
        let slot: String
        let requestIndex: Int
        let partIndex: Int?
    }

    static let maximumSlots = 256

    static func bind(
        _ requests: inout [RequestDraft], locations: [String], files: [String: URL],
        planningOnly: Bool
    ) throws -> [PostmanAttachmentSlot] {
        var targets: [Target] = []
        for (index, request) in requests.enumerated() {
            try Task.checkCancellation()
            let source = locations[index]
            if request.bodyMode == .binary {
                targets.append(
                    Target(slot: source + "/attachments/0", requestIndex: index, partIndex: nil))
            }
            if request.bodyMode == .multipart {
                let parts = request.multipartParts ?? []
                guard !parts.contains(where: { $0.enabled && $0.name.isEmpty }) else {
                    throw UploadError.invalidPart
                }
                var ordinal = 0
                for (partIndex, part) in parts.enumerated()
                where part.enabled && part.kind == .file {
                    targets.append(
                        Target(
                            slot: source + "/attachments/\(ordinal)", requestIndex: index,
                            partIndex: partIndex))
                    ordinal += 1
                    guard targets.count <= maximumSlots else {
                        throw PostmanAttachmentError.tooMany
                    }
                }
            }
            guard targets.count <= maximumSlots else { throw PostmanAttachmentError.tooMany }
        }
        guard Set(files.keys).isSubset(of: Set(targets.map(\.slot))) else {
            throw PostmanAttachmentError.unknownSlot
        }
        let slots = targets.map {
            PostmanAttachmentSlot(slot: $0.slot, bound: files[$0.slot] != nil)
        }
        guard !planningOnly else { return slots }
        if let missing = slots.first(where: { !$0.bound }) {
            throw PostmanAttachmentError.missing(missing.slot)
        }
        for target in targets {
            try Task.checkCancellation()
            guard let file = files[target.slot],
                let reference = try? UploadFileReference.capture(file),
                reference.path == file.standardizedFileURL.path
            else { throw PostmanAttachmentError.unavailable(target.slot) }
            if let partIndex = target.partIndex {
                requests[target.requestIndex].multipartParts?[partIndex].file = reference
            } else {
                requests[target.requestIndex].binaryFile = reference
            }
        }
        return slots
    }
}
