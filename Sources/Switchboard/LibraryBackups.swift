import Foundation

struct LibraryBackup: Codable {
    var schemaVersion = 1
    var created: Date
    var library: LibraryData
    func validated() throws -> LibraryData {
        guard schemaVersion == 1 else { throw TransferError(message: "Unsupported backup version.") }
        try LibraryIntegrity.validate(library)
        return library
    }
}

struct LibraryBackups {
    let directory: URL
    var clock: () -> Date = Date.init
    var dailyLimit = 30
    func daily(_ bytes: Data) throws -> URL {
        let decoded = try JSONDecoder().decode(LibraryData.self, from: bytes)
        try LibraryIntegrity.validate(decoded)
        let formatter = DateFormatter(); formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        let file = directory.appendingPathComponent("daily-\(formatter.string(from: clock())).json")
        if !FileManager.default.fileExists(atPath: file.path) { try write(decoded, to: file); try rotate(keeping: file) }
        return file
    }
    func checkpoint(_ bytes: Data, label: String) throws -> URL {
        let decoded = try JSONDecoder().decode(LibraryData.self, from: bytes)
        try LibraryIntegrity.validate(decoded)
        let file = directory.appendingPathComponent("\(label)-\(UUID().uuidString).json")
        try write(decoded, to: file); return file
    }
    private func write(_ data: LibraryData, to url: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(LibraryBackup(created: clock(), library: data)).write(to: url, options: .atomic)
    }
    private func rotate(keeping newest: URL) throws {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("daily-") && $0.pathExtension == "json" && $0.lastPathComponent != newest.lastPathComponent }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for file in files.dropFirst(max(0, dailyLimit - 1)) { try FileManager.default.removeItem(at: file) }
    }
}
