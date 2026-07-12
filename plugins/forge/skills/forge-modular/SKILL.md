---
name: forge-modular
description: Use when working in a multi-module SPM workspace or Xcode project that uses Forge, or when editing a per-module Container or the app target's composition root. Covers per-module containers, cross-module dependency proxying with unimplemented(), and the composition-root wiring pattern.
---

# Forge Modular Architecture

**First, confirm this project is actually Modular** (see the decision rule in the `using-forge` skill): there must be custom per-module containers, module-local `Inject` typealiases, `unimplemented()` proxies, or composition-root wiring. If the only registration site is `extension AppContainer { … }` with no custom containers, this is a **Simple** app — stop and use `using-forge` instead. Do not introduce the machinery below into a Simple app.

The core rule: **feature modules never import other feature modules.** They import protocol modules. The app target is the only composition root — the only place that imports concrete modules and wires them together.

## Per-module container

Each feature module owns one `Container` subclass with the `SharedContainer` protocol and a local `Inject` typealias:

```swift
// In FeatureAuth module
import Forge

typealias Inject<T> = ContainerInject<AuthContainer, T>

final class AuthContainer: Container, SharedContainer {
    static let shared = AuthContainer()

    var authService: any AuthServiceProtocol {
        provide(.singleton) { AuthService(network: self.networkClient) }
    }

    var networkClient: any NetworkClientProtocol {
        provide(.singleton) { URLSessionNetworkClient() }
    }
}
```

The local `typealias` shadows Forge's framework-level `Inject` so `@Inject(\.authService)` resolves from `AuthContainer.shared`.

## Cross-module dependencies — use `unimplemented` proxies

When a feature module depends on something it can't construct (e.g., analytics, logged-in user, feature flags), declare the dependency in the module's container with `unimplemented(...)` as the default factory:

```swift
// In FeatureSearch — depends on analytics, but FeatureSearch does NOT import FeatureAnalytics
final class SearchContainer: Container, SharedContainer {
    static let shared = SearchContainer()

    // Wired by the app target at startup
    var analytics: any AnalyticsProtocol {
        provide(.singleton) { unimplemented("analytics") } preview: { MockAnalytics() }
    }

    var searchService: any SearchServiceProtocol {
        provide(.singleton) { SearchService(analytics: self.analytics) }
    }
}
```

Notice:
- The factory is `unimplemented("analytics")` — if the app forgets to wire it, the app crashes on first resolution with a clear message naming the missing dependency.
- A `preview:` factory provides a mock so previews still work.
- `FeatureSearch` does not import `FeatureAnalytics`. It only knows about `AnalyticsProtocol` (which lives in a small protocol module both can import).

## Composition root — the app target wires everything

Put the wiring in a **dedicated `CompositionRoot.swift`** in the app target — a
standalone `wireContainers()` function, **not** a method on `AppContainer`. It's the
only place that imports every module, and it's the only thing `App.init()` calls. It
reads each real service from the module container that owns it and `override`s the
matching `unimplemented()` proxy on each feature container:

```swift
// CompositionRoot.swift  (app target)
import Forge
import CoreServices      // owns the real implementations in its own container
import FeatureAuth
import FeatureSearch

// MARK: - Target-level services (OPTIONAL)
// Only if the app target itself owns dependencies that live in no module. Drop this
// whole section in a thin app target — then AppContainer never appears.
//
//   extension AppContainer {
//       var someAppService: any SomeProtocol { provide(.singleton) { SomeService() } }
//   }

// MARK: - Composition root — wire feature proxies once, at launch
func wireContainers() {
    let analytics = ServicesContainer.shared.analytics   // real impl, owned by its module
    SearchContainer.shared.override(\.analytics) { analytics }
    AuthContainer.shared.override(\.analytics)   { analytics }
}
```
```swift
@main
struct MyApp: App {
    init() { wireContainers() }            // the only call site
    var body: some Scene { ... }
}
```

Key rules:
- **Wiring is a standalone function, never a method on `AppContainer`.** Bolting it
  onto `AppContainer` makes the composition root read like the Simple path.
- **`AppContainer` is optional.** Reals belong in the module that owns them (a Core
  service module's own container). Use `AppContainer` only for genuine *target-level*
  services the app itself owns — a thin app target never touches it.
- **Wire from the owning container**, resolving the real once and capturing it (or
  read it through with `{ owner.x }`). Overrides are read-through and never cached.
- **Each wiring line runs its closure once at registration** — the first
  `override(\.x)` for a KeyPath evaluates the override factory as a key-discovery
  probe (never the proxy's `unimplemented()` factory, which stays untouched until
  an unwired resolution). Prefer the capture-first form shown above (`let x =
  owner.x` then `override(\.x) { x }`): a read-through closure (`{ owner.x }`)
  resolves the real eagerly at wiring time anyway, and hides it. If one real
  transitively depends on another container's proxy, wire that proxy first —
  wiring is order-sensitive for cross-dependent reals. Wiring is strip-safe: the
  key comes from the property's own `provide(...)` registration, not from parsing
  the KeyPath, so archived/TestFlight builds behave identically to Xcode runs
  (Forge >= 0.6.0; on older versions set `STRIP_STYLE = debugging` on the app
  target).

This keeps each feature module independently buildable (no cross-feature imports),
testable (override the proxy with a mock), and previewable (the `preview:` factory).

## Consuming a module container from the app target

Inside a feature module, `@Inject(\.x)` works because the module's local `typealias
Inject<T> = ContainerInject<XContainer, T>` is in scope. That typealias is internal
to the module, so **at the app target the bare `@Inject(\.x)` resolves only from
`AppContainer`** — it can't reach a feature container. You don't need
`SomeContainer.shared.dependency` to bridge that gap; use the property wrapper's
explicit-container form, which is fully type-inferred:

```swift
// App target — e.g. an app-level coordinator that needs a feature's service
final class RootCoordinator {
    @ContainerInject(TaskContainer.shared, \.taskService) private var taskService
}
```

For repeated use, define a per-container typealias at the app target (mirrors the
in-module idiom):

```swift
typealias TasksInject<T> = ContainerInject<TaskContainer, T>

@TasksInject(\.taskService) private var taskService
```

Both give the same lazy resolution, caching, and override-awareness as bare
`@Inject`. This is **not** a layering violation — the app target is the composition
root and already imports every module.

Guidance:
- **Bare `@Inject` is intentionally single-container.** Making `@Inject(\.x)`
  resolve across containers would require runtime cross-container lookup (a service
  locator), which Forge deliberately does not do. Don't try to add it — use the
  explicit-container form above.
- **Prefer `AppContainer` for app-level needs.** Reaching into a feature container
  from the composition root is fine occasionally. If app code consumes *many*
  feature internals, promote that dependency to `AppContainer` or a core module
  instead.

## Protocol modules

For the pattern to work, protocols must live in a module both the producer and consumer can import. Common shape:

```
Workspace/
├── AnalyticsProtocols/          # public protocol(s), no implementations
│   └── AnalyticsProtocol.swift
├── FeatureAnalytics/             # imports AnalyticsProtocols, implements
├── FeatureSearch/                # imports AnalyticsProtocols, NOT FeatureAnalytics
└── MyApp/                        # imports everything, composition root
```

`AnalyticsProtocols` has no Forge dependency — it's pure protocol declarations.

## Common mistakes

- **Feature module imports another feature module.** This is the cardinal sin. If you find yourself adding `import FeatureX` in `FeatureY`, you need a protocol module instead.
- **Composition root forgets to wire a proxy.** Caught by `unimplemented()` — but only at runtime. If you add a new cross-module proxy, immediately add the matching `override` in the app target. The `/forge:wire-modules` slash command helps.
- **Using `provide { ... }` without a default for a cross-module dep.** Without `unimplemented`, the factory will be called with no real implementation, often producing silent wrong behavior (a no-op analytics, an empty network client). Always wrap cross-module proxies in `unimplemented`.
- **Per-module container imports app-level types.** Containers should only know about their own module's protocols. Wiring lives in the app target, not in the module's container.

## Testing per-module containers

In a feature module's tests, override the proxies with mocks via `withOverrides` (see `forge-testing` skill). You can test the feature module fully isolated from the rest of the app.

```swift
try await SearchContainer.shared.withOverrides {
    $0.override(\.analytics) { MockAnalytics() }
} run: {
    let result = await SearchContainer.shared.searchService.search("query")
    #expect(result.count > 0)
}
```

## Related skills

- `using-forge` — registration and injection basics
- `forge-testing` — overriding in tests
- `forge-migration` — refactoring an existing modular app to Forge
