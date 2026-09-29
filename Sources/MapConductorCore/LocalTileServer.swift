import Foundation
import Network

public final class LocalTileServer: @unchecked Sendable {
    public private(set) var baseUrl: String

    private let listener: NWListener
    private let queue: DispatchQueue
    private let providersLock = NSLock()
    private var providers: [String: TileProvider] = [:]
    private let cacheOptionsLock = NSLock()
    private var forceNoStoreCache: Bool
    private let connectionsLock = NSLock()
    private var activeConnections = 0
    private var shedConnections = 0

    /**
     The lane tile drawing runs in: at most `renderWidth` at a time, below the
     UI in priority.

     Without it, every connection rendered its tile on the shared concurrent
     queue, synchronously, as it arrived. A pinch makes the map ask for tiles at
     every zoom the gesture passes through, so dozens of renders ran at once;
     GCD answers that by spawning threads — far past the core count — and the
     gesture itself starves. That is what "the map computes while I pinch" feels
     like. android-sdk never had this: its server has had a bounded pool
     (`MAX_WORKER_THREADS = 8`) from the start, which is why the same pinch on a
     Pixel 5a feels fine.

     `.utility` matters as much as the width. The renders are pure CPU; at
     default QoS they compete with the main thread on equal terms, at utility
     the gesture preempts them.
     */
    private let renderQueue = DispatchQueue(
        label: "MapConductorCore.LocalTileServer.render",
        qos: .utility,
        attributes: .concurrent
    )
    private let renderGate: DispatchSemaphore
    private let renderWidth: Int

    /// Counters behind the once-a-second summary log.
    private let statsLock = NSLock()
    private var statsWindowStart = DispatchTime.now().uptimeNanoseconds
    private var statsRendered = 0
    private var statsRenderNanos: UInt64 = 0
    private var statsMaxWaitNanos: UInt64 = 0
    private var statsMaxActive = 0
    private var statsNotFound = 0
    private var statsFailed = 0
    private var statsAbandoned = 0
    private var activeRenders = 0

    private init(listener: NWListener, queue: DispatchQueue, baseUrl: String, forceNoStoreCache: Bool) {
        self.listener = listener
        self.queue = queue
        self.baseUrl = baseUrl
        self.forceNoStoreCache = forceNoStoreCache
        // Two cores stay free for the gesture and the map's own GL thread.
        // The same width android-sdk converges on for its 8-core devices.
        renderWidth = min(8, max(2, ProcessInfo.processInfo.activeProcessorCount - 2))
        renderGate = DispatchSemaphore(value: renderWidth)
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

    public var isListening: Bool {
        listener.state == .ready
    }

    internal var allProviders: [String: TileProvider] {
        providersLock.lock()
        defer { providersLock.unlock() }
        return providers
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

    /**
     Renders one of this server's URLs without going through TCP.

     Native map SDKs that expose an in-process tile callback should use this
     path. Besides avoiding a loopback HTTP round trip, their task cancellation
     is authoritative: unlike a TCP FIN it really does mean that the map no
     longer wants the tile.

     The same render gate is shared with HTTP clients, so using the direct path
     cannot create an unbounded number of CPU-heavy renders.
     */
    public func renderLocalTile(
        url: URL,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) -> Data? {
        guard url.absoluteString.hasPrefix(baseUrl + "/") else { return nil }

        let queuedAt = DispatchTime.now().uptimeNanoseconds
        while renderGate.wait(timeout: .now() + .milliseconds(10)) != .success {
            if isCancelled() { return nil }
        }
        let waitNanos = DispatchTime.now().uptimeNanoseconds - queuedAt

        statsLock.lock()
        activeRenders += 1
        statsMaxActive = max(statsMaxActive, activeRenders)
        statsLock.unlock()

        let renderStart = DispatchTime.now().uptimeNanoseconds
        let outcome = resolveTile(path: url.path, isCancelled: isCancelled)
        let renderNanos = DispatchTime.now().uptimeNanoseconds - renderStart

        statsLock.lock()
        activeRenders -= 1
        statsLock.unlock()
        renderGate.signal()

        record(outcome: outcome, path: url.path, waitNanos: waitNanos, renderNanos: renderNanos)

        switch outcome {
        case .tile(let response):
            return response.body
        case .empty(let pixelSize, _):
            return TransparentTile.png(size: pixelSize)
        case .notFound, .failed, .abandoned:
            return nil
        }
    }

    @available(*, deprecated, message: "`version` is ignored. Use `urlTemplate(routeId:tileSize:)` instead.")
    public func urlTemplate(routeId: String, version: Int64) -> String {
        urlTemplate(routeId: routeId, tileSize: RasterLayerSource.defaultTileSize)
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
        // Only serve device-internal clients: a remote peer cannot complete a
        // TCP handshake with a spoofed loopback source address. The listener
        // itself stays on the wildcard address (dual-stack) because some map
        // SDK HTTP stacks resolve localhost to ::1.
        guard isLoopback(connection) else {
            MCLog.tileServer("LocalTileServer: rejected non-loopback connection from \(connection.endpoint)")
            connection.cancel()
            return
        }

        // Bound concurrent connections; excess is shed and the map SDK retries.
        connectionsLock.lock()
        if activeConnections >= Self.maxConcurrentConnections {
            shedConnections += 1
            let shed = shedConnections
            connectionsLock.unlock()
            MCLog.tileServer("LocalTileServer: shed connection (saturated) total=\(shed)")
            connection.cancel()
            return
        }
        activeConnections += 1
        connectionsLock.unlock()

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                guard let self else { return }
                self.connectionsLock.lock()
                self.activeConnections = max(0, self.activeConnections - 1)
                self.connectionsLock.unlock()
            default:
                break
            }
        }

        connection.start(queue: queue)
        receiveRequest(connection: connection, buffer: Data(), handled: 0)
    }

    private func isLoopback(_ connection: NWConnection) -> Bool {
        guard case let .hostPort(host, _) = connection.endpoint else { return false }
        switch host {
        case .ipv4(let address):
            return address.isLoopback
        case .ipv6(let address):
            if address.isLoopback { return true }
            // IPv4-mapped loopback (::ffff:127.0.0.1)
            return address.asIPv4?.isLoopback == true
        case .name:
            return false
        @unknown default:
            return false
        }
    }

    private func receiveRequest(connection: NWConnection, buffer: Data, handled: Int) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            var nextBuffer = buffer
            if let data {
                nextBuffer.append(data)
            }

            // Refuse oversized request heads instead of buffering them forever.
            if nextBuffer.count > Self.maxRequestHeadBytes {
                connection.cancel()
                return
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

        let path = String(request.path.split(separator: "?")[0])
        let queuedAt = DispatchTime.now().uptimeNanoseconds
        renderQueue.async { [weak self] in
            guard let self else {
                connection.cancel()
                return
            }
            // The wait is the queue telling us the lane is full. It shows up in
            // the summary log as wait(max); a long one during a pinch means the
            // gesture is generating tiles faster than the lane drains them,
            // which is the intended trade — the UI stays smooth and the tiles
            // arrive a beat later.
            self.renderGate.wait()
            let waitNanos = DispatchTime.now().uptimeNanoseconds - queuedAt
            self.statsLock.lock()
            self.activeRenders += 1
            self.statsMaxActive = max(self.statsMaxActive, self.activeRenders)
            self.statsLock.unlock()

            let renderStart = DispatchTime.now().uptimeNanoseconds
            let gone = { @Sendable in
                switch connection.state {
                case .cancelled, .failed: return true
                default: return false
                }
            }
            let outcome = self.resolveTile(path: path, isCancelled: gone)
            let renderNanos = DispatchTime.now().uptimeNanoseconds - renderStart
            self.renderGate.signal()
            self.statsLock.lock()
            self.activeRenders -= 1
            self.statsLock.unlock()

            self.record(outcome: outcome, path: path, waitNanos: waitNanos, renderNanos: renderNanos)
            self.respond(
                outcome: outcome,
                connection: connection,
                remainingData: remainingData,
                keepAlive: keepAlive,
                handled: handled
            )
        }
    }

    /// Feeds the counters and emits the once-a-second summary plus anomalies.
    private func record(outcome: TileOutcome, path: String, waitNanos: UInt64, renderNanos: UInt64) {
        MCLog.tileDetail(String(
            format: "tile %@ wait=%.0fms render=%.0fms",
            path, Double(waitNanos) / 1e6, Double(renderNanos) / 1e6
        ))
        switch outcome {
        case .notFound:
            MCLog.tileServer("LocalTileServer: 404 \(path)")
        case .failed:
            // 503 -- the map will retry. If these repeat for the same path,
            // the provider is failing deterministically; the path says which.
            MCLog.tileServer("LocalTileServer: 503 \(path)")
        case .abandoned:
            MCLog.tileServer("LocalTileServer: abandoned \(path) after \(renderNanos / 1_000_000)ms")
        case .empty, .tile:
            break
        }

        statsLock.lock()
        statsRendered += 1
        statsRenderNanos += renderNanos
        statsMaxWaitNanos = max(statsMaxWaitNanos, waitNanos)
        if case .notFound = outcome { statsNotFound += 1 }
        if case .failed = outcome { statsFailed += 1 }
        if case .abandoned = outcome { statsAbandoned += 1 }
        let now = DispatchTime.now().uptimeNanoseconds
        let windowNanos = now - statsWindowStart
        var line: String?
        if windowNanos >= 1_000_000_000 {
            line = String(
                format: "LocalTileServer: %d tiles in %.1fs render=%.0fms wait(max)=%.0fms "
                    + "parallel(max)=%d/%d notFound=%d failed=%d abandoned=%d",
                statsRendered, Double(windowNanos) / 1e9,
                Double(statsRenderNanos) / 1e6, Double(statsMaxWaitNanos) / 1e6,
                statsMaxActive, renderWidth, statsNotFound, statsFailed, statsAbandoned
            )
            statsWindowStart = now
            statsRendered = 0
            statsRenderNanos = 0
            statsMaxWaitNanos = 0
            statsMaxActive = 0
            statsNotFound = 0
            statsFailed = 0
            statsAbandoned = 0
        }
        statsLock.unlock()
        if let line { MCLog.tileServer(line) }
    }

    private func respond(
        outcome: TileOutcome,
        connection: NWConnection,
        remainingData: Data,
        keepAlive: Bool,
        handled: Int
    ) {
        if case .abandoned = outcome {
            // Nobody is left to read an answer, and the only answer that would
            // fit is "not found", which is a lie the map would believe. End the
            // connection instead.
            connection.cancel()
            return
        }
        if case .failed = outcome {
            sendResponse(
                connection: connection,
                status: "503 Service Unavailable",
                contentType: "text/plain",
                body: Data("Tile render failed".utf8),
                keepAlive: keepAlive,
                extraHeaders: ["Cache-Control": "no-store", "Retry-After": "1"]
            ) { [weak self, weak connection] in
                guard let self, let connection else { return }
                self.finishRequest(connection: connection, remainingData: remainingData, keepAlive: keepAlive, handled: handled)
            }
            return
        }
        let tileResponse: TileResponse? = {
            switch outcome {
            case .tile(let response):
                return response
            case .empty(let pixelSize, let cacheControl):
                // A transparent picture is what "nothing here" looks like. If
                // the encoder cannot produce one the answer falls through to
                // 404 below, which is the old behaviour and still wrong — but
                // it only happens when PNG encoding itself is broken.
                guard let png = TransparentTile.png(size: pixelSize) else { return nil }
                return TileResponse(body: png, cacheControl: cacheControl)
            default:
                return nil
            }
        }()
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

        // Swift では "\r\n" が 1 つの Character なので、CRLF 区切りの文字列を
        // `split(separator: "\n")` しても**行が分かれない**（全体が 1 要素になり、
        // ヘッダが 1 つも取れなくなる）。先に LF へ正規化する。
        let normalized = headerString.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
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

    /// What a request resolved to. `abandoned` is deliberately not `notFound`:
    /// the difference is what the map does next.
    private enum TileOutcome {
        case tile(TileResponse)
        /// The provider had nothing to draw here. Answered with a transparent
        /// tile: an empty spot is a real answer, and a cacheable one — the URL
        /// carries the data version, so it is re-asked when the data changes.
        /// Saying 404 or 503 instead is what leaves a hole in the map.
        case empty(pixelSize: Int, cacheControl: String)
        /// The path names nothing: bad route, bad coordinates. Answered 404,
        /// and the map is right to stop asking.
        case notFound
        /// The provider could not draw it right now. Answered 503, which every
        /// map SDK treats as retryable. A 404 here would be believed forever:
        /// GMS caches "no tile" per coordinate, so one transient failure
        /// becomes a permanent hole with its neighbours' icons cut at the edge.
        case failed
        /// The client gave up before the tile was drawn.
        case abandoned
    }

    private func resolveTile(
        path: String,
        isCancelled: @escaping @Sendable () -> Bool
    ) -> TileOutcome {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else { return .notFound }

        let segments = trimmed.split(separator: "/").map(String.init)
        guard segments.count >= 6, segments[0] == "tiles" else {
            return .notFound
        }

        let routeId = segments[1]
        guard let tileSize = Int(segments[2]) else {
            return .notFound
        }
        let hasCacheKey = segments.count >= 7
        let zIndex = hasCacheKey ? 4 : 3
        let xIndex = hasCacheKey ? 5 : 4
        let yIndex = hasCacheKey ? 6 : 5
        guard let z = Int(segments[zIndex]), let x = Int(segments[xIndex]) else {
            return .notFound
        }

        guard let coordinate = parseTileCoordinate(segments[yIndex]) else {
            return .notFound
        }

        guard let provider = getProvider(routeId: routeId) else {
            return .notFound
        }

        let noStore: Bool = {
            cacheOptionsLock.lock()
            defer { cacheOptionsLock.unlock() }
            return forceNoStoreCache
        }()
        let cacheControl = noStore ? Self.noStoreCacheControl : Self.longCacheControl

        let bytes: Data?
        do {
            bytes = try provider.renderTile(
                request: TileRequest(x: x, y: coordinate.y, z: z, pixelRatio: coordinate.pixelRatio),
                isCancelled: isCancelled
            )
        } catch {
            MCLog.tileServer("LocalTileServer: render threw for \(trimmed): \(error)")
            return isCancelled() ? .abandoned : .failed
        }
        guard let bytes else {
            // Nothing to draw. Answered with pixels, not with "no tile" —
            // unless nobody is waiting any more, in which case the only thing
            // worth doing is not answering.
            return isCancelled() ? .abandoned : .empty(
                pixelSize: tileSize * coordinate.pixelRatio,
                cacheControl: cacheControl
            )
        }
        guard !isCancelled() else { return .abandoned }
        return .tile(TileResponse(body: bytes, cacheControl: cacheControl))
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
        // Allow cross-origin reads: WebView-based providers (e.g. Longdo, whose
        // MapLibre GL map runs in a WKWebView at a different origin) fetch these
        // tiles as crossOrigin images and would otherwise drop them. The server
        // only ever serves locally-generated overlay tiles on loopback.
        response.append("Access-Control-Allow-Origin: *\r\n".data(using: .utf8) ?? Data())
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
    private static let maxConcurrentConnections = 128
    private static let maxRequestHeadBytes = 16 * 1024
    private static let longCacheControl = "public, max-age=31536000, immutable"
    private static let noStoreCacheControl = "no-store, no-cache, must-revalidate, max-age=0"
}

struct TileCoordinate: Equatable {
    let y: Int
    let pixelRatio: Int
}

private let tileCoordinateExpression = try! NSRegularExpression(
    pattern: #"^(\d+)(?:@(\d+)x)?\.png$"#
)

func parseTileCoordinate(_ fileName: String) -> TileCoordinate? {
    guard let match = tileCoordinateExpression.firstMatch(
              in: fileName,
              range: NSRange(fileName.startIndex..., in: fileName)
          ),
          let yRange = Range(match.range(at: 1), in: fileName),
          let y = Int(fileName[yRange]) else {
        return nil
    }

    let pixelRatio: Int
    if match.range(at: 2).location != NSNotFound,
       let ratioRange = Range(match.range(at: 2), in: fileName),
       let parsedRatio = Int(fileName[ratioRange]) {
        pixelRatio = parsedRatio
    } else {
        pixelRatio = 1
    }
    guard (1...3).contains(pixelRatio) else { return nil }
    return TileCoordinate(y: y, pixelRatio: pixelRatio)
}
