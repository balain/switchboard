import Foundation

final class HealthSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var redirects = 0
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        lock.lock(); redirects += 1; let allowed = redirects <= 5; lock.unlock()
        guard allowed, let url = request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { completionHandler(nil); return }
        var clean = request
        clean.url = WebHealthProbe.withoutCredentials(url)
        clean.setValue(nil, forHTTPHeaderField: "Authorization")
        clean.setValue(nil, forHTTPHeaderField: "Cookie")
        completionHandler(clean)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
}

enum WebHealthProbe {
    static func classify(_ status: Int) -> HealthCheck {
        let state: HealthStatus
        switch status {
        case 200..<300: state = .healthy
        case 404, 410: state = .missing
        case 401, 403: state = .authenticationRequired
        case 429: state = .rateLimited
        case 500..<600: state = .temporaryFailure
        default: state = .unknown
        }
        return HealthCheck(status: state, detail: "HTTP \(status). A transient or protected response does not establish a permanently broken link.")
    }
    static func withoutCredentials(_ url: URL) -> URL {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        parts.user = nil; parts.password = nil
        return parts.url ?? url
    }
    static func request(_ url: URL, head: Bool) -> URLRequest {
        var request = URLRequest(url: withoutCredentials(url), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.httpMethod = head ? "HEAD" : "GET"
        if !head { request.setValue("bytes=0-4095", forHTTPHeaderField: "Range") }
        request.setValue("Switchboard link check", forHTTPHeaderField: "User-Agent")
        return request
    }
    static func check(_ url: URL, configuration: URLSessionConfiguration? = nil) async throws -> HealthCheck {
        try Task.checkCancellation()
        let config = configuration ?? URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil
        config.httpShouldSetCookies = false; config.timeoutIntervalForResource = 20
        let delegate = HealthSessionDelegate()
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
        let (_, response) = try await session.bytes(for: request(url, head: true))
        guard let http = response as? HTTPURLResponse else { return HealthCheck(status: .unknown, detail: "Not an HTTP response.") }
        if [405, 501].contains(http.statusCode) {
            let (bytes, fallback) = try await session.bytes(for: request(url, head: false))
            var count = 0
            for try await _ in bytes { try Task.checkCancellation(); count += 1; if count >= 8_192 { break } }
            return classify((fallback as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return classify(http.statusCode)
        } catch {
            try Task.checkCancellation()
            let code = (error as? URLError)?.code
            if code == .userAuthenticationRequired || code == .userCancelledAuthentication {
                return HealthCheck(status: .authenticationRequired, detail: "The server requires authentication.")
            }
            return HealthCheck(status: .temporaryFailure, detail: error.localizedDescription)
        }
    }
}
