import Foundation

enum RequestTerminalColor {
    private static let jsonTokens = try! NSRegularExpression(
        pattern:
            #"("(?:[^"\\]++|\\.)*+")(?=[ \t]*:)|"(?:[^"\\]++|\\.)*+"|-?[0-9]+(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?|true|false|null"#
    )
    private static let xmlTokens = try! NSRegularExpression(
        pattern:
            #"<!--[\s\S]*?-->|<!\[CDATA\[[\s\S]*?\]\]>|<\?[\s\S]*?\?>|<(?:[^>"']++|"[^"]*+"|'[^']*+')*+>"#
    )

    static func status(_ status: Int, enabled: Bool) -> String {
        let code =
            switch status {
            case 200...299: 32
            case 300...399: 33
            case 400...599: 31
            default: 36
            }
        return paint("HTTP \(status)", code: code, enabled: enabled)
    }

    static func paint(_ text: String, code: Int, enabled: Bool = true) -> String {
        enabled ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text
    }

    static func body(_ text: String, json: Bool) -> String {
        guard text.utf8.count <= 1024 * 1024 else { return escape(text, multiline: true) }
        let tokens = json ? jsonTokens : xmlTokens
        var rendered = ""
        var previous = text.startIndex
        tokens.enumerateMatches(in: text, range: NSRange(text.startIndex..., in: text)) {
            match, _, _ in
            guard let match, let range = Range(match.range, in: text) else { return }
            rendered += escape(text[previous..<range.lowerBound], multiline: true)
            let token = text[range]
            let code: Int
            if json {
                code =
                    match.range(at: 1).location != NSNotFound ? 36 : token.first == "\"" ? 32 : 33
            } else {
                code = token.hasPrefix("<!") || token.hasPrefix("<?") ? 33 : 36
            }
            rendered += paint(escape(token, multiline: true), code: code)
            previous = range.upperBound
        }
        rendered += escape(text[previous...], multiline: true)
        return rendered
    }

    static func escape(_ text: some StringProtocol, multiline: Bool = false) -> String {
        var rendered = ""
        for scalar in text.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control where multiline && (scalar == "\n" || scalar == "\t"):
                rendered.unicodeScalars.append(scalar)
            case .control, .format, .lineSeparator, .paragraphSeparator:
                rendered += "\\u{\(String(scalar.value, radix: 16, uppercase: true))}"
            default:
                rendered.unicodeScalars.append(scalar)
            }
        }
        return rendered
    }
}
