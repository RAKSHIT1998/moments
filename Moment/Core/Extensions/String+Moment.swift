import Foundation

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var isBlank: Bool { trimmed.isEmpty }

    /// Collapses runs of whitespace/newlines to a single space.
    var collapsedWhitespace: String {
        components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    func truncated(_ limit: Int) -> String {
        count <= limit ? self : String(prefix(limit)).trimmed + "…"
    }

    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }

    /// Case-insensitive whole-word containment.
    func containsWord(_ word: String) -> Bool {
        range(of: "\\b\(NSRegularExpression.escapedPattern(for: word))\\b", options: [.regularExpression, .caseInsensitive]) != nil
    }

    func matches(_ pattern: String, caseSensitive: Bool = false) -> Bool {
        range(of: pattern, options: caseSensitive ? [.regularExpression] : [.regularExpression, .caseInsensitive]) != nil
    }

    /// Removes emoji and variation selectors. Scalar-property based, so it never trips regex engines.
    var strippingEmoji: String {
        String(String.UnicodeScalarView(unicodeScalars.filter { scalar in
            if scalar.value == 0xFE0F || scalar.value == 0x200D { return false }
            if scalar.properties.isEmojiPresentation { return false }
            if scalar.properties.isEmoji && scalar.value > 0x238C { return false }
            return true
        }))
    }

    /// First capture group of the first match, if any. Case-insensitive unless `caseSensitive`
    /// (use that for patterns that rely on capitalization, like `[A-Z][a-z]+`).
    func firstMatch(_ pattern: String, group: Int = 1, caseSensitive: Bool = false) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: caseSensitive ? [] : [.caseInsensitive]) else { return nil }
        let range = NSRange(startIndex..., in: self)
        guard let m = regex.firstMatch(in: self, range: range), m.numberOfRanges > group,
              let r = Range(m.range(at: group), in: self) else { return nil }
        return String(self[r])
    }

    func allMatches(_ pattern: String, group: Int = 0, caseSensitive: Bool = false) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: caseSensitive ? [] : [.caseInsensitive]) else { return [] }
        let range = NSRange(startIndex..., in: self)
        return regex.matches(in: self, range: range).compactMap { m in
            guard m.numberOfRanges > group, let r = Range(m.range(at: group), in: self) else { return nil }
            return String(self[r])
        }
    }
}
