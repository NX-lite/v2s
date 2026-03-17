import Foundation

/// Applies a user-defined glossary table to a translated string.
/// Source terms are matched case-insensitively and replaced with the target term.
struct GlossaryService: Sendable {
    func apply(to text: String, glossary: [String: String]) -> String {
        guard !glossary.isEmpty else { return text }
        var result = text
        for (source, target) in glossary where !source.isEmpty {
            result = result.replacingOccurrences(
                of: source,
                with: target,
                options: [.caseInsensitive]
            )
        }
        return result
    }
}
