import Foundation

enum BookmarkHTML {
    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
    static func decode(_ value: String) -> String {
        let expression = try! NSRegularExpression(pattern: "&(#x[0-9a-fA-F]+|#[0-9]+|amp|quot|apos|lt|gt|nbsp);")
        var result = value
        for match in expression.matches(in: value, range: NSRange(value.startIndex..., in: value)).reversed() {
            guard let tokenRange = Range(match.range(at: 1), in: value), let fullRange = Range(match.range, in: result) else { continue }
            let token = String(value[tokenRange]); let replacement: String?
            if token.hasPrefix("#x"), let code = UInt32(token.dropFirst(2), radix: 16), let scalar = UnicodeScalar(code) { replacement = String(scalar) }
            else if token.hasPrefix("#"), let code = UInt32(token.dropFirst()), let scalar = UnicodeScalar(code) { replacement = String(scalar) }
            else { replacement = ["amp":"&", "quot":"\"", "apos":"'", "lt":"<", "gt":">", "nbsp":" "][token] }
            if let replacement { result.replaceSubrange(fullRange, with: replacement) }
        }
        return result
    }
    static func export(_ data: LibraryData) -> String {
        var lines = ["<!DOCTYPE NETSCAPE-Bookmark-file-1>", "<META HTTP-EQUIV=\"Content-Type\" CONTENT=\"text/html; charset=UTF-8\">", "<TITLE>Switchboard bookmarks</TITLE>", "<DL><p>"]
        func append(_ parent: UUID?, visited: Set<UUID>) {
            for entry in data.entries where entry.kind == .url && entry.collectionID == parent {
                lines.append("<DT><A HREF=\"\(escape(entry.location))\" ADD_DATE=\"\(Int(entry.added.timeIntervalSince1970))\" TAGS=\"\(escape(entry.tags.joined(separator: ",")))\" DATA-SWITCHBOARD-FAVORITE=\"\(entry.favorite)\">\(escape(entry.name))</A>")
                if !entry.notes.isEmpty { lines.append("<DD>\(escape(entry.notes))") }
            }
            for collection in data.collections where collection.parentID == parent && !visited.contains(collection.id) {
                lines.append("<DT><H3>\(escape(collection.name))</H3>\n<DL><p>")
                append(collection.id, visited: visited.union([collection.id])); lines.append("</DL><p>")
            }
        }
        append(nil, visited: []); lines.append("</DL><p>"); return lines.joined(separator: "\n")
    }
    static func parse(_ bytes: Data) throws -> LibraryData {
        guard let html = String(data: bytes, encoding: .utf8) else { throw TransferError(message: "Bookmark HTML must be UTF-8.") }
        let clean = html.replacingOccurrences(of: "(?is)<!--.*?-->", with: "", options: .regularExpression)
        let tokenizer = try NSRegularExpression(pattern: "(?is)<(/?)([a-z][a-z0-9]*)([^>]*)>|([^<]+)")
        let attributes = try NSRegularExpression(pattern: "(?i)([a-z][a-z0-9_-]*)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))")
        var data = LibraryData(); var stack: [UUID?] = []; var pending: UUID?; var title: String?
        var anchor: [String: String]?; var anchorName = ""; var notes = false; var ignored: String?
        func parent() -> UUID? { stack.last ?? nil }
        for token in tokenizer.matches(in: clean, range: NSRange(clean.startIndex..., in: clean)) {
            func text(_ index: Int) -> String { Range(token.range(at: index), in: clean).map { String(clean[$0]) } ?? "" }
            let tag = text(2).lowercased(); let closing = text(1) == "/"
            if let skip = ignored { if closing && tag == skip { ignored = nil }; continue }
            if tag == "script" || tag == "style" { if !closing { ignored = tag }; continue }
            if tag.isEmpty {
                let value = decode(text(4))
                if title != nil { title! += value }
                else if anchor != nil { anchorName += value }
                else if notes, !data.entries.isEmpty { data.entries[data.entries.count - 1].notes += value }
                continue
            }
            if ["dt", "h3", "a", "dl"].contains(tag) { notes = false }
            if tag == "h3" {
                if closing, let name = title {
                    let collection = LibraryCollection(name: name.trimmingCharacters(in: .whitespacesAndNewlines), parentID: parent())
                    data.collections.append(collection); pending = collection.id; title = nil
                } else if !closing { title = "" }
            } else if tag == "dl" {
                if closing { if !stack.isEmpty { stack.removeLast() } }
                else { stack.append(pending ?? parent()); pending = nil }
            } else if tag == "a" {
                if closing, let values = anchor {
                    if let href = values["href"], let url = LibraryLogic.webURL(href), href.lowercased().hasPrefix("http") {
                        var entry = LibraryEntry(name: anchorName.trimmingCharacters(in: .whitespacesAndNewlines), location: url.absoluteString, kind: .url, collectionID: parent())
                        if entry.name.isEmpty { entry.name = url.host ?? url.absoluteString }
                        entry.tags = (values["tags"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        if let seconds = Double(values["add_date"] ?? ""), seconds.isFinite, seconds >= 0 { entry.added = Date(timeIntervalSince1970: seconds) }
                        entry.favorite = values["data-switchboard-favorite"] == "true"
                        data.entries.append(entry)
                    }
                    anchor = nil
                } else if !closing {
                    let raw = text(3); var values: [String: String] = [:]
                    for attribute in attributes.matches(in: raw, range: NSRange(raw.startIndex..., in: raw)) {
                        guard let key = Range(attribute.range(at: 1), in: raw) else { continue }
                        let value = (2...4).compactMap { Range(attribute.range(at: $0), in: raw).map { String(raw[$0]) } }.first ?? ""
                        values[String(raw[key]).lowercased()] = decode(value)
                    }
                    anchor = values; anchorName = ""
                }
            } else if tag == "dd", !closing { notes = true }
            guard data.entries.count <= 10_000, data.collections.count <= 5_000 else { throw TransferError(message: "Too many bookmarks or folders.") }
        }
        for index in data.entries.indices { data.entries[index].notes = data.entries[index].notes.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !data.entries.isEmpty || !data.collections.isEmpty else { throw TransferError(message: "No supported bookmarks found.") }
        return try PortableLibrary(data).library()
    }
}
