import Foundation
import Combine
import ImageIO
import CryptoKit
import UniformTypeIdentifiers

struct URLThumbnailResult: Sendable {
    let image: CGImage
    let png: Data
}

enum URLThumbnailLoader {
    static func valid(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.host != nil && url.user == nil && url.password == nil
    }
    static func key(_ url: URL) -> String {
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: true)
        parts?.fragment = nil
        return SHA256.hash(data: Data((parts?.string ?? url.absoluteString).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func decode(_ data: Data) -> URLThumbnailResult? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 320,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return URLThumbnailResult(image: image, png: output as Data)
    }
    static func candidates(html: String, base: URL) -> [URL] {
        let stripped = html.replacingOccurrences(of: #"<!--[\s\S]*?(?:-->|$)|<(script|style)\b[^>]*>[\s\S]*?</\1\s*>"#, with: "", options: [.regularExpression, .caseInsensitive])
        guard let tags = try? NSRegularExpression(pattern: #"<(meta|link)\b[^>]*>"#, options: .caseInsensitive),
              let attributes = try? NSRegularExpression(pattern: #"([\w:-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#) else { return [] }
        var previews: [String] = [], icons: [String] = []
        for match in tags.matches(in: stripped, range: NSRange(stripped.startIndex..., in: stripped)) {
            let tag = (stripped as NSString).substring(with: match.range)
            var values: [String: String] = [:]
            for attribute in attributes.matches(in: tag, range: NSRange(tag.startIndex..., in: tag)) {
                let key = (tag as NSString).substring(with: attribute.range(at: 1)).lowercased()
                for index in 2...4 where attribute.range(at: index).location != NSNotFound {
                    values[key] = (tag as NSString).substring(with: attribute.range(at: index)); break
                }
            }
            let property = (values["property"] ?? values["name"] ?? "").lowercased()
            if ["og:image", "og:image:url", "twitter:image", "twitter:image:src"].contains(property), let value = values["content"] { previews.append(value) }
            let rel = (values["rel"] ?? "").lowercased().split(whereSeparator: \.isWhitespace)
            if rel.contains("icon") || rel.contains("apple-touch-icon"), let value = values["href"] { icons.append(value) }
        }
        let fallback = URL(string: "/favicon.ico", relativeTo: base)?.absoluteString ?? ""
        var seen: Set<String> = []
        return (Array(previews.prefix(3)) + Array(icons.prefix(2)) + [fallback]).compactMap { raw in
            let value = raw.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&#38;", with: "&")
            guard let url = URL(string: value, relativeTo: base)?.absoluteURL, valid(url), seen.insert(url.absoluteString).inserted else { return nil }
            return url
        }
    }
    static func read(_ url: URL, session: URLSession, limit: Int) async throws -> (Data, HTTPURLResponse) {
        guard valid(url) else { throw URLError(.badURL) }
        let (bytes, response) = try await session.bytes(for: URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10))
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
              let final = response.url, valid(final), response.expectedContentLength <= limit else { throw URLError(.badServerResponse) }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < limit else { throw URLError(.dataLengthExceedsMaximum) }
            data.append(byte)
        }
        return (data, response)
    }
    static func fetch(_ url: URL) async -> URLThumbnailResult? { await fetch(url, session: nil) }
    static func fetch(_ url: URL, session suppliedSession: URLSession?) async -> URLThumbnailResult? {
        guard valid(url), !Task.isCancelled else { return nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil; configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 10; configuration.timeoutIntervalForResource = 15
        let session = suppliedSession ?? URLSession(configuration: configuration)
        defer { if suppliedSession == nil { session.invalidateAndCancel() } }
        var candidates = [URL(string: "/favicon.ico", relativeTo: url)!.absoluteURL]
        if let (data, response) = try? await read(url, session: session, limit: 1_048_576) {
            if response.mimeType?.hasPrefix("image/") == true { return decode(data) }
            if response.mimeType == nil || ["text/html", "application/xhtml+xml"].contains(response.mimeType ?? "") {
                candidates = self.candidates(html: String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self), base: response.url ?? url)
            }
        }
        for candidate in candidates {
            guard !Task.isCancelled else { return nil }
            if let (data, response) = try? await read(candidate, session: session, limit: 5_242_880),
               response.mimeType?.hasPrefix("image/") == true, let result = decode(data) { return result }
        }
        return nil
    }
}

actor URLThumbnailCache {
    let directory: URL
    let maximumBytes: Int
    var generation = 0
    init(directory: URL, maximumBytes: Int = 100 * 1_024 * 1_024) { self.directory = directory; self.maximumBytes = maximumBytes }
    func read(_ key: String, now: Date = Date()) -> URLThumbnailResult? {
        let file = directory.appendingPathComponent(key + ".png")
        guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let date = values.contentModificationDate, now.timeIntervalSince(date) < 7 * 86400,
              (values.fileSize ?? Int.max) <= 1_048_576, let data = try? Data(contentsOf: file) else { return nil }
        return URLThumbnailLoader.decode(data)
    }
    func write(_ data: Data, key: String, generation: Int) {
        guard generation == self.generation, data.count <= maximumBytes else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent(key + ".png"), options: .atomic)
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]).filter { $0.pathExtension == "png" }
            let records = files.map { ($0, try? $0.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])) }
                .sorted { ($0.1?.contentModificationDate ?? .distantPast) < ($1.1?.contentModificationDate ?? .distantPast) }
            var total = records.reduce(0) { $0 + ($1.1?.fileSize ?? 0) }
            for (file, values) in records where total > maximumBytes {
                try FileManager.default.removeItem(at: file); total -= values?.fileSize ?? 0
            }
        } catch { /* Cache failures must not prevent display. */ }
    }
    func clear() throws {
        generation += 1
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }
}

@MainActor
final class URLThumbnailStore: ObservableObject {
    static let shared = URLThumbnailStore()
    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: "urlThumbnailsEnabled"); if !enabled { cancelAll() }; revision += 1; pump() } }
    @Published var workers: Int { didSet { defaults.set(min(12, max(1, workers)), forKey: "urlThumbnailWorkers"); pump() } }
    @Published private(set) var revision = 0
    @Published private(set) var message: String?
    private let defaults: UserDefaults
    private let cache: URLThumbnailCache
    private let fetch: @Sendable (URL) async -> URLThumbnailResult?
    private var pending: [String] = []
    private var urls: [String: URL] = [:]
    private var waiters: [String: [UUID: CheckedContinuation<CGImage?, Never>]] = [:]
    private var active: [String: Task<Void, Never>] = [:]
    private var memory: [String: (CGImage?, Date)] = [:]
    private var clearing = false
    init(defaults: UserDefaults = .standard, directory: URL? = nil,
         fetch: @escaping @Sendable (URL) async -> URLThumbnailResult? = URLThumbnailLoader.fetch) {
        self.defaults = defaults; self.fetch = fetch
        enabled = defaults.bool(forKey: "urlThumbnailsEnabled")
        workers = min(12, max(1, defaults.object(forKey: "urlThumbnailWorkers") as? Int ?? 4))
        cache = URLThumbnailCache(directory: directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Switchboard/URLThumbnails"))
    }
    func image(for url: URL) async -> CGImage? {
        guard enabled, !clearing, URLThumbnailLoader.valid(url), !Task.isCancelled else { return nil }
        let key = URLThumbnailLoader.key(url)
        if let cached = memory[key], cached.1 > Date() { return cached.0 }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: nil); return }
                waiters[key, default: [:]][id] = continuation
                urls[key] = url
                if active[key] == nil && !pending.contains(key) { pending.append(key) }
                pump()
            }
        } onCancel: { Task { @MainActor in self.cancel(key: key, id: id) } }
    }
    private func cancel(key: String, id: UUID) {
        waiters[key]?.removeValue(forKey: id)?.resume(returning: nil)
        if waiters[key]?.isEmpty == true { pending.removeAll { $0 == key }; urls[key] = nil; waiters[key] = nil }
        // A shared in-flight load finishes for the cache; disabling cancels it immediately.
    }
    private func cancelAll() {
        active.values.forEach { $0.cancel() }
        for group in waiters.values { group.values.forEach { $0.resume(returning: nil) } }
        waiters = [:]; pending = []; urls = [:]; memory = [:]
    }
    private func pump() {
        guard enabled, !clearing else { return }
        while active.count < min(12, max(1, workers)), !pending.isEmpty {
            let key = pending.removeFirst()
            guard let url = urls[key], waiters[key]?.isEmpty == false else { continue }
            let revision = revision, cache = cache, fetch = fetch
            active[key] = Task.detached(priority: .utility) { [weak self] in
                let generation = await cache.generation
                let cached = await cache.read(key)
                let result: URLThumbnailResult?
                if let cached { result = cached } else { result = await fetch(url) }
                if !Task.isCancelled, cached == nil, let result { await cache.write(result.png, key: key, generation: generation) }
                let image = Task.isCancelled ? nil : result?.image
                await self?.finish(key: key, image: image, revision: revision)
            }
        }
    }
    private func finish(key: String, image: CGImage?, revision: Int) {
        active[key] = nil
        let current = enabled && !clearing && self.revision == revision
        if !current, enabled, !clearing, waiters[key]?.isEmpty == false {
            pending.append(key); pump(); return
        }
        urls[key] = nil
        if current {
            if memory.count >= 128, let oldest = memory.min(by: { $0.value.1 < $1.value.1 })?.key { memory[oldest] = nil }
            memory[key] = (image, Date().addingTimeInterval(image == nil ? 3600 : 600))
        }
        for waiter in (waiters.removeValue(forKey: key) ?? [:]).values { waiter.resume(returning: current ? image : nil) }
        pump()
    }
    func clearCache() {
        guard !clearing else { return }
        clearing = true; cancelAll(); revision += 1
        Task {
            do { try await cache.clear(); message = "URL thumbnail cache cleared." }
            catch { message = "Could not clear the cache: \(error.localizedDescription)" }
            clearing = false; revision += 1; pump()
        }
    }
}
