import Foundation

enum RuleTrigger: String, Codable, CaseIterable, Identifiable {
    case additionsAndManual, manualOnly, additionsOnly
    var id: String { rawValue }
    var title: String { switch self { case .additionsAndManual: "New additions and manual"; case .manualOnly: "Manual only"; case .additionsOnly: "New additions only" } }
    func includes(_ event: RuleEvent) -> Bool { event == .manual ? self != .additionsOnly : self != .manualOnly }
}
enum RuleEvent { case newEntries, importedEntries, manual }

enum OrganizationAction: Codable, Equatable {
    case addTag(UUID), removeTag(UUID), collection(UUID?), favorite(Bool)
    func unavailable(in data: LibraryData) -> Bool {
        switch self {
        case .addTag(let id), .removeTag(let id): !data.tags.contains { $0.id == id }
        case .collection(let id): id != nil && !data.collections.contains { $0.id == id }
        case .favorite: false
        }
    }
    func apply(to entry: inout LibraryEntry, data: LibraryData) {
        switch self {
        case .addTag(let id):
            if let tag = data.tags.first(where: { $0.id == id }), !entry.tags.contains(where: { $0.caseInsensitiveCompare(tag.name) == .orderedSame }) { entry.tags.append(tag.name) }
        case .removeTag(let id):
            if let tag = data.tags.first(where: { $0.id == id }) { entry.tags.removeAll { $0.caseInsensitiveCompare(tag.name) == .orderedSame } }
        case .collection(let id): entry.collectionID = id
        case .favorite(let value): entry.favorite = value
        }
    }
    var assignment: (String, String)? {
        switch self {
        case .collection(let id): ("collection", id?.uuidString ?? "none")
        case .favorite(let value): ("favorite", String(value))
        case .addTag(let id): ("tag \(id.uuidString)", "add")
        case .removeTag(let id): ("tag \(id.uuidString)", "remove")
        }
    }
}

struct OrganizationRule: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var enabled = false
    var trigger: RuleTrigger = .additionsAndManual
    var criteria = EntryPredicate()
    var nameContains = ""
    var locationContains = ""
    var host = ""
    var folder = ""
    var actions: [OrganizationAction] = [.favorite(true)]
    var stopProcessing = false
    func unavailable(in data: LibraryData) -> Bool { criteria.unavailable(in: data) || actions.contains { $0.unavailable(in: data) } }
    func validation(in data: LibraryData) -> String? {
        if unavailable(in: data) { return "A referenced tag or collection is unavailable. Repair it before enabling this rule." }
        if actions.isEmpty { return "Add at least one action." }
        if !folder.isEmpty && !folder.hasPrefix("/") { return "Folder must be an absolute path." }
        if !host.isEmpty, URLComponents(string: "https://" + host)?.host?.lowercased() != host.lowercased() || host.contains("/") {
            return "Enter an exact hostname without a scheme, port, or path."
        }
        return nil
    }
    func matches(_ entry: LibraryEntry, in data: LibraryData, now: Date = Date()) -> Bool {
        guard validation(in: data) == nil, criteria.matches(entry, in: data, now: now),
              (nameContains.isEmpty || entry.name.localizedCaseInsensitiveContains(nameContains)), (locationContains.isEmpty || entry.location.localizedCaseInsensitiveContains(locationContains)) else { return false }
        if !host.isEmpty { guard entry.kind == .url, entry.url?.host?.caseInsensitiveCompare(host) == .orderedSame else { return false } }
        if !folder.isEmpty {
            guard entry.kind != .url else { return false }
            let base = URL(fileURLWithPath: folder).standardizedFileURL.pathComponents
            let path = URL(fileURLWithPath: entry.location).standardizedFileURL.pathComponents
            guard path.starts(with: base) else { return false }
        }
        return true
    }
}

struct RulePreview {
    let rules: [OrganizationRule]
    let tags: [LibraryTag]
    let collections: [LibraryCollection]
    let expected: [LibraryEntry]
    let updated: [LibraryEntry]
    let reasons: [UUID: [String]]
    let conflicts: [String]
    let day: Date
    var changed: Int { zip(expected, updated).filter { $0 != $1 }.count }
}

enum RuleEngine {
    static func preview(entries: [LibraryEntry], data: LibraryData, event: RuleEvent, now: Date = Date()) -> RulePreview {
        var updated: [LibraryEntry] = []; var reasons: [UUID: [String]] = [:]; var conflicts: [String] = []
        for original in entries {
            var entry = original; var assignments: [String: (String, String)] = [:]
            for rule in data.rules where rule.enabled && rule.trigger.includes(event) {
                guard rule.matches(entry, in: data, now: now) else { continue }
                reasons[entry.id, default: []].append(rule.name)
                for action in rule.actions {
                    if let (field, value) = action.assignment {
                        if let previous = assignments[field], previous.0 != value {
                            let display: String
                            switch action {
                            case .addTag(let id), .removeTag(let id): display = "tag ‘\(data.tags.first { $0.id == id }?.name ?? "unavailable")’"
                            default: display = field
                            }
                            conflicts.append("\(entry.name): ‘\(rule.name)’ overrides \(display) set by ‘\(previous.1)’.")
                        }
                        assignments[field] = (value, rule.name)
                    }
                    action.apply(to: &entry, data: data)
                }
                if rule.stopProcessing { break }
            }
            updated.append(entry)
        }
        return RulePreview(rules: data.rules, tags: data.tags, collections: data.collections, expected: entries,
                           updated: updated, reasons: reasons, conflicts: conflicts, day: Calendar.current.startOfDay(for: now))
    }
}
