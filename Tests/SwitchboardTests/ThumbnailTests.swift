import XCTest
@testable import Switchboard

final class ThumbnailTests: XCTestCase {
    func testLegacyViewConfigurationUsesCompactThumbnailDefault() throws {
        let json = Data(#"{"fields":["kind","location"],"palette":"forest","fontName":"Menlo","fontSize":14}"#.utf8)
        let configuration = try JSONDecoder().decode(ViewConfiguration.self, from: json)
        XCTAssertEqual(configuration.resolvedThumbnailSize, 80)
        XCTAssertEqual(configuration.fontName, "Menlo")
        XCTAssertEqual(configuration.fields, [.kind, .location])
    }

    func testThumbnailSizeStaysWithinSupportedRange() {
        XCTAssertEqual(ViewConfiguration(thumbnailSize: 1).resolvedThumbnailSize, 48)
        XCTAssertEqual(ViewConfiguration(thumbnailSize: 1000).resolvedThumbnailSize, 160)
        XCTAssertEqual(ViewConfiguration(thumbnailSize: .nan).resolvedThumbnailSize, 80)
        XCTAssertEqual(ViewConfiguration(thumbnailSize: .infinity).resolvedThumbnailSize, 80)
    }

    @MainActor func testThumbnailViewAndSizePersistIndependentlyOfOtherFormats() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.json")
        let store = LibraryStore(storageURL: url)
        store.data.view = .thumbnails
        store.configuration = ViewConfiguration(palette: .forest, thumbnailSize: 120)
        let restored = LibraryStore(storageURL: url)
        XCTAssertNil(restored.error)
        XCTAssertEqual(restored.data.view, .thumbnails)
        XCTAssertEqual(restored.configuration.resolvedThumbnailSize, 120)
        XCTAssertEqual(restored.configuration.palette, .forest)
        restored.data.view = .mediumCards
        XCTAssertEqual(restored.configuration, ViewConfiguration())
        restored.data.view = .thumbnails
        XCTAssertEqual(restored.configuration.resolvedThumbnailSize, 120)
    }
}
