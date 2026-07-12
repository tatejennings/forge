# Modular Architecture

Organize dependency injection across multiple Swift Package Manager modules.

## Overview

In a modular codebase, each SPM module owns its own ``Container`` subclass. This
keeps dependency boundaries clean, makes modules independently testable, and
prevents accidental cross-module coupling.

## One Container per Module

Each module defines exactly one container that manages all dependencies for that
module. The container file includes the module-local typealias:

```swift
// FeatureAuth/Sources/AuthContainer.swift

import Forge
import CoreProtocols

typealias Inject<T> = ContainerInject<AuthContainer, T>

public final class AuthContainer: Container, SharedContainer {
    public static let shared = AuthContainer()

    public var authService: any AuthServiceProtocol {
        provide(.singleton) {
            AuthService(network: self.networkClient)
        } preview: {
            MockAuthService()
        }
    }

    public var networkClient: any NetworkClientProtocol {
        provide(.singleton) { URLSessionNetworkClient() }
    }
}
```

All `@Inject` usages within the module use the bare syntax — no container name visible:

```swift
// FeatureAuth/Sources/LoginViewModel.swift

final class LoginViewModel: ObservableObject {
    @Inject(\.authService) private var auth
}
```

## Cross-Module Proxying

Feature modules must not import other feature modules directly. If a module needs a
dependency owned by another module, it **proxies** the dependency through its own
container using ``unimplemented(_:file:line:)`` as the default factory. The app target
wires the real implementation at startup via ``OverridableContainer/override(_:with:)``:

```swift
// FeatureSearch/Sources/SearchContainer.swift

import Forge

public final class SearchContainer: Container, SharedContainer {
    public static let shared = SearchContainer()

    // Wired by the app target — crashes if not overridden
    public var analytics: any AnalyticsProtocol {
        provide(.singleton) {
            unimplemented("analytics")
        } preview: {
            MockAnalytics()
        }
    }

    public var searchService: any SearchServiceProtocol {
        provide(.singleton) {
            SearchService(analytics: self.analytics)
        }
    }
}
```

Using ``unimplemented(_:file:line:)`` here means that if the composition root forgets
to wire `analytics`, the app crashes on launch with a clear message instead of
silently running on mock data.

### Benefits of Proxying

- **Fail-fast safety** — ``unimplemented(_:file:line:)`` catches missing wiring immediately
- **Test isolation** — override `analytics` on `SearchContainer` directly, without
  touching another module's container
- **Clean dependency graph** — each module's DI surface is fully within its own container
- **Swappability** — if the analytics provider changes, only the override needs updating

## The Composition Root

The app target is the **composition root** — the only place where all modules are
imported and containers are wired together. Put the wiring in a dedicated
`CompositionRoot.swift` as a **standalone `wireContainers()` function** (not a method
on ``AppContainer``), and call it once from `App.init()`:

```swift
// App/Sources/CompositionRoot.swift

import Forge
import FeatureAuth
import FeatureSearch
import CoreAnalytics

// MARK: - Target-level services (OPTIONAL)
// Only if the app target itself owns dependencies that live in no module. A thin app
// target omits this entirely — then `AppContainer` never appears.
//
//   extension AppContainer {
//       var someAppService: any SomeProtocol { provide(.singleton) { SomeService() } }
//   }

// MARK: - Composition root — wire feature proxies once, at launch
func wireContainers() {
    // Wire each feature module's `unimplemented` proxy to the real implementation,
    // read from the module container that owns it. Containers are stable singletons —
    // wire with `override`, never by reassigning `shared`.
    let analytics = CoreAnalyticsContainer.shared.analytics
    SearchContainer.shared.override(\.analytics) { analytics }
}
```
```swift
// App/Sources/MyApp.swift
@main
struct MyApp: App {
    init() { wireContainers() }
    var body: some Scene { WindowGroup { RootView() } }
}
```

> Note: The first `override(\.x)` for a KeyPath runs its closure once at
> registration (key discovery), so wiring closures execute during
> `wireContainers()` — prefer the capture-first form shown above
> (`let analytics = …` then `override(\.analytics) { analytics }`) over a
> read-through closure, which would resolve the real at wiring time anyway,
> just less visibly. If one real transitively depends on another container's
> proxy, wire that proxy on an earlier line: wiring is order-sensitive for
> cross-dependent reals. The target must be a provide-backed property of the
> same type; see ``OverridableContainer/override(_:with:)`` for the full
> discovery rules.

> Important: The real implementations live in the module that owns them (here,
> `CoreAnalytics`'s own container) — not on ``AppContainer``. ``AppContainer`` is
> **optional** in a modular app: use it only for genuine *target-level* services the
> app itself owns. A thin app target whose modules own everything never touches it.
> And keep the wiring a free function — making it a method on ``AppContainer`` makes
> the composition root read like the Simple path.

## Consuming a Module Container from the App Target

Inside a feature module, `@Inject(\.x)` works because the module's local
``Inject`` typealias (`typealias Inject<T> = ContainerInject<XContainer, T>`) is in
scope. That typealias is internal to the module, so **at the app target the bare
`@Inject(\.x)` resolves only from ``AppContainer``** — it cannot reach a feature
container.

You do not need `SomeContainer.shared.dependency` to bridge that gap. Use
``ContainerInject``'s explicit-container initializer, which is fully type-inferred:

```swift
// App target — e.g. an app-level coordinator that needs a feature's service
final class RootCoordinator {
    @ContainerInject(TaskContainer.shared, \.taskService) private var taskService
}
```

For repeated use, declare a per-container typealias at the app target, mirroring the
in-module idiom:

```swift
typealias TasksInject<T> = ContainerInject<TaskContainer, T>

@TasksInject(\.taskService) private var taskService
```

Both forms give the same lazy resolution, caching, and override-awareness as the
bare ``Inject``. This is **not** a layering violation — the app target is the
composition root and already imports every module.

> Note: The bare ``Inject`` is intentionally bound to a single container. Resolving
> `@Inject(\.x)` across containers would require runtime cross-container lookup
> (a service locator), which Forge does not do — the fixed-container typealias is
> what makes resolution compile-time-safe. Prefer registering app-level needs on
> ``AppContainer``; reach into a feature container only when the app genuinely needs
> something that feature owns.

## Import Dependency Graph

The correct architecture follows this pattern:

```
CoreProtocols (protocols only — no Forge import)
       ^
       |
  Feature modules (each has its own Container)
       ^
       |
  App target (imports all modules, wires containers)
```

**Key rules:**

1. Protocol modules define abstractions only — no Forge dependency needed
2. Feature modules import protocol modules and Forge
3. ViewModels and services never `import` a concrete service module directly
4. The app target is the only place that imports both protocol and concrete modules

## Best Practices

- Keep containers **module-scoped** — if a container grows beyond its module's
  concerns, the module has too many responsibilities
- Make dependency properties **public** — they are the module's DI surface
- Use **protocol return types** on all dependency properties
- Proxy cross-module dependencies rather than importing other feature modules
