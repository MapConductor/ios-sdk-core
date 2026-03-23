import Foundation
import Network

public final class LocalTileServer {
    public private(set) var baseUrl: String

    private let listener: NWListener
    private let queue: DispatchQueue
    private let providersLock = NSLock()
    private var providers: [String: TileProvider] = [:]
    private let cacheOptionsLock = NSLock()
    private var forceNoStoreCache: Bool

    private init(listener: NWListener, queue: DispatchQueue, baseUrl: String, forceNoStoreCache: Bool) {
        self.listener = listener
        self.queue = queue
        self.baseUrl = baseUrl
        self.forceNoStoreCache = forceNoStoreCache
    }

    public func register(routeId: String, provider: TileProvider) {
        providersLock.lock()
        providers[routeId] = provider
        providersLock.unlock()
    }

    public func unregister(routeId: String) {
        providersLock.lock()
        providers.removeValue(forKey: routeId)
        providersLock.unlock()
    }

    public func setForceNoStoreCache(_ value: Bool) {
        cacheOptionsLock.lock()
        forceNoStoreCache = value
        cacheOptionsLock.unlock()
    }

    public func urlTemplate(routeId: String, tileSize: Int) -> String {
        "\(baseUrl)/tiles/\(routeId)/\(tileSize)/{z}/{x}/{y}.png"
    }

    public func urlTemplate(routeId: String, tileSize: Int, cacheKey: String) -> String {
        "\(baseUrl)/tiles/\(routeId)/\(tileSize)/\(cacheKey)/{z}/{x}/{y}.png"
    }

    @available(*, deprecated, message: "`version` is ignored. Use `urlTemplate(routeId:tileSize:)` instead.")
    public func urlTemplate(routeId: String, version: Int64) -> String {
        urlTemplate(routeId: routeId, tileSize: RasterSource.defaultTileSize)
    }

    public func stop() {
        listener.cancel()
    }

    public static func startServer(forceNoStoreCache: Bool = false) -> LocalTileServer {
        let queue = DispatchQueue(label: "MapConductorCore.LocalTileServer", attributes: .concurrent)

        let listener: NWListener
        do {
            listener = try NWListener(using: .tcp)
        } catch {
            fatalError("Failed to create tile server listener: \(error)")
        }

        let server = LocalTileServer(
            listener: listener,
            queue: queue,
            baseUrl: "http://127.0.0.1:0",
            forceNoStoreCache: forceNoStoreCache
        )
        listener.newConnectionHandler = { [weak server] connection in
            server?.handleConnection(connection)
        }

        let readySemaphore = DispatchSemaphore(value: 0)
        var startError: NWError?
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed:
                if case let .failed(error) = state {
                    startError = error
                }
                readySemaphore.signal()
            default:
                break
            }
        }

        listener.start(queue: queue)
        readySemaphore.wait()

        if let startError {
            fatalError("Failed to start tile server: \(startError)")
        }

        guard let port = listener.port else {
            fatalError("Tile server failed to obtain a port.")
        }

        server.baseUrl = "http://127.0.0.1:\(port.rawValue)"
        return server
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(connection: connection, buffer: Data(), handled: 0)
    }

    private func receiveRequest(connection: NWConnection, buffer: Data, handled: Int) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            var nextBuffer = buffer
            if let data {
                nextBuffer.append(data)
            }

            if let headerRange = nextBuffer.range(of: Data([13, 10, 13, 10])) {
                let headerData = nextBuffer.subdata(in: 0..<headerRange.lowerBound)
                let remainingData = nextBuffer.subdata(in: headerRange.upperBound..<nextBuffer.count)
                self.handleRequest(headerData: headerData, connection: connection, remainingData: remainingData, handled: handled)
                return
            }

            if isComplete || error != nil {
                connection.cancel()
                return
            }

            self.receiveRequest(connection: connection, buffer: nextBuffer, handled: handled)
        }
    }

    private func handleRequest(headerData: Data, connection: NWConnection, remainingData: Data, handled: Int) {
        let request = parseRequest(headerData: headerData)
        guard let request, request.valid else {
            sendResponse(
                connection: connection,
                status: "400 Bad Request",
                contentType: "text/plain",
                body: Data("Bad request".utf8),
                keepAlive: false,
                extraHeaders: ["Cache-Control": "no-store"]
            ) { [weak connection] in
                connection?.cancel()
            }
            return
        }

        let keepAlive = shouldKeepAlive(request)

        guard request.method == "GET" else {
            sendResponse(
                connection: connection,
                status: "405 Method Not Allowed",
                contentType: "text/plain",
                body: Data("Method not allowed".utf8),
                keepAlive: false,
                extraHeaders: ["Allow": "GET", "Cache-Control": "no-store"]
            ) { [weak connection] in
                connection?.cancel()
            }
            return
        }

        let path = request.path.split(separator: "?")[0]
        let tileResponse = resolveTile(path: String(path))
        if let tileResponse {
            sendResponse(
                connection: connection,
                status: "200 OK",
                contentType: "image/png",
                body: tileResponse.body,
                keepAlive: keepAlive,
                extraHeaders: ["Cache-Control": tileResponse.cacheControl]
            ) { [weak self, weak connection] in
                guard let self, let connection else { return }
                self.finishRequest(connection: connection, remainingData: remainingData, keepAlive: keepAlive, handled: handled)
            }
        } else {
            sendResponse(
                connection: connection,
                status: "404 Not Found",
                contentType: "text/plain",
                body: Data("Not found".utf8),
                keepAlive: keepAlive,
                extraHeaders: ["Cache-Control": "no-store"]
            ) { [weak self, weak connection] in
                guard let self, let connection else { return }
                self.finishRequest(connection: connection, remainingData: remainingData, keepAlive: keepAlive, handled: handled)
            }
        }
    }

    private func finishRequest(connection: NWConnection, remainingData: Data, keepAlive: Bool, handled: Int) {
        let nextHandled = handled + 1
        if keepAlive, nextHandled < Self.maxKeepAliveRequests {
            receiveRequest(connection: connection, buffer: remainingData, handled: nextHandled)
        } else {
            connection.cancel()
        }
    }

    private func getProvider(routeId: String) -> TileProvider? {
        providersLock.lock()
        defer { providersLock.unlock() }
        return providers[routeId]
    }

    private func parseRequest(headerData: Data) -> Request? {
        guard let headerString = String(data: headerData, encoding: .utf8) else {
            return nil
        }

        let lines = headerString.split(separator: "\n", omittingEmptySubsequences: false)
        var requestLine: Substring?
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                requestLine = Substring(trimmed)
                break
            }
        }

        guard let requestLine else { return nil }
        let parts = requestLine.split(separator: " ")
        let valid = parts.count >= 2
        let method = parts.first.map(String.init) ?? ""
        let path = parts.dropFirst().first.map(String.init) ?? ""
        let httpVersion = parts.dropFirst(2).first.map(String.init) ?? "HTTP/1.0"

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            guard let index = trimmed.firstIndex(of: ":") else { continue }
            let key = trimmed[..<index].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = trimmed[trimmed.index(after: index)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty, !value.isEmpty {
                headers[key] = value
            }
        }

        return Request(method: method, path: path, httpVersion: httpVersion, headers: headers, valid: valid)
    }

    private func shouldKeepAlive(_ request: Request) -> Bool {
        let connection = request.headers["connection"]?.lowercased()
        switch request.httpVersion {
        case "HTTP/1.1":
            return connection != "close"
        case "HTTP/1.0":
            return connection == "keep-alive"
        default:
            return false
        }
    }

    private func resolveTile(path: String) -> TileResponse? {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else { return nil }

        let segments = trimmed.split(separator: "/").map(String.init)
        guard segments.count >= 6, segments[0] == "tiles" else {
            return nil
        }

        let routeId = segments[1]
        guard Int(segments[2]) != nil else {
            return nil
        }
        let hasCacheKey = segments.count >= 7
        let zIndex = hasCacheKey ? 4 : 3
        let xIndex = hasCacheKey ? 5 : 4
        let yIndex = hasCacheKey ? 6 : 5
        guard let z = Int(segments[zIndex]), let x = Int(segments[xIndex]) else {
            return nil
        }

        let yPart = segments[yIndex].split(separator: ".").first
        guard let yPart, let y = Int(yPart) else {
            return nil
        }

        guard let provider = getProvider(routeId: routeId) else {
            return nil
        }

        guard let bytes = provider.renderTile(request: TileRequest(x: x, y: y, z: z)) else {
            return nil
        }

        let noStore: Bool = {
            cacheOptionsLock.lock()
            defer { cacheOptionsLock.unlock() }
            return forceNoStoreCache
        }()
        let cacheControl = noStore ? Self.noStoreCacheControl : Self.longCacheControl
        return TileResponse(body: bytes, cacheControl: cacheControl)
    }

    private func sendResponse(
        connection: NWConnection,
        status: String,
        contentType: String,
        body: Data,
        keepAlive: Bool,
        extraHeaders: [String: String] = [:],
        completion: @escaping () -> Void
    ) {
        var response = Data()
        response.append("HTTP/1.1 \(status)\r\n".data(using: .utf8) ?? Data())
        response.append("Content-Type: \(contentType)\r\n".data(using: .utf8) ?? Data())
        response.append("Content-Length: \(body.count)\r\n".data(using: .utf8) ?? Data())
        response.append("Connection: \(keepAlive ? "keep-alive" : "close")\r\n".data(using: .utf8) ?? Data())
        for (key, value) in extraHeaders {
            response.append("\(key): \(value)\r\n".data(using: .utf8) ?? Data())
        }
        response.append("\r\n".data(using: .utf8) ?? Data())
        response.append(body)

        connection.send(content: response, completion: .contentProcessed { _ in
            completion()
        })
    }

    private struct Request {
        let method: String
        let path: String
        let httpVersion: String
        let headers: [String: String]
        let valid: Bool
    }

    private struct TileResponse {
        let body: Data
        let cacheControl: String
    }

    private static let maxKeepAliveRequests = 10
    private static let longCacheControl = "public, max-age=31536000, immutable"
    private static let noStoreCacheControl = "no-store, no-cache, must-revalidate, max-age=0"
}
