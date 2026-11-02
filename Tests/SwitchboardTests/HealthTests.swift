import XCTest
@testable import Switchboard

private actor HealthResults {
    var values: [HealthFinding] = []
    var active = 0
    var maximum = 0
    var webCalls = 0
    func append(_ value: HealthFinding) { values.append(value) }
    func enter() { active += 1; maximum = max(maximum, active) }
    func leave() { active -= 1 }
    func web() { webCalls += 1 }
}

private final class HealthURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var methods: [String] = []
    nonisolated(unsafe) static var failure: URLError?
    private static let lock = NSLock()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.methods.append(request.httpMethod ?? ""); let failure = Self.failure; Self.lock.unlock()
        if let failure { client?.urlProtocol(self, didFailWithError: failure); return }
        let status = request.httpMethod == "HEAD" ? 405 : 206
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if request.httpMethod == "GET" { client?.urlProtocol(self, didLoad: Data(repeating: 65, count: 4096)) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

final class HealthTests: XCTestCase {
    func testLocalReferencesBookmarkAndUnavailableVolume() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("sample".utf8).write(to: url)
        var entry = LibraryEntry(name: "Sample", location: url.path, kind: .file)
        XCTAssertEqual(LocalHealthProbe.check(entry).status, .healthy)
        entry.location = url.path + ".missing"; XCTAssertEqual(LocalHealthProbe.check(entry).status, .missing)
        entry.bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        XCTAssertEqual(LocalHealthProbe.check(entry).status, .healthy)
        XCTAssertTrue(entry.location.hasSuffix(".missing"))
        let unavailable = LibraryEntry(name: "Offline", location: "/Volumes/\(UUID().uuidString)/file.txt", kind: .file)
        XCTAssertEqual(LocalHealthProbe.check(unavailable).status, .unavailableVolume)
    }
    func testLocalOnlyScanDoesNotContactWebAndFindsConservativeDuplicates() async {
        let a = LibraryEntry(name: "A", location: "https://EXAMPLE.com:443/a?x=1", kind: .url)
        let b = LibraryEntry(name: "B", location: "https://example.com/a?x=1", kind: .url)
        let c = LibraryEntry(name: "C", location: "https://example.com/a?x=2", kind: .url)
        let results = HealthResults()
        let scanner = LibraryHealthScanner(web: { _ in await results.web(); return HealthCheck(status: .healthy, detail: "") })
        await scanner.scan([a, b, c], includeWeb: false) { await results.append($0) }
        let values = await results.values
        let webCalls = await results.webCalls; XCTAssertEqual(webCalls, 0)
        XCTAssertEqual(values.first { $0.id == a.id }?.duplicates, [b.id])
        XCTAssertEqual(values.first { $0.id == c.id }?.duplicates, [])
    }
    func testBoundedConcurrencyAndCancellation() async throws {
        let entries = (0..<40).map { LibraryEntry(name: "\($0)", location: "/tmp/\($0)", kind: .file) }
        let results = HealthResults()
        let scanner = LibraryHealthScanner(local: { _ in
            await results.enter(); try? await Task.sleep(for: .milliseconds(50)); await results.leave()
            return HealthCheck(status: .healthy, detail: "")
        }, concurrency: 3)
        let task = Task { await scanner.scan(entries, includeWeb: false) { await results.append($0) } }
        try await Task.sleep(for: .milliseconds(10)); task.cancel(); await task.value
        let maximum = await results.maximum; let values = await results.values
        XCTAssertLessThanOrEqual(maximum, 3); XCTAssertTrue(values.isEmpty)
    }
    func testHTTPStatusesAndBoundedFallback() async throws {
        XCTAssertEqual(WebHealthProbe.classify(404).status, .missing)
        XCTAssertEqual(WebHealthProbe.classify(410).status, .missing)
        XCTAssertEqual(WebHealthProbe.classify(403).status, .authenticationRequired)
        XCTAssertEqual(WebHealthProbe.classify(429).status, .rateLimited)
        XCTAssertEqual(WebHealthProbe.classify(503).status, .temporaryFailure)
        XCTAssertEqual(WebHealthProbe.classify(302).status, .unknown)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [HealthURLProtocol.self]
        HealthURLProtocol.methods = []; HealthURLProtocol.failure = nil
        let url = URL(string: "https://health.invalid/sample")!
        let result = try await WebHealthProbe.check(url, configuration: config)
        XCTAssertEqual(result.status, .healthy); XCTAssertEqual(HealthURLProtocol.methods, ["HEAD", "GET"])
        XCTAssertEqual(WebHealthProbe.request(url, head: false).value(forHTTPHeaderField: "Range"), "bytes=0-4095")
        HealthURLProtocol.failure = URLError(.serverCertificateUntrusted)
        let failure = try await WebHealthProbe.check(url, configuration: config)
        XCTAssertEqual(failure.status, .temporaryFailure)
        HealthURLProtocol.failure = nil
    }
    func testWebRequestsOmitEmbeddedCredentials() throws {
        let url = try XCTUnwrap(URL(string: "https://user:secret@example.com/path?q=kept"))
        let request = WebHealthProbe.request(url, head: true)
        XCTAssertEqual(request.url?.absoluteString, "https://example.com/path?q=kept")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }
    func testRedirectsStopAfterFiveWithoutMakingRequests() {
        let delegate = HealthSessionDelegate()
        let session = URLSession(configuration: .ephemeral); defer { session.invalidateAndCancel() }
        let url = URL(string: "https://health.invalid")!; let task = session.dataTask(with: url)
        let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: nil)!
        for index in 1...6 {
            var allowed = false
            delegate.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: URLRequest(url: url)) { allowed = $0 != nil }
            XCTAssertEqual(allowed, index <= 5)
        }
    }
    @MainActor func testRepairPreservesMetadataSupportsUndoAndRejectsStaleSnapshots() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LibraryStore(storageURL: dir.appendingPathComponent("library.json"))
        let id = try XCTUnwrap(store.addURL(name: "Original", location: "example.com", collectionID: nil))
        let original = try XCTUnwrap(store.data.entries.first { $0.id == id })
        var replacement = original; replacement.location = "https://replacement.example.com"
        XCTAssertEqual(store.applyEntryChanges(expected: [original], updated: [replacement], title: "Repair Reference"), 1)
        store.undoManager.undo(); XCTAssertEqual(store.data.entries.first, original)
        var newer = original; newer.notes = "Changed after scan"; store.update(newer)
        XCTAssertEqual(store.applyEntryChanges(expected: [original], updated: [replacement], title: "Repair Reference"), 0)
        XCTAssertEqual(store.data.entries.first?.notes, newer.notes)
    }
    @MainActor func testInFlightFindingsAreDiscardedAfterEntryChanges() async throws {
        let original = LibraryEntry(name: "Original", location: "/tmp/original", kind: .file)
        var changed = original; changed.location = "/tmp/changed"
        let model = HealthScanModel()
        let scanner = LibraryHealthScanner(local: { _ in
            try? await Task.sleep(for: .milliseconds(30)); return HealthCheck(status: .healthy, detail: "")
        })
        model.scan([original], includeWeb: false, scanner: scanner)
        model.discardStale(in: [changed])
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(model.findings.isEmpty); XCTAssertFalse(model.running)
        model.cancel()
    }

}
