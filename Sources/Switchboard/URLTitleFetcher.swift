import Foundation
import CoreFoundation

enum URLTitleFetcher {
    enum FetchError: Error { case invalidURL, invalidResponse, notHTML }
    static let maximumBytes = 1_048_576

    /// Clipboard text must be a single web address, rather than arbitrary prose.
    static func clipboardURL(_ text: String) -> URL? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.contains(where: { $0.isWhitespace }),
              let url = LibraryLogic.webURL(text), let host = url.host,
              host.contains(".") || host == "localhost" || host.contains(":") || text.contains("://") else { return nil }
        return url
    }

    static func title(for url: URL, session suppliedSession: URLSession? = nil) async throws -> String? {
        try Task.checkCancellation()
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
            throw FetchError.invalidURL
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        let session = suppliedSession ?? URLSession(configuration: configuration)
        defer { if suppliedSession == nil { session.invalidateAndCancel() } }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.setValue("text/html, application/xhtml+xml", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw FetchError.invalidResponse
        }
        if let mime = response.mimeType?.lowercased(), !["text/html", "application/xhtml+xml"].contains(mime) {
            throw FetchError.notHTML
        }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            data.append(byte)
            if data.count == maximumBytes { break }
        }
        try Task.checkCancellation()
        return htmlTitle(decode(data, charset: response.textEncodingName))
    }

    private static func decode(_ data: Data, charset: String?) -> String {
        // Honor the response encoding, then a page's early charset declaration.
        let prefix = String(decoding: data.prefix(4096), as: UTF8.self)
        let declared = firstMatch(#"<meta\b[^>]*charset\s*=\s*["']?\s*([a-zA-Z0-9_-]+)"#, in: prefix)
        if let charset = charset ?? declared {
            let encoding = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
            if encoding != kCFStringEncodingInvalidId,
               let text = String(data: data, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(encoding))) {
                return text
            }
        }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) ?? prefix
    }

    static func htmlTitle(_ html: String) -> String? {
        // Read plain title text without rendering HTML, executing scripts, or loading resources.
        let stripped = html.replacingOccurrences(of: #"<!--[\s\S]*?(?:-->|$)|<(script|style)\b[^>]*>[\s\S]*?</\1\s*>"#,
                                                 with: "", options: [.regularExpression, .caseInsensitive])
        guard let raw = firstMatch(#"<title\b[^>]*>([\s\S]*?)</title\s*>"#, in: stripped) else { return nil }
        let title = decodeEntities(raw).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return title.isEmpty ? nil : String(title.prefix(500))
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private static func decodeEntities(_ text: String) -> String {
        let named = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
                     "ndash": "–", "mdash": "—", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”",
                     "hellip": "…", "copy": "©", "reg": "®", "trade": "™", "bull": "•", "middot": "·",
                     "laquo": "«", "raquo": "»", "eacute": "é", "Eacute": "É", "aacute": "á",
                     "ouml": "ö", "uuml": "ü", "euro": "€", "pound": "£"]
        guard let regex = try? NSRegularExpression(pattern: #"&(#(?:[xX][0-9a-fA-F]+|[0-9]+)|[a-zA-Z]+);"#) else { return text }
        var result = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: result), let keyRange = Range(match.range(at: 1), in: text) else { continue }
            let key = String(text[keyRange])
            var replacement = named[key]
            if key.hasPrefix("#") {
                let hex = key.lowercased().hasPrefix("#x")
                if let code = UInt32(key.dropFirst(hex ? 2 : 1), radix: hex ? 16 : 10),
                   let scalar = UnicodeScalar(code), code != 0 {
                    replacement = String(scalar)
                }
            }
            if let replacement { result.replaceSubrange(range, with: replacement) }
        }
        return result
    }
}
