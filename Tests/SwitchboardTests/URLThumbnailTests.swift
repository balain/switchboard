import XCTest
import ImageIO
@testable import Switchboard

private actor ThumbnailProbe {
    var calls = 0
    var active = 0
    var peak = 0
    func fetch(_ url: URL) async -> URLThumbnailResult? {
        calls += 1; active += 1; peak = max(peak, active)
        try? await Task.sleep(for: .milliseconds(50))
        active -= 1
        return nil
    }
    func counts() -> (Int, Int) { (calls, peak) }
}

final class URLThumbnailTests: XCTestCase {
    func testPreviewPriorityRelativeURLsAndUnsafeSchemes() {
        let html = """
        <script><meta property='og:image' content='https://bad.example/image'></script>
        <link rel="shortcut icon" href="/icon.png">
        <meta content="../preview.png?a=1&amp;b=2" property="og:image">
        <meta name="twitter:image" content="file:///tmp/private.png">
        """
        let urls = URLThumbnailLoader.candidates(html: html, base: URL(string: "https://example.com/path/page")!)
        XCTAssertEqual(urls.map(\.absoluteString), ["https://example.com/preview.png?a=1&b=2", "https://example.com/icon.png", "https://example.com/favicon.ico"])
        XCTAssertFalse(URLThumbnailLoader.valid(URL(string: "https://user:password@example.com")!))
        XCTAssertEqual(URLThumbnailLoader.key(URL(string: "https://example.com/#one")!), URLThumbnailLoader.key(URL(string: "https://example.com/#two")!))
    }
    func testNetworkLimitsAndIconFallbackWithMockResponses() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ThumbnailURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let result = await URLThumbnailLoader.fetch(URL(string: "https://example.test/page")!, session: session)
        XCTAssertNotNil(result, "A corrupt preview should fall back to the site icon")
        for path in ["oversized", "failure"] {
            do {
                _ = try await URLThumbnailLoader.read(URL(string: "https://example.test/\(path)")!, session: session, limit: 64)
                XCTFail("Expected bounded fetch to reject \(path)")
            } catch { }
        }
    }
    @MainActor func testDefaultOffConcurrencyCoalescingAndFailureCache() async throws {
        let suite = UUID().uuidString, directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let probe = ThumbnailProbe()
        let store = URLThumbnailStore(defaults: defaults, directory: directory, fetch: { await probe.fetch($0) })
        let url = URL(string: "https://example.test/one")!
        let disabled = await store.image(for: url)
        XCTAssertNil(disabled)
        var counts = await probe.counts(); XCTAssertEqual(counts.0, 0)
        store.workers = 2; store.enabled = true
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<12 {
                group.addTask { _ = await store.image(for: URL(string: "https://example.test/\(index % 6)")!) }
            }
        }
        counts = await probe.counts(); XCTAssertEqual(counts.0, 6); XCTAssertEqual(counts.1, 2)
        _ = await store.image(for: URL(string: "https://example.test/0")!)
        counts = await probe.counts(); XCTAssertEqual(counts.0, 6)
        XCTAssertTrue(defaults.bool(forKey: "urlThumbnailsEnabled")); XCTAssertEqual(defaults.integer(forKey: "urlThumbnailWorkers"), 2)
    }
    @MainActor func testDisableStopsQueuedLoads() async throws {
        let suite = UUID().uuidString, directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let probe = ThumbnailProbe()
        let store = URLThumbnailStore(defaults: defaults, directory: directory, fetch: { await probe.fetch($0) })
        store.enabled = true; store.workers = 1
        let tasks = (0..<8).map { index in Task { await store.image(for: URL(string: "https://example.test/\(index)")!) } }
        try await Task.sleep(for: .milliseconds(10))
        store.enabled = false
        for task in tasks { let result = await task.value; XCTAssertNil(result) }
        let counts = await probe.counts(); XCTAssertLessThanOrEqual(counts.0, 1)
    }
    func testDiskCacheExpirationBudgetAndClearGeneration() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pixel = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a1ZkAAAAASUVORK5CYII=")!
        let image = try XCTUnwrap(URLThumbnailLoader.decode(pixel))
        XCTAssertEqual(image.image.width, 1)
        let cache = URLThumbnailCache(directory: directory, maximumBytes: image.png.count + 1)
        await cache.write(image.png, key: "first", generation: 0)
        let cached = await cache.read("first"); XCTAssertNotNil(cached)
        let freshStore = URLThumbnailCache(directory: directory)
        let persisted = await freshStore.read("first"); XCTAssertNotNil(persisted)
        let expired = await cache.read("first", now: Date().addingTimeInterval(8 * 86400)); XCTAssertNil(expired)
        await cache.write(image.png, key: "second", generation: 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 1)
        try await cache.clear()
        await cache.write(image.png, key: "stale", generation: 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }
}

private final class ThumbnailURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let data: Data, mime: String
        switch url.path {
        case "/page":
            data = Data("<meta property='og:image' content='/broken.png'><link rel='icon' href='/icon.png'>".utf8); mime = "text/html"
        case "/icon.png":
            data = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a1ZkAAAAASUVORK5CYII=")!; mime = "image/png"
        case "/oversized": data = Data(repeating: 65, count: 128); mime = "text/html"
        default: data = Data("invalid image".utf8); mime = "image/png"
        }
        let response = HTTPURLResponse(url: url, statusCode: url.path == "/failure" ? 503 : 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": mime])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
