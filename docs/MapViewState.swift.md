# MapViewState

Base class and protocol for map view state objects. Each map SDK integration provides a concrete
subclass (`GoogleMapViewState`, `MapboxViewState`, etc.).

---

# InitState

An enum describing the initialization phase of a map view state.

## Signature

```swift
public enum InitState {
    case NotStarted
    case Initializing
    case SdkInitialized
    case MapViewCreated
    case MapCreated
    case Failed
}
```

---

# MapViewStateProtocol

A protocol that all map view state types must implement.

## Signature

```swift
public protocol MapViewStateProtocol: ObservableObject {
    associatedtype ActualMapDesignType

    var id: String { get }
    var cameraPosition: MapCameraPosition { get }
    var mapDesignType: ActualMapDesignType { get set }

    func moveCameraTo(cameraPosition: MapCameraPosition, durationMillis: Long?)
    func moveCameraTo(position: GeoPoint, durationMillis: Long?)
    func getMapViewHolder() -> AnyMapViewHolder?
}
```

## Extension (default implementations)

```swift
public extension MapViewStateProtocol {
    func moveCameraTo(cameraPosition: MapCameraPosition)  // durationMillis = 0
    func moveCameraTo(position: GeoPoint)                 // durationMillis = 0
}
```

---

# MapViewState

An open `ObservableObject` base class for map view state. Subclassed by each map SDK integration.
All properties and methods call `fatalError` and must be overridden.

## Signature

```swift
open class MapViewState<ActualMapDesignType>: ObservableObject, MapViewStateProtocol {
    public init()

    open var id: String { get }
    open var cameraPosition: MapCameraPosition { get }
    open var mapDesignType: ActualMapDesignType { get set }

    open func moveCameraTo(cameraPosition: MapCameraPosition, durationMillis: Long?)
    open func moveCameraTo(position: GeoPoint, durationMillis: Long?)
    open func getMapViewHolder() -> AnyMapViewHolder?
}
```

## Methods

### `moveCameraTo(cameraPosition:durationMillis:)`

```swift
open func moveCameraTo(cameraPosition: MapCameraPosition, durationMillis: Long?)
```

### `moveCameraTo(position:durationMillis:)`

```swift
open func moveCameraTo(position: GeoPoint, durationMillis: Long?)
```

**Parameters (shared)**

- `durationMillis`
    - Type: `Long?`
    - Description: Animation duration in milliseconds. `0` or `nil` moves the camera instantly.
