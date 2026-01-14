# MapConductor Core module

MapConductor provides a unified API for multiple mobile map SDKs.

## Overview

MapConductor iOS Core provides the core abstraction layer for building
declarative and provider-independent map SDKs on iOS.

It encapsulates map-related domain logic such as coordinate models,
camera semantics, map state, and interaction behaviors, while remaining
completely independent from rendering, UI frameworks, and concrete map SDKs.

This separation allows higher-level layers (SwiftUI bindings, UIKit views,
or specific map SDK drivers) to share a consistent conceptual model
without being coupled to a particular map provider.

## What this module does

MapConductor iOS Core defines the provider-agnostic core logic of the
MapConductor SDK.

Specifically, this module is responsible for:

- Defining shared domain models such as coordinates, camera state,
  map objects, and interaction semantics
- Providing abstract state and behavior that represent map operations
  independently of any concrete map SDK
- Serving as the contract between higher-level APIs and
  provider-specific driver implementations

All logic in this module is designed to be reusable across different
map providers and UI frameworks.

## What this module does NOT do

To keep responsibilities clear, this core module intentionally does NOT:

- Render maps or map objects
- Depend on MapKit, Mapbox, ArcGIS, or any other map SDK
- Provide SwiftUI or UIKit views
- Handle platform-specific lifecycle or view management
- Make assumptions about how maps are displayed or rendered

Those concerns are handled by higher-level modules and
provider-specific driver implementations built on top of this core.

## Architecture

MapConductor follows a layered architecture that separates
map semantics from rendering and provider-specific behavior.

┌────────────────────────────────────────────┐
│ Application / App Logic                    │
├────────────────────────────────────────────┤
│ MapConductor Unified API (SwiftUI)         │
│  - SwiftUI bindings / composables          │
│  - MapView integration & event bridging    │
├────────────────────────────────────────────┤
│ MapConductor iOS Core                      │
│  - Domain models                           │
│  - State & behavior                        │
│  - Provider-agnostic logic                 │
├────────────────────────────────────────────┤
│ Provider Drivers (Adapters)                │
│  - MapKit driver                           │
│  - Google Maps driver                      │
│  - MapLibre driver                         │
├────────────────────────────────────────────┤
│ Concrete Map SDKs (Vendor SDKs)            │
└────────────────────────────────────────────┘

The unified API is currently expressed primarily through SwiftUI bindings,
but the underlying semantics are not tied to any specific UI framework.
Provider-specific differences are isolated in driver modules,
while the core module defines provider-agnostic semantics and state.

## Design philosophy

MapConductor iOS Core is designed around the idea that
*map behavior and meaning should be independent of map providers*.

By modeling map concepts at an abstract level, this module enables:

- Consistent application logic across different map SDKs
- Lower switching cost between providers
- Shared knowledge and mental models among developers

This approach avoids a "lowest common denominator" API
and instead models map capabilities in a way that preserves
the expressive power of each provider where possible.

## Who should use or care about this module

This module is primarily intended for:

- Developers implementing MapConductor drivers for specific map SDKs
- Contributors working on the internal architecture of MapConductor
- Developers who want to understand the conceptual model behind the SDK

If you are simply using MapConductor in an application,
you usually do not need to interact with this module directly.
