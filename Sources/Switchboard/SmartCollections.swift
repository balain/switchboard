import Foundation

enum AddedDateRule: String, Codable, CaseIterable, Identifiable {
    case anytime, today, thisWeek, lastSevenDays, lastThirtyDays, range
    var id: String { rawValue }
    var title: String {
        switch self {
        case .anytime: "Any date"
        case .today: "Today"
        case .thisWeek: "This week"
        case .lastSevenDays: "Last 7 days"
        case .lastThirtyDays: "Last 30 days"
        case .range: "Date range"
        }
    }
}

struct TagConstraint: Codable, Equatable {
    var ids: Set<UUID>
    var match: TagMatch
}

struct EntryPredicate: Codable, Equatable {
    var queries: [String] = [""]
    var kind: EntryKind?
    var fileExtension = ""
    var favorite: Bool?
    var collectionID: UUID?
    var tagIDs: Set<UUID> = []
    var tagMatch: TagMatch = .any
    var additionalTags: [TagConstraint] = []
    var added: AddedDateRule = .anytime
    var startDate = Date()
    var endDate = Date()

    func unavailable(in data: LibraryData) -> Bool {
        if let collectionID, !data.collections.contains(where: { $0.id == collectionID }) { return true }
        return !tagIDs.union(additionalTags.flatMap { $0.ids }).isSubset(of: Set(data.tags.map(\.id)))
    }
    func matches(_ entry: LibraryEntry, in data: LibraryData, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard !unavailable(in: data), queries.allSatisfy({ LibraryLogic.matches(entry, query: $0) }) else { return false }
        if let kind, entry.kind != kind { return false }
        let ext = fileExtension.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if !ext.isEmpty, (entry.location as NSString).pathExtension.caseInsensitiveCompare(ext) != .orderedSame { return false }
        if let favorite, entry.favorite != favorite { return false }
        if let collectionID {
            guard let assigned = entry.collectionID,
                  LibraryLogic.descendants(of: collectionID, in: data.collections).contains(assigned) else { return false }
        }
        for group in [TagConstraint(ids: tagIDs, match: tagMatch)] + additionalTags where !group.ids.isEmpty {
            let checks = data.tags.filter { group.ids.contains($0.id) }.map { tag in
                entry.tags.contains { $0.caseInsensitiveCompare(tag.name) == .orderedSame }
            }
            if group.match == .all ? !checks.allSatisfy({ $0 }) : !checks.contains(true) { return false }
        }
        let today = calendar.startOfDay(for: now)
        let lower: Date
        let upper: Date
        switch added {
        case .anytime: return true
        case .today:
            lower = today; upper = calendar.date(byAdding: .day, value: 1, to: today) ?? now
        case .thisWeek:
            guard let interval = calendar.dateInterval(of: .weekOfYear, for: now) else { return false }
            lower = interval.start; upper = interval.end
        case .lastSevenDays, .lastThirtyDays:
            lower = calendar.date(byAdding: .day, value: added == .lastSevenDays ? -6 : -29, to: today) ?? today
            upper = calendar.date(byAdding: .day, value: 1, to: today) ?? now
        case .range:
            lower = calendar.startOfDay(for: startDate)
            upper = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: endDate)) ?? endDate
        }
        return entry.added >= lower && entry.added < upper
    }
}

struct SavedFilter: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var criteria = EntryPredicate()
    var icon: String?
    var palette: Palette?
    var sort: EntrySort?
    var scope: String { "smart:" + id.uuidString }
    static func id(in scope: String) -> UUID? {
        guard scope.hasPrefix("smart:") else { return nil }
        return UUID(uuidString: String(scope.dropFirst(6)))
    }
}
