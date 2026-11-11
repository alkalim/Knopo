import Foundation

/// Tags in Logseq page properties may be bare, bracketed, or prefixed with #.
/// Ranges let renames preserve separators and the spelling of unrelated tags.
public enum PageTagValue {
    public struct Token: Equatable, Sendable {
        public let name: String
        public let range: NSRange
        public let nameRange: NSRange
    }

    private static let regex = try! NSRegularExpression(
        pattern: #"#?\[\[([^\]\r\n]+)\]\]|#([\p{L}\p{N}_-]+)|([^,#\[\]\s]+(?:[ \t]+[^,#\[\]\s]+)*)"#)

    public static func tokens(in value: String) -> [Token] {
        let source = value as NSString
        return regex.matches(in: value, range: NSRange(location: 0, length: source.length)).compactMap { match in
            guard let group = (1...3).first(where: { match.range(at: $0).location != NSNotFound }) else { return nil }
            let range = match.range(at: group)
            let raw = source.substring(with: range)
            let name = raw.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            let leading = raw.prefix(while: { $0.isWhitespace }).utf16.count
            return Token(name: name.lowercased(), range: match.range,
                         nameRange: NSRange(location: range.location + leading, length: name.utf16.count))
        }
    }

    public static func rename(_ old: String, to new: String, in value: String) -> String {
        let result = NSMutableString(string: value)
        for token in tokens(in: value).reversed() where token.name == old.lowercased() {
            let spelling = (value as NSString).substring(with: token.range)
            if spelling.hasPrefix("#"), !spelling.hasPrefix("#[["), new.contains(where: { $0.isWhitespace }) {
                result.replaceCharacters(in: token.range, with: "#[[\(new)]]")
            } else {
                result.replaceCharacters(in: token.nameRange, with: new)
            }
        }
        return result as String
    }
}
