import Foundation

/// Field conditions narrow the scope; the remaining phrase searches metadata or content.
struct SearchQuery {
    struct Condition {
        let field: String
        let value: String
        let excluded: Bool
        func matches(_ entry: LibraryEntry) -> Bool {
            let result: Bool
            switch field {
            case "kind": result = entry.kind.rawValue == value.lowercased()
            case "tag": result = entry.tags.contains { $0.caseInsensitiveCompare(value) == .orderedSame }
            case "ext": result = entry.url?.pathExtension.caseInsensitiveCompare(value.trimmingCharacters(in: CharacterSet(charactersIn: "."))) == .orderedSame
            case "favorite": result = entry.favorite == (value.lowercased() == "true")
            case "name": result = entry.name.localizedCaseInsensitiveContains(value)
            case "location": result = entry.location.localizedCaseInsensitiveContains(value)
            case "notes": result = entry.notes.localizedCaseInsensitiveContains(value)
            default: result = false
            }
            return excluded ? !result : result
        }
    }
    let text: String
    let conditions: [Condition]
    let error: String?
    init(_ source: String) {
        var tokens: [String] = [], token = "", quoted = false
        for character in source {
            if character == "\"" { quoted.toggle() }
            else if character.isWhitespace && !quoted {
                if !token.isEmpty { tokens.append(token); token = "" }
            } else { token.append(character) }
        }
        if !token.isEmpty { tokens.append(token) }
        var conditions: [Condition] = [], words: [String] = []
        var error: String? = quoted ? "Close the quoted phrase to finish your search." : nil
        let fields: Set<String> = ["kind", "tag", "ext", "favorite", "name", "location", "notes"]
        for token in tokens {
            let excluded = token.hasPrefix("-")
            let candidate = excluded ? String(token.dropFirst()) : token
            let parts = candidate.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, fields.contains(parts[0].lowercased()) else { words.append(token); continue }
            let field = parts[0].lowercased(), value = String(parts[1])
            if value.isEmpty { error = "Enter a value after \(field):." }
            else if field == "kind", EntryKind(rawValue: value.lowercased()) == nil { error = "Use kind:file, kind:folder, or kind:url." }
            else if field == "favorite", !["true", "false"].contains(value.lowercased()) { error = "Use favorite:true or favorite:false." }
            conditions.append(Condition(field: field, value: value, excluded: excluded))
        }
        self.text = words.joined(separator: " "); self.conditions = conditions; self.error = error
    }
    func matchesFields(_ entry: LibraryEntry) -> Bool {
        error == nil && conditions.allSatisfy { $0.matches(entry) }
    }
    func matchesMetadata(_ entry: LibraryEntry) -> Bool {
        matchesFields(entry) && (text.isEmpty || LibraryLogic.searchableText(entry).contains { $0.localizedCaseInsensitiveContains(text) })
    }
}
