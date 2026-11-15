import Foundation

public enum XMLTextFormatter {
    public static func pretty(_ text: String) throws -> String {
        guard text.utf8.count <= 512 * 1024 else { throw WorkspaceError.tooLarge }
        guard !text.utf8.contains(0), text.range(of: "<!DOCTYPE", options: .literal) == nil else {
            throw FormatError.unsupportedDocument
        }
        let document = try XMLDocument(
            xmlString: text,
            options: [.nodeLoadExternalEntitiesNever, .nodePreserveCDATA, .nodePreserveWhitespace])
        guard let root = document.rootElement(), document.dtd == nil,
            document.characterEncoding?.lowercased() == "utf-8"
        else { throw FormatError.unsupportedDocument }

        // Indenting mixed content or an explicit whitespace-preserving subtree can change its text.
        var preserveSource = false
        var pending = [(root, 1)]
        while let (element, depth) = pending.popLast() {
            guard depth <= 64 else { throw WorkspaceError.tooLarge }
            let children = element.children ?? []
            let elements = children.compactMap { $0 as? XMLElement }
            if element.attribute(forName: "xml:space")?.stringValue == "preserve"
                || (!elements.isEmpty
                    && children.contains { node in
                        node.kind == .text && node.stringValue?.isEmpty == false
                    })
            {
                preserveSource = true
            }
            pending.append(contentsOf: elements.map { ($0, depth + 1) })
        }
        let output =
            preserveSource
            ? text : document.xmlString(options: [.nodePrettyPrint, .nodeCompactEmptyElement])
        guard output.utf8.count <= 8 * 1024 * 1024 else { throw WorkspaceError.tooLarge }
        return output.hasSuffix("\n") ? String(output.dropLast()) : output
    }

    private enum FormatError: Error { case unsupportedDocument }
}
