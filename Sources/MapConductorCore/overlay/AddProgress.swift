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
    /// The list's state objects and a way to their ids. Walks the whole list;
    /// called only when the list changed. Holds the list, so its storage
    /// cannot be reused while ``identity`` is remembered.
    let list: () -> AddProgressList
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
        list = { AddProgressList(objects: states.map { $0 as AnyObject }, id: { states[$0].id }) }
    }
}

/// A collection's list as ``AddProgressTracker`` compares it with the last one.
struct AddProgressList {
    static let empty = AddProgressList(objects: [], id: { _ in "" })

    let objects: [AnyObject]
    /// The id of `objects[i]`.
    let id: (Int) -> String
}

/// The states one collection handed over and how many of them are on the map.
@MainActor
final class AddProgressTracker {
    private static let progressInterval: TimeInterval = 0.1

    private var callbacks = AddProgressCallbacks()
    private var last: AddProgressRequest?
    private var lastList = AddProgressList.empty
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
        let next = request.list()
        let previous = lastList
        lastList = next
        let hadStates = !previous.objects.isEmpty
        if next.objects.isEmpty && !hadStates { return }
        let change = Self.compare(next, previous)
        // States the list brought: not in the last list, not even as another
        // object with the same id (that is an update).
        let fresh: [(id: String, state: AnyObject)] = change.added.compactMap { i in
            let id = next.id(i)
            return change.removedIds.contains(id) ? nil : (id: id, state: next.objects[i])
        }
        if !pending.isEmpty, !change.removed.isEmpty {
            // A state still coming that left the list no longer counts; one handed
            // over again as a new object with the same id is followed by that
            // object, which is the one the map reports.
            var replacement: [String: AnyObject] = [:]
            if fresh.isEmpty {
                for i in change.added { replacement[next.id(i)] = next.objects[i] }
            }
            let before = pending.count
            var kept: [ObjectIdentifier: (id: String, state: AnyObject)] = [:]
            for (key, entry) in pending {
                if !change.removed.contains(key) {
                    kept[key] = entry
                } else if change.addedIds.contains(entry.id) {
                    let state = replacement[entry.id] ?? entry.state
                    kept[ObjectIdentifier(state)] = (id: entry.id, state: state)
                }
            }
            pending = kept
            total -= before - pending.count
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

    /// How `next` differs from `previous`, by identity: which of `next` are new
    /// objects (`added`, their indices), which objects of `previous` left
    /// (`removed`), and the ids of each. A list changes by a filter or by new
    /// states far more often than by reordering, so the two are walked side by
    /// side, and nothing is hashed for the states that line up: a filter over
    /// 723,800 circles built two sets of ids for 0.5 to 0.8 s on the main thread.
    ///
    /// Past the 64 states ahead, the walk scans on to the end of `previous`, until
    /// it has scanned as many states as `previous` has; then it looks objects up
    /// in an index of `previous` instead. New states spread through the list (a
    /// carrier that comes back, its cells all over the list) each scanned to the
    /// end, and held the main thread for 3 to 10 s over 723,800 circles.
    ///
    /// The scan can take an object that is further on in `previous` for a new
    /// one; that object then shows as removed too, with the same id, and the id
    /// comparison below sorts it out. Only the speed depends on the walk.
    private static func compare(_ next: AddProgressList, _ previous: AddProgressList) -> (
        added: [Int], addedIds: Set<String>, removed: Set<ObjectIdentifier>, removedIds: Set<String>
    ) {
        let old = previous.objects
        var matched = [Bool](repeating: false, count: old.count)
        var added: [Int] = []
        var cursor = 0
        // Where a scan to the end last found nothing: objects missing there are
        // taken as new without scanning again (a run of new states).
        var exhaustedAt = -1
        var scanned = 0
        var index: [ObjectIdentifier: Int]?
        for (i, object) in next.objects.enumerated() {
            var k = cursor
            let near = min(old.count, cursor + 64)
            while k < near, old[k] !== object { k += 1 }
            if k == near {
                // Past a run of removed states, or a new one.
                guard exhaustedAt != cursor else {
                    added.append(i)
                    continue
                }
                if index == nil, scanned < old.count {
                    let start = k
                    while k < old.count, old[k] !== object { k += 1 }
                    scanned += k - start
                    if k == old.count { exhaustedAt = cursor }
                } else {
                    if index == nil {
                        index = Dictionary(old.indices.map { (ObjectIdentifier(old[$0]), $0) }, uniquingKeysWith: { a, _ in a })
                    }
                    k = index?[ObjectIdentifier(object)] ?? old.count
                    if k < old.count, matched[k] { k = old.count }
                }
                if k == old.count {
                    added.append(i)
                    continue
                }
            }
            matched[k] = true
            cursor = max(cursor, k + 1)
        }
        var removed: Set<ObjectIdentifier> = []
        var removedIds: Set<String> = []
        for (p, object) in old.enumerated() where !matched[p] {
            removed.insert(ObjectIdentifier(object))
            // Only a new object can share an id with one that left.
            if !added.isEmpty { removedIds.insert(previous.id(p)) }
        }
        let addedIds = removed.isEmpty ? [] : Set(added.map(next.id))
        return (added, addedIds, removed, removedIds)
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
        let due = DispatchTime.now() + settleDelay
        DispatchQueue.main.asyncAfter(deadline: due) { [weak self] in
            guard let self, self.settleToken == token else { return }
            // Late because the main thread was held: the hand-over that held it
            // may have queued the work that keeps the map busy, so give that
            // work the whole delay to show up.
            if DispatchTime.now().uptimeNanoseconds > due.uptimeNanoseconds + 100_000_000 {
                self.scheduleSettle()
                return
            }
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
