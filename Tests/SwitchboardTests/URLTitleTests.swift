import XCTest
@testable import Switchboard

final class URLTitleTests: XCTestCase {
    func testClipboardRequiresSingleWebAddress() {
        XCTAssertEqual(URLTitleFetcher.clipboardURL(" https://example.com/page\n")?.host, "example.com")
        XCTAssertEqual(URLTitleFetcher.clipboardURL("example.com")?.scheme, "https")
        XCTAssertEqual(URLTitleFetcher.clipboardURL("https://intranet/page")?.host, "intranet")
        XCTAssertNil(URLTitleFetcher.clipboardURL("just some notes"))
        XCTAssertNil(URLTitleFetcher.clipboardURL("notes"))
        XCTAssertNil(URLTitleFetcher.clipboardURL("file:///tmp/private.txt"))
        XCTAssertNil(URLTitleFetcher.clipboardURL("javascript://example.com"))
    }

    func testHTMLTitleDecodesEntitiesAndIgnoresFalseTitles() {
        let html = """
        <!-- <title>Comment</title> -->
        <script>let example = '<title>Script</title>';</script>
        <TITLE data-test="title">  News &amp; Ideas&nbsp; &mdash; &#x1F4DA;
          &#169; &quot;Reading&quot; </TITLE>
        """
        XCTAssertEqual(URLTitleFetcher.htmlTitle(html), "News & Ideas — 📚 © \"Reading\"")
        XCTAssertEqual(URLTitleFetcher.htmlTitle("<title>A &amp;lt; B</title>"), "A &lt; B")
        XCTAssertEqual(URLTitleFetcher.htmlTitle("<title>A&#10;B</title>"), "A B")
        XCTAssertNil(URLTitleFetcher.htmlTitle("<html><body>No title</body></html>"))
        XCTAssertNil(URLTitleFetcher.htmlTitle("<title> &nbsp; </title>"))
    }

    func testFetchReadsTitleAndDeclaredEncoding() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        let title = try await URLTitleFetcher.title(for: URL(string: "https://example.test/ok")!, session: session)
        XCTAssertEqual(title, "Example & Friends")
        let encoded = try await URLTitleFetcher.title(for: URL(string: "https://example.test/encoded")!, session: session)
        XCTAssertEqual(encoded, "Café")
        let noTitle = try await URLTitleFetcher.title(for: URL(string: "https://example.test/empty")!, session: session)
        XCTAssertNil(noTitle)
    }

    func testFetchRejectsHTTPFailuresAndNonHTML() async {
        let session = session()
        defer { session.invalidateAndCancel() }
        for path in ["failure", "image"] {
            do {
                _ = try await URLTitleFetcher.title(for: URL(string: "https://example.test/\(path)")!, session: session)
                XCTFail("Expected rejection of \(path)")
            } catch { }
        }
    }

    func testFetchStopsAtSizeLimit() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        let title = try await URLTitleFetcher.title(for: URL(string: "https://example.test/large")!, session: session)
        XCTAssertNil(title, "A title beyond the response size limit must not be read")
    }

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TitleURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class TitleURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let path = url.lastPathComponent
        let type = path == "image" ? "image/png" : "text/html; charset=windows-1252"
        let response = HTTPURLResponse(url: url, statusCode: path == "failure" ? 404 : 200,
                                       httpVersion: "HTTP/1.1", headerFields: ["Content-Type": type])!
        let html = path == "large" ? String(repeating: " ", count: URLTitleFetcher.maximumBytes) + "<title>Too late</title>" :
            path == "encoded" ? "<meta charset='windows-1252'><title>Café</title>" :
            path == "empty" ? "<html><body>No title</body></html>" : "<title>Example &amp; Friends</title>"
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: html.data(using: .windowsCP1252)!)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
