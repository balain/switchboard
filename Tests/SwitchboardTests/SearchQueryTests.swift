import XCTest
@testable import Switchboard

final class SearchQueryTests: XCTestCase {
    private var entry: LibraryEntry {
        var entry = LibraryEntry(name: "Annual Report", location: "/Projects/report.pdf", kind: .file)
        entry.tags = ["To Read", "Finance"]; entry.notes = "Review with team"; entry.favorite = true
        return entry
    }
    func testFieldsCombineWithPhraseAndNegation() {
        XCTAssertTrue(SearchQuery("kind:file tag:\"To Read\" ext:PDF favorite:true Report -tag:Archive").matchesMetadata(entry))
        XCTAssertFalse(SearchQuery("kind:file tag:Archive Report").matchesMetadata(entry))
        XCTAssertFalse(SearchQuery("-favorite:true").matchesMetadata(entry))
        XCTAssertTrue(SearchQuery("name:annual location:projects notes:team").matchesMetadata(entry))
    }
    func testPlainPhrasesAndUnknownPrefixesStayLiteral() {
        XCTAssertEqual(SearchQuery("annual report").text, "annual report")
        XCTAssertTrue(SearchQuery("annual report").matchesMetadata(entry))
        XCTAssertEqual(SearchQuery("https://example.com other:value").text, "https://example.com other:value")
        XCTAssertTrue(SearchQuery("\"Annual Report\"").matchesMetadata(entry))
    }
    func testInvalidConditionsFailClosed() {
        for query in ["kind:bad", "tag:", "favorite:yes", "tag:\"unfinished"] {
            XCTAssertNotNil(SearchQuery(query).error)
            XCTAssertFalse(SearchQuery(query).matchesMetadata(entry))
        }
    }
    func testContentPhraseSeparatesFromMandatoryFields() {
        let query = SearchQuery("kind:file ext:pdf quarterly results")
        XCTAssertEqual(query.text, "quarterly results")
        XCTAssertTrue(query.matchesFields(entry))
        XCTAssertFalse(query.matchesMetadata(entry))
        var url = entry; url.kind = .url
        XCTAssertFalse(query.matchesFields(url))
        XCTAssertTrue(SearchQuery("tag:finance").text.isEmpty)
        XCTAssertTrue(SearchQuery("tag:finance").matchesMetadata(entry))
    }
    func testOperatorsCombineWithCollectionAndTagScope() {
        let collection = LibraryCollection(name: "Work")
        var included = entry; included.collectionID = collection.id
        var outside = entry; outside.id = UUID()
        let matches = LibraryLogic.scopedEntries([included, outside], collections: [collection],
            scope: collection.id.uuidString, hierarchical: true, query: "ext:pdf favorite:true", sort: .name,
            tags: ["Finance"], tagMatch: .all)
        XCTAssertEqual(matches.map(\.id), [included.id])
        XCTAssertTrue(LibraryLogic.scopedEntries([included], collections: [collection],
            scope: collection.id.uuidString, hierarchical: true, query: "-tag:Finance", sort: .name,
            tags: ["Finance"], tagMatch: .all).isEmpty)
    }

}
