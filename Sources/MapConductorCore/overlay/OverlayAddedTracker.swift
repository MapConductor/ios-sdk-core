import Foundation

/**
 Which of a controller's overlays have reached the map, so that each state's
 `onAdded` is called once each time it goes from "not on the map" to "on the map".

 A controller keeps one and tells it three things:

 - ``retain(_:)`` at the start of every list sync, with the ids the app now
   has. Ids it no longer has are forgotten, so a later add calls `onAdded` again.
 - ``admit(_:)`` once an overlay is on the map: right after the renderer's
   `onAdd` returned its native object, or after the tile layer that holds it
   was handed to the map. It returns the states that were not on the map yet;
   pass them to ``notify(_:)``.
 - ``reset()`` on `clear`.

 An in-place change, a move between native drawing and tiles, or a native
 object rebuilt by the provider (a style reload) keeps the id here, so none
 of those calls `onAdded` again.

 The record is separate from the controller's entity manager on purpose:
 providers clear their manager on a style reload and re-create everything,
 which is not the app adding anything.
 */
@_spi(MapConductorDriver)
public final class OverlayAddedTracker {
    private let lock = NSLock()
    private var onMap: Set<String> = []

    public init() {}

    /// Forgets the overlays whose ids are not in `ids` (the app removed them).
    public func retain(_ ids: Set<String>) {
        lock.lock()
        defer { lock.unlock() }
        if onMap.isEmpty { return }
        onMap = onMap.filter { ids.contains($0) }
    }

    /// Forgets one overlay (removed by id).
    public func forget(_ id: String) {
        lock.lock()
        defer { lock.unlock() }
        onMap.remove(id)
    }

    /// Records `states` as on the map and returns those that were not.
    public func admit<S: Identifiable>(_ states: [S]) -> [S] where S.ID == String {
        if states.isEmpty { return [] }
        lock.lock()
        defer { lock.unlock() }
        var fresh: [S] = []
        for state in states where onMap.insert(state.id).inserted {
            fresh.append(state)
        }
        return fresh
    }

    public func contains(_ id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return onMap.contains(id)
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        onMap.removeAll()
    }

    /// Calls `onAdded` of each state on the main actor, in order.
    ///
    /// Swift handlers cannot throw, so one handler cannot stop the others the
    /// way an exception could on Android or the web.
    public static func notify<S: OverlayAddedNotifying>(_ states: [S]) async {
        if states.isEmpty { return }
        let listening = OverlayAddedListeners.isActive
        // Skip the hop when nobody listens (the common case with markers).
        guard listening || states.contains(where: { $0.hasOnAdded }) else { return }
        await MainActor.run {
            if listening { OverlayAddedListeners.notify(states.map { $0 as AnyObject }) }
            for state in states { state.callOnAdded() }
        }
    }

    /// ``admit(_:)`` then ``notify(_:)``.
    public func admitAndNotify<S: OverlayAddedNotifying>(_ states: [S]) async where S.ID == String {
        await Self.notify(admit(states))
    }
}

/// Hears every batch of states ``OverlayAddedTracker/notify(_:)`` reports, on the
/// main actor, before their `onAdded` calls. For the framework layer (the
/// collections count their own states with it), not for apps.
@_spi(MapConductorDriver)
public enum OverlayAddedListeners {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var listeners: [UUID: @MainActor ([AnyObject]) -> Void] = [:]

    static var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !listeners.isEmpty
    }

    /// Adds `listener`; call the returned function (from any thread) to remove it.
    public static func add(_ listener: @escaping @MainActor ([AnyObject]) -> Void) -> () -> Void {
        let key = UUID()
        lock.lock()
        listeners[key] = listener
        lock.unlock()
        return {
            lock.lock()
            listeners[key] = nil
            lock.unlock()
        }
    }

    @MainActor
    static func notify(_ states: [AnyObject]) {
        lock.lock()
        let current = Array(listeners.values)
        lock.unlock()
        for listener in current { listener(states) }
    }
}

/// An overlay state with an `onAdded` handler. Lets ``OverlayAddedTracker``
/// call it without knowing the overlay type.
@_spi(MapConductorDriver)
public protocol OverlayAddedNotifying: Identifiable {
    var hasOnAdded: Bool { get }
    func callOnAdded()
}

@_spi(MapConductorDriver)
extension MarkerState: OverlayAddedNotifying {
    public var hasOnAdded: Bool { onAdded != nil }
    public func callOnAdded() { onAdded?(self) }
}

@_spi(MapConductorDriver)
extension CircleState: OverlayAddedNotifying {
    public var hasOnAdded: Bool { onAdded != nil }
    public func callOnAdded() { onAdded?(self) }
}

@_spi(MapConductorDriver)
extension PolylineState: OverlayAddedNotifying {
    public var hasOnAdded: Bool { onAdded != nil }
    public func callOnAdded() { onAdded?(self) }
}

@_spi(MapConductorDriver)
extension PolygonState: OverlayAddedNotifying {
    public var hasOnAdded: Bool { onAdded != nil }
    public func callOnAdded() { onAdded?(self) }
}

@_spi(MapConductorDriver)
extension GroundImageState: OverlayAddedNotifying {
    public var hasOnAdded: Bool { onAdded != nil }
    public func callOnAdded() { onAdded?(self) }
}

@_spi(MapConductorDriver)
extension RasterLayerState: OverlayAddedNotifying {
    public var hasOnAdded: Bool { onAdded != nil }
    public func callOnAdded() { onAdded?(self) }
}
