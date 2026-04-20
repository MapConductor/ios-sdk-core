# MarkerState

State object controlling a single map marker. Conforms to `ObservableObject` — changes to
published properties automatically update the marker on the map.

---

# MarkerAnimation

An enum describing marker drop or bounce animations.

## Signature

```swift
public enum MarkerAnimation {
    case Drop
    case Bounce
}
```

---

# OnMarkerEventHandler

A type alias for the closure called on marker events (tap, drag).

## Signature

```swift
public typealias OnMarkerEventHandler = (MarkerState) -> Void
```

---

# MarkerFingerPrint

A value-type snapshot of a `MarkerState` used for change detection.

## Signature

```swift
public struct MarkerFingerPrint: Equatable, Hashable {
    public let id: Int
    public let icon: Int?
    public let clickable: Int
    public let draggable: Int
    public let latitude: Int
    public let longitude: Int
    public let animation: Int?
}
```

---

# MarkerState

## Signature

```swift
public final class MarkerState: ObservableObject, Identifiable, Equatable, Hashable {
    public let id: String
    public var extra: Any?

    @Published public var icon: (any MarkerIconProtocol)?
    @Published public var clickable: Bool
    @Published public var draggable: Bool
    @Published public var position: GeoPoint
    @Published public var onClick: OnMarkerEventHandler?
    @Published public var onDragStart: OnMarkerEventHandler?
    @Published public var onDrag: OnMarkerEventHandler?
    @Published public var onDragEnd: OnMarkerEventHandler?
    @Published public var onAnimateStart: OnMarkerEventHandler?
    @Published public var onAnimateEnd: OnMarkerEventHandler?

    public init(
        position: GeoPoint,
        id: String? = nil,
        extra: Any? = nil,
        icon: (any MarkerIconProtocol)? = nil,
        animation: MarkerAnimation? = nil,
        clickable: Bool = true,
        draggable: Bool = false,
        onClick: OnMarkerEventHandler? = nil,
        onDragStart: OnMarkerEventHandler? = nil,
        onDrag: OnMarkerEventHandler? = nil,
        onDragEnd: OnMarkerEventHandler? = nil,
        onAnimateStart: OnMarkerEventHandler? = nil,
        onAnimateEnd: OnMarkerEventHandler? = nil
    )

    public convenience init(
        position: GeoPoint,
        id: String? = nil,
        extra: Any? = nil,
        icon: DefaultMarkerIcon,
        animation: MarkerAnimation? = nil,
        clickable: Bool = true,
        draggable: Bool = false,
        onClick: OnMarkerEventHandler? = nil,
        onDragStart: OnMarkerEventHandler? = nil,
        onDrag: OnMarkerEventHandler? = nil,
        onDragEnd: OnMarkerEventHandler? = nil,
        onAnimateStart: OnMarkerEventHandler? = nil,
        onAnimateEnd: OnMarkerEventHandler? = nil
    )
}
```

## Constructor Parameters

- `position`
    - Type: `GeoPoint`
    - Description: The marker's geographic position.
- `id`
    - Type: `String?`
    - Default: `nil`
    - Description: Stable identifier. Auto-generated from content hash if `nil`.
- `extra`
    - Type: `Any?`
    - Default: `nil`
    - Description: Arbitrary user data attached to the marker.
- `icon`
    - Type: `(any MarkerIconProtocol)?`
    - Default: `nil`
    - Description: Custom marker icon. Uses `DefaultMarkerIcon` if `nil`.
- `animation`
    - Type: `MarkerAnimation?`
    - Default: `nil`
    - Description: Initial animation to play when the marker appears.
- `clickable`
    - Type: `Bool`
    - Default: `true`
    - Description: Whether tapping the marker fires `onClick`.
- `draggable`
    - Type: `Bool`
    - Default: `false`
    - Description: Whether the user can drag the marker.
- `onClick` / `onDragStart` / `onDrag` / `onDragEnd` / `onAnimateStart` / `onAnimateEnd`
    - Type: `OnMarkerEventHandler?`
    - Default: `nil`
    - Description: Event handlers for the respective user actions.

## Methods

### `animate(_:)`

Triggers a drop or bounce animation on the marker.

```swift
public func animate(_ animation: MarkerAnimation?)
```

### `getAnimation()`

Returns the current pending animation, if any.

```swift
public func getAnimation() -> MarkerAnimation?
```

### `copy(...)`

Returns a new `MarkerState` with any of the given values overriding the current ones.

```swift
public func copy(
    id: String? = nil,
    position: GeoPoint? = nil,
    extra: Any? = nil,
    icon: (any MarkerIconProtocol)? = nil,
    clickable: Bool? = nil,
    draggable: Bool? = nil,
    onClick: OnMarkerEventHandler? = nil,
    onDragStart: OnMarkerEventHandler? = nil,
    onDrag: OnMarkerEventHandler? = nil,
    onDragEnd: OnMarkerEventHandler? = nil,
    onAnimateStart: OnMarkerEventHandler? = nil,
    onAnimateEnd: OnMarkerEventHandler? = nil
) -> MarkerState
```

### `fingerPrint()`

Returns a `MarkerFingerPrint` snapshot for change detection.

```swift
public func fingerPrint() -> MarkerFingerPrint
```

### `asFlow()`

Returns an `AnyPublisher<MarkerFingerPrint, Never>` that emits when any relevant property changes.

```swift
public func asFlow() -> AnyPublisher<MarkerFingerPrint, Never>
```

## Example

```swift
let marker = MarkerState(
    position: GeoPoint(latitude: 35.6812, longitude: 139.7671),
    icon: BitmapIcon(bitmap: UIImage(named: "pin")!),
    onClick: { state in
        print("Tapped marker: \(state.id)")
    }
)
marker.animate(.Drop)
```
