import Foundation
import Network

struct VivaldiHTTP {
    struct Request { var method: String; var headers: [String: String]; var body: Data }
    static let maximumBytes = 4 * 1_024 * 1_024
    static func parse(_ data: Data) throws -> Request? {
        guard data.count <= maximumBytes + 16_384 else { throw TransferError(message: "Request exceeds the sync limit.") }
        guard let boundary = data.range(of: Data("\r\n\r\n".utf8)) else {
            if data.count > 16_384 { throw TransferError(message: "Request headers are too large.") }; return nil
        }
        guard boundary.lowerBound <= 16_384, let text = String(data: data[..<boundary.lowerBound], encoding: .utf8) else { throw TransferError(message: "Invalid request headers.") }
        let lines = text.components(separatedBy: "\r\n")
        guard let first = lines.first, ["POST /sync HTTP/1.1", "OPTIONS /sync HTTP/1.1"].contains(first) else { throw TransferError(message: "Unsupported sync request.") }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw TransferError(message: "Invalid header.") }
            let name = line[..<colon].lowercased(); let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard headers[name] == nil else { throw TransferError(message: "Repeated request headers are not accepted.") }; headers[name] = value
        }
        guard headers["transfer-encoding"] == nil else { throw TransferError(message: "Streaming request bodies are not accepted.") }
        let options = first.hasPrefix("OPTIONS")
        guard let length = Int(headers["content-length"] ?? (options ? "0" : "-1")), length >= 0, length <= maximumBytes else { throw TransferError(message: "Invalid body length.") }
        let available = data.count - boundary.upperBound
        guard available <= length else { throw TransferError(message: "Extra request bytes are not accepted.") }
        guard available == length else { return nil }
        return Request(method: options ? "OPTIONS" : "POST", headers: headers, body: Data(data[boundary.upperBound...]))
    }
    static func allowedOrigin(_ origin: String?) -> Bool {
        guard let origin else { return true }
        return origin.range(of: "^chrome-extension://[a-p]{32}$", options: .regularExpression) != nil
    }
    static func authenticates(_ supplied: String?, token: String) -> Bool {
        let expected = Array("Bearer \(token)".utf8), actual = Array((supplied ?? "").utf8)
        guard expected.count == actual.count else { return false }
        return zip(expected, actual).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
    static func response(_ body: Data, status: Int, origin: String?) -> Data {
        var headers = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n"
        if let origin, allowedOrigin(origin) { headers += "Access-Control-Allow-Origin: \(origin)\r\nVary: Origin\r\nAccess-Control-Allow-Methods: POST, OPTIONS\r\nAccess-Control-Allow-Headers: authorization, content-type\r\n" }
        return Data((headers + "\r\n").utf8) + body
    }
}

final class VivaldiBridge: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "Switchboard.Vivaldi.loopback")
    private let token: String
    private let handler: @Sendable (Data) async throws -> Data
    private var connections: [UUID: NWConnection] = [:]
    var ready: (@Sendable (Result<UInt16, Error>) -> Void)?
    init(port: UInt16, token: String, handler: @escaping @Sendable (Data) async throws -> Data) throws {
        self.token = token; self.handler = handler
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port) ?? .any)
        listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state { case .ready: if let port = self.listener.port { self.ready?(.success(port.rawValue)) }
            case .failed(let error): self.ready?(.failure(error))
            default: break }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
    }
    func start() { listener.start(queue: queue) }
    func stop() { listener.cancel(); queue.async { [weak self] in guard let self else { return }; for connection in self.connections.values { connection.cancel() }; self.connections.removeAll() } }
    private func accept(_ connection: NWConnection) {
        guard connections.count < 8 else { connection.cancel(); return }
        let id = UUID(); connections[id] = connection
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 15) { [weak self, weak connection] in connection?.cancel(); self?.connections[id] = nil }
        receive(connection, id: id, bytes: Data())
    }
    private func receive(_ connection: NWConnection, id: UUID, bytes: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var accumulated = bytes; if let data { accumulated.append(data) }
            do {
                if let request = try VivaldiHTTP.parse(accumulated) {
                    let host = "127.0.0.1:\(self.listener.port?.rawValue ?? 0)"
                    guard request.headers["host"] == host, VivaldiHTTP.allowedOrigin(request.headers["origin"]) else { throw TransferError(message: "Untrusted sync origin.") }
                    if request.method == "OPTIONS" { self.send(Data("{}".utf8), status: 200, origin: request.headers["origin"], connection: connection, id: id); return }
                    guard VivaldiHTTP.authenticates(request.headers["authorization"], token: self.token), request.headers["content-type"]?.hasPrefix("application/json") == true else {
                        self.send(Data("{\"message\":\"Pairing required.\"}".utf8), status: 401, origin: request.headers["origin"], connection: connection, id: id); return
                    }
                    Task {
                        do { let response = try await self.handler(request.body); self.queue.async { self.send(response, status: 200, origin: request.headers["origin"], connection: connection, id: id) } }
                        catch {
                            let body = (try? JSONEncoder().encode(VivaldiResponse(status: "error", message: error.localizedDescription))) ?? Data()
                            self.queue.async { self.send(body, status: 409, origin: request.headers["origin"], connection: connection, id: id) }
                        }
                    }
                } else if !complete && error == nil { self.receive(connection, id: id, bytes: accumulated) }
                else { connection.cancel(); self.connections[id] = nil }
            } catch { self.send(Data("{\"message\":\"Invalid sync request.\"}".utf8), status: 400, origin: nil, connection: connection, id: id) }
        }
    }
    private func send(_ body: Data, status: Int, origin: String?, connection: NWConnection, id: UUID) {
        connection.send(content: VivaldiHTTP.response(body, status: status, origin: origin), completion: .contentProcessed { [weak self] _ in
            connection.cancel(); self?.queue.async { [weak self] in self?.connections[id] = nil }
        })
    }
}
