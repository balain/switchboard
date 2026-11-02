import XCTest
import AppKit
import CoreText
@testable import Switchboard

final class ContentSearchTests: XCTestCase {
    private func fixture() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true); return directory
    }
    func testTextUnicodeEncodingAndLimits() throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("notes.txt")
        try "Café — searchable needle".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertTrue(try ContentExtractor().text(at: file).contains("needle"))
        try Data([0, 1, 2]).write(to: file); XCTAssertThrowsError(try ContentExtractor().text(at: file))
        try Data(repeating: 65, count: 65).write(to: file)
        XCTAssertThrowsError(try ContentExtractor(maximumTextBytes: 64).text(at: file))
        var utf16 = Data([0xFF, 0xFE]); utf16.append("Unicode Ω".data(using: .utf16LittleEndian)!)
        try utf16.write(to: file); XCTAssertTrue(try ContentExtractor().text(at: file).contains("Ω"))
    }
    @MainActor func testSearchablePDFAndPageLimits() throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("sample.pdf")
        var box = CGRect(x: 0, y: 0, width: 300, height: 300)
        let context = try XCTUnwrap(CGContext(file as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil); context.textPosition = CGPoint(x: 20, y: 200)
        let text = NSAttributedString(string: "A searchable PDF needle", attributes: [.font: NSFont.systemFont(ofSize: 14)])
        CTLineDraw(CTLineCreateWithAttributedString(text), context)
        context.endPDFPage(); context.closePDF()
        XCTAssertTrue(try ContentExtractor().text(at: file).contains("needle"))
        XCTAssertThrowsError(try ContentExtractor(maximumPages: 0).text(at: file))
    }
    func testCacheInvalidatesChangedFilesEvictsAndClearsRemovedEntries() async throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("notes.txt")
        try "Old needle".write(to: file, atomically: true, encoding: .utf8)
        let entry = LibraryEntry(name: "No metadata match", location: file.path, kind: .file)
        let cache = dir.appendingPathComponent("cache")
        let service = ContentSearchService(directory: cache, maximumCacheBytes: 1100)
        let first = await service.match(entry, query: "needle"); XCTAssertEqual(first.state, .matched)
        try "Changed content without that phrase".write(to: file, atomically: true, encoding: .utf8)
        let changed = await service.match(entry, query: "needle"); XCTAssertEqual(changed.state, .noMatch)
        for index in 0..<4 {
            let url = dir.appendingPathComponent("\(index).txt"); try String(repeating: "text", count: 150).write(to: url, atomically: true, encoding: .utf8)
            _ = await service.match(LibraryEntry(name: "\(index)", location: url.path, kind: .file), query: "text")
        }
        let files = try FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: [.fileSizeKey])
        let bytes = try files.reduce(0) { $0 + (try $1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
        XCTAssertLessThanOrEqual(bytes, 1100)
        try await service.retain([])
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: cache.path).isEmpty)
        try await service.clear(); XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
    }
    func testUnavailableUnsupportedAndNonFileResultsAreExplicit() async throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let service = ContentSearchService(directory: dir.appendingPathComponent("cache"))
        let missing = await service.match(LibraryEntry(name: "Missing", location: dir.appendingPathComponent("missing.txt").path, kind: .file), query: "word")
        XCTAssertEqual(missing.state, .unavailable)
        let unsupported = dir.appendingPathComponent("data.bin"); try Data([1, 2, 3]).write(to: unsupported)
        let skipped = await service.match(LibraryEntry(name: "Binary", location: unsupported.path, kind: .file), query: "word")
        XCTAssertEqual(skipped.state, .skipped)
        let web = await service.match(LibraryEntry(name: "Web", location: "https://example.com", kind: .url), query: "word")
        XCTAssertEqual(web.state, .skipped)
    }
    @MainActor func testRapidQueriesAndClearDoNotPublishStaleMatches() async throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("notes.txt"); try "new phrase".write(to: file, atomically: true, encoding: .utf8)
        let entry = LibraryEntry(name: "Fixture", location: file.path, kind: .file)
        let model = ContentSearchModel(service: ContentSearchService(directory: dir.appendingPathComponent("cache")))
        let old = ContentSearchRequest(entries: [entry], libraryIDs: [entry.id], query: "old", mode: .contents)
        let new = ContentSearchRequest(entries: [entry], libraryIDs: [entry.id], query: "new", mode: .contents)
        let first = Task { await model.run(old) }
        try await Task.sleep(for: .milliseconds(10)); first.cancel()
        await model.run(new); await first.value
        XCTAssertEqual(model.request, new); XCTAssertEqual(model.matches[entry.id]?.state, .matched)
        let pending = Task { await model.run(old) }
        try await Task.sleep(for: .milliseconds(10)); await model.clearCache(); await pending.value
        XCTAssertNil(model.request); XCTAssertTrue(model.matches.isEmpty)
    }
}
