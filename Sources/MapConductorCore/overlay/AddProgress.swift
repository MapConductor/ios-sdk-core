import Foundation

/// How far a collection (``Markers``, ``Circles``, ``Polylines``, ``Polygons``)
/// is with putting its states on the map: for a list of thousands the screen
/// shows nothing until they are drawn, and these say that work is going on.
///
/// "On the map" is what each state's `onAdded` means: drawn natively, or, for a
/// state drawn in tiles, its tiles handed to the map. The work does not end
/// there for tiles, so the collection also counts as busy while its tiles are
/// being drawn: after a filter change, and while the camera moves to where
/// tiles are not drawn yet.
///
/// - `onAddStart(total)`: a list was handed over, or tiles have been drawn for
///   0.2 s without one; `total` is how many states the list brought that are
///   not on the map yet (0 when it only removed or updated states, or for
///   tiles alone). An empty list after an empty one calls nothing.
/// - `onAddProgress(added, total)`: how many of them are on the map so far, at
///   most every 100 ms, and once more with `added == total` before the end
///   when `total` is not 0.
/// - `onAddEnd(total)`: all of them are on the map and nothing has been drawn
///   for 0.4 s. A state taken out of the list before it got there no longer
///   counts against the end.
///
/// A list that brings new states while an earlier one is still being added
/// starts over: a new `onAddStart` with only the new states, and no `onAddEnd`
/// for the earlier list. All three run on the main actor, never during a view
/// update.
///
/// A collection is told apart from the others on the same map by where it is
/// written in the content closure, the way SwiftUI tells views apart. It
/// starts from nothing when it leaves the content and comes back, and when the
/// map is recreated.
public struct AddProgressCallbacks {
    public var onAddStart: ((_ total: Int) -> Void)?
    public var onAddProgress: ((_ added: Int, _ total: Int) -> Void)?
    public var onAddEnd: ((_ total: Int) -> Void)?

    public init(
        onAddStart: ((_ total: Int) -> Void)? = nil,
        onAddProgress: ((_ added: Int, _ total: Int) -> Void)? = nil,
        onAddEnd: ((_ total: Int) -> Void)? = nil
    ) {
        self.onAddStart = onAddStart
        self.onAddProgress = onAddProgress
        self.onAddEnd = onAddEnd
    }

    var isEmpty: Bool { onAddStart == nil && onAddProgress == nil && onAddEnd == nil }
}

/// One collection's list as it was put into a ``MapViewContent``.
struct AddProgressRequest {
    /// Where the collection is written (and what kind it is).
    let site: String
    let callbacks: AddProgressCallbacks
    /// The list's storage, so that an unchanged list costs nothing to recognise:
    /// the content is rebuilt on every camera frame.
    let identity: UnsafeRawPointer?
    let count: Int
    /// The list's ids and state objects. Walks the whole list; called only when
    /// the list changed. Holds the list, so its storage cannot be reused while
    /// ``identity`` is remembered.
    let entries: () -> [(id: String, state: AnyObject)]
    /// The map's tilers for this kind, busy while they take a list or draw
    /// tiles. Filled in by the collection when it joins the content.
    var activity: [TileActivity] = []
    let kind: String

    init<S: Identifiable & AnyObject>(
        kind: String,
        states: [S],
        callbacks: AddProgressCallbacks,
        fileID: StaticString,
        line: UInt,
        column: UInt
    ) where S.ID == String {
        site = "\(kind) \(fileID):\(line):\(column)"
        self.kind = kind
        self.callbacks = callbacks
        identity = states.withUnsafeBufferPointer { UnsafeRawPointer($0.baseAddress) }
        count = states.count
        entries = { states.map { (id: $0.id, state: $0 as AnyObject) } }
    }
}

/// The states one collection handed over and how many of them are on the map.
@MainActor
final class AddProgressTracker {
    private static let progressInterval: TimeInterval = 0.1

    private var callbacks = AddProgressCallbacks()
    private var last: AddProgressRequest?
    private var ids: Set<String> = []
    /// State objects handed over and not on the map yet.
    private var pending: [ObjectIdentifier: (id: String, state: AnyObject)] = [:]
    private var total = 0
    private var added = 0
    /// Between an onAddStart and its onAddEnd.
    private var busy = false
    /// This stretch's onAddStart has been called (it waits for the view update to end).
    private var announced = true
    /// The collection's tiles are being drawn (or its tiler is taking a list).
    private var drawing = false
    /// Cancels what an earlier stretch scheduled (its start, its progress).
    private var generation = 0
    private var settleToken = 0
    private var drawStartToken = 0
    private var lastProgressAt = -TimeInterval.infinity
    private var progressScheduled = false
    private let now: () -> TimeInterval
    private let settleDelay: TimeInterval
    private let drawStartDelay: TimeInterval
    private var observed: [ObjectIdentifier] = []
    private var stopObserving: [() -> Void] = []

    init(
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        settleDelay: TimeInterval = 0.4,
        drawStartDelay: TimeInterval = 0.2
    ) {
        self.now = now
        self.settleDelay = settleDelay
        self.drawStartDelay = drawStartDelay
    }

    /// The collection's list in this content pass. Calls nothing itself (this
    /// runs during a view update); the start it causes comes right after.
    func sync(_ request: AddProgressRequest) {
        callbacks = request.callbacks
        observe(request.activity)
        if let last, last.identity == request.identity, last.count == request.count { return }
        last = request
        let entries = request.entries()
        let nextIds = Set(entries.map(\.id))
        let hadStates = !ids.isEmpty
        let fresh = entries.filter { !ids.contains($0.id) }
        ids = nextIds
        if entries.isEmpty && !hadStates { return }
        if !pending.isEmpty {
            let before = pending.count
            pending = pending.filter { nextIds.contains($0.value.id) }
            total -= before - pending.count
            if fresh.isEmpty {
                // A state that is still coming may be handed over again as a new
                // object with the same id; the map reports that object.
                let pendingIds = Set(pending.values.map(\.id))
                var rekeyed: [ObjectIdentifier: (id: String, state: AnyObject)] = [:]
                for entry in entries where pendingIds.contains(entry.id) {
                    rekeyed[ObjectIdentifier(entry.state)] = entry
                }
                pending = rekeyed
            }
        }
        if !fresh.isEmpty {
            pending = Dictionary(fresh.map { (ObjectIdentifier($0.state), $0) }, uniquingKeysWith: { a, _ in a })
            total = pending.count
            added = 0
            lastProgressAt = -.infinity
            begin()
        } else if !busy {
            total = 0
            added = 0
            begin()
        }
        scheduleSettle()
    }

    /// States reached the map (any collection's, any map's: only ours count).
    func arrived(_ states: [AnyObject]) {
        if pending.isEmpty { return }
        var hit = false
        for state in states where pending.removeValue(forKey: ObjectIdentifier(state)) != nil {
            added += 1
            hit = true
        }
        guard hit else { return }
        announceStart()
        if pending.isEmpty { scheduleSettle() } else { reportProgress() }
    }

    /// Whether the collection's tiles are being drawn now.
    func drawingChanged(_ drawing: Bool) {
        if drawing == self.drawing { return }
        self.drawing = drawing
        if drawing {
            settleToken += 1
            if !busy {
                drawStartToken += 1
                let token = drawStartToken
                DispatchQueue.main.asyncAfter(deadline: .now() + drawStartDelay) { [weak self] in
                    guard let self, self.drawStartToken == token, self.drawing, !self.busy else { return }
                    self.total = 0
                    self.added = 0
                    self.begin()
                }
            }
        } else {
            drawStartToken += 1
            scheduleSettle()
        }
    }

    func dispose() {
        generation += 1
        settleToken += 1
        drawStartToken += 1
        pending = [:]
        observe([])
    }

    private func begin() {
        generation += 1
        busy = true
        announced = false
        drawStartToken += 1
        later { $0.announceStart() }
    }

    private func later(_ body: @escaping @MainActor (AddProgressTracker) -> Void) {
        let generation = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == generation else { return }
            body(self)
        }
    }

    private func announceStart() {
        if announced { return }
        announced = true
        callbacks.onAddStart?(total)
    }

    /// Every reason to be busy that ends schedules this anew, so it runs once
    /// nothing has come, been handed over or drawn for the whole delay.
    private func scheduleSettle() {
        guard busy else { return }
        settleToken += 1
        let token = settleToken
        DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay) { [weak self] in
            guard let self, self.settleToken == token else { return }
            self.finishIfIdle()
        }
    }

    private func finishIfIdle() {
        guard busy, !drawing, pending.isEmpty else { return }
        announceStart()
        busy = false
        generation += 1
        let total = self.total
        self.total = 0
        added = 0
        if total > 0 { callbacks.onAddProgress?(total, total) }
        callbacks.onAddEnd?(total)
    }

    private func reportProgress() {
        if progressScheduled { return }
        let wait = lastProgressAt + Self.progressInterval - now()
        if wait <= 0 {
            emitProgress()
            return
        }
        progressScheduled = true
        let generation = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self else { return }
            self.progressScheduled = false
            guard self.generation == generation else { return }
            self.emitProgress()
        }
    }

    private func emitProgress() {
        if pending.isEmpty { return }
        lastProgressAt = now()
        callbacks.onAddProgress?(added, total)
    }

    /// Follows `activity` (the same tilers are a no-op), off the view update.
    private func observe(_ activity: [TileActivity]) {
        let identifiers = activity.map(ObjectIdentifier.init)
        if identifiers == observed { return }
        observed = identifiers
        for stop in stopObserving { stop() }
        stopObserving = activity.map { tiler in
            tiler.observe { [weak self] _ in
                DispatchQueue.main.async { self?.activityChanged(activity) }
            }
        }
        if activity.isEmpty {
            drawingChanged(false)
        } else {
            DispatchQueue.main.async { [weak self] in self?.activityChanged(activity) }
        }
    }

    private func activityChanged(_ activity: [TileActivity]) {
        guard activity.map(ObjectIdentifier.init) == observed else { return }
        drawingChanged(activity.contains { $0.active })
    }
}

/// The trackers of one map view's collections, kept for as long as the map view.
@MainActor
final class AddProgressHost: ObservableObject {
    private var trackers: [String: AddProgressTracker] = [:]
    private var removeListener: (() -> Void)?

    /// The collections in this content pass. Ones no longer there are dropped.
    func sync(_ requests: [AddProgressRequest]) {
        if requests.isEmpty && trackers.isEmpty { return }
        var occurrences: [String: Int] = [:]
        var live: Set<String> = []
        for request in requests {
            // The same line in a loop: tell them apart by order.
            let n = occurrences[request.site, default: 0]
            occurrences[request.site] = n + 1
            let key = "\(request.site)#\(n)"
            live.insert(key)
            let tracker = trackers[key] ?? AddProgressTracker()
            trackers[key] = tracker
            tracker.sync(request)
        }
        for (key, tracker) in trackers where !live.contains(key) {
            tracker.dispose()
            trackers[key] = nil
        }
        if trackers.isEmpty {
            removeListener?()
            removeListener = nil
        } else if removeListener == nil {
            removeListener = OverlayAddedListeners.add { [weak self] states in
                guard let self else { return }
                for tracker in self.trackers.values { tracker.arrived(states) }
            }
        }
    }

    deinit {
        removeListener?()
    }
}
