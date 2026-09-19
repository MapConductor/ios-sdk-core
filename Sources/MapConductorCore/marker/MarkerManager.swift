import Foundation
public struct MarkerManagerStats: Sendable, Hashable {
    public let entityCount: Int
    public let hasSpatialIndex: Bool
    public let spatialIndexInitialized: Bool
    public let estimatedMemoryKB: Int
}

public final class MarkerManager<ActualMarker> {
    private let geocell: HexGeocellProtocol
    public let minMarkerCount: Int

    private var entities: [String: MarkerEntity<ActualMarker>] = [:]
    /// Only `findByIdPrefix` still needs hex cells; it is built the first time
    /// that is called, so nothing else pays for it.
    private var cellRegistry: HexCellRegistry<ActualMarker>?
    /// The index the per-tile queries use. Weak, because the manager owns the
    /// markers and the index only ever borrows them.
    private lazy var gridIndex = MarkerGridIndex<ActualMarker> { [weak self] in
        guard let self else { return [] }
        return Array(self.entities.values)
    }
    private var destroyed = false
    private let lock = NSLock()

    public init(
        geocell: HexGeocellProtocol = HexGeocell.defaultGeocell(),
        minMarkerCount: Int = 2000
    ) {
        self.geocell = geocell
        self.minMarkerCount = minMarkerCount
    }

    /// 破棄後のアクセスかどうかを返す。破棄後なら警告ログを出して `false` を返す。
    ///
    /// 進行中の非同期処理（Combine の配送、await から戻ってきたレンダラ往復、
    /// コレクタのデバウンス窓に溜まっていた更新）は、プロバイダ切り替えのように
    /// destroy → 生成が続けて起きる場面で destroy 直後に到着しうる。これは正常な
    /// 競合なので例外は投げない。
    ///
    /// ただし**書き込み系は実行しない**。マネージャはマップ 1 つにつき 1 個で、
    /// プロバイダを切り替えると新しいマップが自前のマネージャを作る（サンプルアプリも
    /// プロバイダごとに別の state を持ち、再利用していない）。破棄済みのマネージャに
    /// 書き戻しても誰も参照せず、破棄済みオブジェクトが再び状態を持つだけになる。
    /// android-sdk の `MarkerManager.usable(operation)` と同じ意味論。
    private func usableLocked(_ operation: String) -> Bool {
        if destroyed {
            NSLog("[MapConductor] MarkerManager.%@ called after destroy (ignored)", operation)
            return false
        }
        return true
    }

    public func getEntity(_ id: String) -> MarkerEntity<ActualMarker>? {
        lock.lock()
        defer { lock.unlock() }
        guard usableLocked("getEntity") else { return nil }
        return entities[id]
    }

    public func hasEntity(_ id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard usableLocked("hasEntity") else { return false }
        return entities[id] != nil
    }

    @discardableResult
    public func removeEntity(_ id: String) -> MarkerEntity<ActualMarker>? {
        lock.lock()
        defer { lock.unlock() }
        guard usableLocked("removeEntity") else { return nil }
        let removed = entities.removeValue(forKey: id)
        if let removed {
            cellRegistry?.removePoint(entity: removed)
            gridIndex.invalidate()
        }
        return removed
    }

    public func registerEntity(_ entity: MarkerEntity<ActualMarker>) {
        lock.lock()
        defer { lock.unlock() }
        guard usableLocked("registerEntity") else { return }
        entities[entity.state.id] = entity
        cellRegistry?.setPoint(entity: entity)
        gridIndex.invalidate()
    }

    public func updateEntity(_ entity: MarkerEntity<ActualMarker>) {
        lock.lock()
        defer { lock.unlock() }
        guard usableLocked("updateEntity") else { return }
        entities[entity.state.id] = entity
        cellRegistry?.setPoint(entity: entity)
        gridIndex.invalidate()
    }

    public func metersPerPixel(
        position: GeoPointProtocol,
        zoom: Double,
        pixels: Double,
        tileSize: Int = 256
    ) -> Double {
        lock.lock()
        defer { lock.unlock() }
        // 純粋な計算で内部状態を触らないため、破棄後でも警告だけ出して計算を続ける。
        _ = usableLocked("metersPerPixel")
        let pixelsAtZoom = Double(tileSize) * pow(2.0, zoom)
        return Earth.circumferenceMeters / pixelsAtZoom * cos(position.latitude * .pi / 180.0) * pixels
    }

    public func findNearest(position: GeoPointProtocol) -> MarkerEntity<ActualMarker>? {
        lock.lock()
        defer { lock.unlock() }
        guard usableLocked("findNearest") else { return nil }

        if entities.count > minMarkerCount {
            return gridIndex.nearest(position: position) ?? bruteForceNearestLocked(position: position)
        }

        return bruteForceNearestLocked(position: position)
    }

    private func bruteForceNearestLocked(position: GeoPointProtocol) -> MarkerEntity<ActualMarker>? {
        entities.values.min { lhs, rhs in
            let dx1 = lhs.state.position.latitude - position.latitude
            let dy1 = lhs.state.position.longitude - position.longitude
            let dx2 = rhs.state.position.latitude - position.latitude
            let dy2 = rhs.state.position.longitude - position.longitude
            return dx1 * dx1 + dy1 * dy1 < dx2 * dx2 + dy2 * dy2
        }
    }

    public func findByIdPrefix(_ prefix: String) -> [HexCell] {
        lock.lock()
        defer { lock.unlock() }
        guard usableLocked("findByIdPrefix") else { return [] }
        // The registry is built here and nowhere else: this is the one caller
        // that needs hex cells rather than markers.
        return ensureCellRegistryLocked().findByIdPrefix(prefix)
    }

    private func ensureCellRegistryLocked() -> HexCellRegistry<ActualMarker> {
        if let cellRegistry { return cellRegistry }

        let newRegistry = HexCellRegistry<ActualMarker>(geocell: geocell, zoom: 20.0)
        for entity in entities.values {
            newRegistry.setPoint(entity: entity)
        }
        cellRegistry = newRegistry
        return newRegistry
    }

    public func allEntities() -> [MarkerEntity<ActualMarker>] {
        lock.lock()
        defer { lock.unlock() }
        guard usableLocked("allEntities") else { return [] }
        return Array(entities.values)
    }

    public func findMarkersInBounds(_ bounds: GeoRectBounds) -> [MarkerEntity<ActualMarker>] {
        if bounds.isEmpty { return [] }

        lock.lock()
        defer { lock.unlock() }
        guard usableLocked("findMarkersInBounds") else { return [] }

        if entities.count > minMarkerCount {
            return gridIndex.inBounds(bounds)
        }

        return entities.values.filter { entity in
            bounds.contains(point: entity.state.position)
        }
    }

    /// The markers in `bounds`, thinned to at most one per
    /// `minSeparationDegrees`.
    ///
    /// The caller is saying that markers closer than that are
    /// interchangeable, which lets the index answer from its cells instead of
    /// reading every marker. It declines — and this falls back to the full
    /// query — when its cells are too coarse to honour the separation, so the
    /// caller still has to apply the real rule to what comes back.
    ///
    /// Mirrors `findMarkersInBounds(bounds, minSeparationDegrees)` in
    /// android-sdk.
    public func findMarkersInBounds(
        _ bounds: GeoRectBounds,
        minSeparationDegrees: Double
    ) -> [MarkerEntity<ActualMarker>] {
        if bounds.isEmpty { return [] }

        lock.lock()
        if usableLocked("findMarkersInBounds"), entities.count > minMarkerCount,
           let thinned = gridIndex.inBoundsThinned(bounds, minSeparationDegrees: minSeparationDegrees) {
            lock.unlock()
            return thinned
        }
        lock.unlock()

        return findMarkersInBounds(bounds)
    }

    public func getMemoryStats() -> MarkerManagerStats {
        lock.lock()
        defer { lock.unlock() }
        _ = usableLocked("getMemoryStats")
        return MarkerManagerStats(
            entityCount: entities.count,
            hasSpatialIndex: true,
            spatialIndexInitialized: gridIndex.isBuilt,
            estimatedMemoryKB: Int(estimateMemoryUsageLocked() / 1024)
        )
    }

    private func estimateMemoryUsageLocked() -> Int64 {
        let entityMapOverhead = Int64(entities.count) * 64
        let entityObjects = Int64(entities.count) * 200
        let gridSize = gridIndex.estimatedBytes()
        // The hex registry is usually absent; when findByIdPrefix has built it,
        // it costs a cell object and a string id per marker.
        let hexSize = cellRegistry == nil ? 0 : Int64(entities.count) * 100
        let spatialIndexSize = gridSize + hexSize
        return entityMapOverhead + entityObjects + spatialIndexSize
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        guard usableLocked("clear") else { return }
        entities.removeAll()
        cellRegistry?.clear()
        gridIndex.invalidate()
    }

    public func destroy() {
        lock.lock()
        defer { lock.unlock() }
        if destroyed { return }
        destroyed = true
        entities.removeAll()
        cellRegistry?.clear()
        cellRegistry = nil
        gridIndex.invalidate()
    }

    public var isDestroyed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return destroyed
    }

    public static func defaultManager() -> MarkerManager<ActualMarker> {
        MarkerManager<ActualMarker>()
    }

    public static func defaultManager(geocell: HexGeocellProtocol) -> MarkerManager<ActualMarker> {
        MarkerManager<ActualMarker>(geocell: geocell)
    }

    public static func defaultManager(
        geocell: HexGeocellProtocol? = nil,
        minMarkerCount: Int = 2000
    ) -> MarkerManager<ActualMarker> {
        MarkerManager<ActualMarker>(
            geocell: geocell ?? HexGeocell.defaultGeocell(),
            minMarkerCount: minMarkerCount
        )
    }
}
