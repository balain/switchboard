import XCTest
@testable import Switchboard

final class FilePreviewTests: XCTestCase {
    func testTextPreviewIsBoundedAndPreservesLines() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("notes.md")
        let lines = (1...30).map { "Line \($0)" }
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(FilePreviewLoader.textExcerpt(at: url), lines.prefix(14).joined(separator: "\n"))
        try String(repeating: "x", count: 100_000).write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(FilePreviewLoader.textExcerpt(at: url)?.utf8.count, FilePreviewLoader.maximumTextBytes)
    }

    func testEmptyUnicodeAndBinaryFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("notes.txt")
        try Data().write(to: url)
        XCTAssertEqual(FilePreviewLoader.textExcerpt(at: url), "This file is empty.")
        try "Café 📚".write(to: url, atomically: true, encoding: .utf16)
        XCTAssertEqual(FilePreviewLoader.textExcerpt(at: url), "Café 📚")
        try Data([0, 1, 2, 3]).write(to: url)
        XCTAssertNil(FilePreviewLoader.textExcerpt(at: url))
        XCTAssertNil(FilePreviewLoader.textExcerpt(at: directory))
        XCTAssertNil(FilePreviewLoader.textExcerpt(at: directory.appendingPathComponent("missing.txt")))
    }

    func testOnlyFilesHaveContentPreviewsAndBookmarksResolve() throws {
        XCTAssertNil(FilePreviewLoader.fileURL(for: LibraryEntry(name: "Web", location: "https://example.com", kind: .url)))
        XCTAssertNil(FilePreviewLoader.fileURL(for: LibraryEntry(name: "Folder", location: "/tmp", kind: .folder)))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        defer { try? FileManager.default.removeItem(at: url) }
        try "Preview".write(to: url, atomically: true, encoding: .utf8)
        let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        let entry = LibraryEntry(name: "Notes", location: "/missing.txt", kind: .file, bookmark: bookmark)
        XCTAssertEqual(FilePreviewLoader.fileURL(for: entry)?.standardizedFileURL, url.standardizedFileURL)
    }
}
