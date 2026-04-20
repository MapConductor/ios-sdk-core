# Types

Common type aliases and Kotlin-compatibility shims used throughout the SDK.

---

# Long

A type alias for `Int64`, matching the Kotlin `Long` type used in the shared cross-platform API.

## Signature

```swift
public typealias Long = Int64
```

---

# CoroutineScope

A Kotlin-compatibility shim. In Kotlin multiplatform code, `CoroutineScope` controls the
lifecycle of coroutines. On iOS this class is a no-op placeholder that satisfies type constraints
in shared interfaces.

## Signature

```swift
public final class CoroutineScope {
    public init()
}
```
