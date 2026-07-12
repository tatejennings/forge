# AGENTS.md

Instructions for AI coding agents (Cursor, Aider, Codex CLI, Sourcegraph Cody, etc.) working in a Swift project that uses the [Forge](https://github.com/tatejennings/Forge) dependency injection framework.

> Using Claude Code? Install the dedicated plugin for richer, context-aware support:
> `/plugin marketplace add tatejennings/Forge` then `/plugin install forge@forge-plugins`.

---

## What Forge is

Forge is a lightweight DI framework for Swift — compile-time-safe at the call site (KeyPaths + inferred types), with loud, fail-fast runtime checks underneath. Registration is a computed property on a `Container` subclass; injection is a `@Inject(\.keyPath)` property wrapper. No code generation. No reflection. No build phases.

```swift
import Forge

extension AppContainer {
    var authService: any AuthServiceProtocol {
        provide(.singleton) { AuthService(network: self.networkClient) }
    }
}

@Observable
final class LoginViewModel {
    @ObservationIgnored
    @Inject(\.authService) private var authService
}
```

## Which path am I in? (decide this first)

Forge projects follow one of two paths. **Detect the path from the code before writing any — don't guess from the target count alone.**

- **Modular** if ANY of these are present: a custom `final class XContainer: Container, SharedContainer`; a module-local `typealias Inject<T> = ContainerInject<XContainer, T>`; `unimplemented(...)` factories; or composition-root wiring (`XContainer.shared.override(\.y) { … }`). A Modular app *also* extends `AppContainer` (as its composition root holding the live implementations) — so seeing an `AppContainer` extension does **not** mean Simple.
- **Simple** if the ONLY registration site is `extension AppContainer { … }`, injection uses the built-in `@Inject(\.x)`, and there are **no** custom `Container` subclasses, **no** module-local `Inject` typealias, and **no** `unimplemented()`.
- **Starting fresh?** Single target → Simple. Multi-module SPM → Modular (see "Modular apps" below).
- **Never mix:** `unimplemented()` and composition-root wiring are **Modular-only**. In a Simple app, register the real implementation directly.

## Non-negotiable rules

1. **Always return a protocol type from `provide`.** Concrete types cannot be overridden in tests or previews.
2. **One container per module.** An `AuthContainer` registers auth deps, not analytics.
3. **Feature modules never import other feature modules.** Use protocol modules and cross-module proxies (see "Modular apps" below).

## Scope selection

| Scope | Behavior | Use when |
|---|---|---|
| `.transient` (default) | New instance per resolution | Stateless services, per-screen ViewModels |
| `.singleton` | One instance for container lifetime | Network clients, databases, analytics |
| `.cached` | One instance until `resetCached()` | ViewModels that survive nav but can be refreshed |

`provide { ... }` and `provide(.transient) { ... }` are equivalent.

## Injection sites

- **Classes (ViewModels, services):** `@Inject(\.x)` works directly. Uses `mutating get` for lazy resolution.
- **SwiftUI Views:** `@Inject` doesn't work — Views are value types. Use `@State` with direct resolution:
  ```swift
  struct LoginView: View {
      @State private var viewModel = AppContainer.shared.loginViewModel
  }
  ```

## Preview support

Add a `preview:` factory to swap dependencies automatically inside `#Preview`:
```swift
var authService: any AuthServiceProtocol {
    provide(.singleton) { AuthService(network: self.networkClient) } preview: { MockAuthService() }
}
```
Add a preview factory for services that hit the network, disk, or other side effects. Skip for pure value-producing services.

## Testing

Use `withOverrides` — overrides are scoped to the closure and restored automatically, even on throw:

```swift
@Test("Login calls auth service")
func loginCallsService() async throws {
    let mock = MockAuthService(shouldSucceed: true)

    try await AppContainer.shared.withOverrides {
        $0.override(\.authService) { mock }
    } run: {
        let viewModel = LoginViewModel()
        await viewModel.login(username: "user", password: "pass")
        #expect(mock.loginCalled)
    }
}
```

Never mutate `Container.shared` directly in test bodies — it persists across tests and causes order-dependent failures.

Reset helpers:
- `resetCached()` — clears `.cached` values only.
- `resetAll()` — clears all overrides AND all cached/singleton values.

## `unimplemented` — explicit contracts (Modular-only)

`unimplemented(_:)` returns a value that crashes immediately if resolved. It exists for cross-module proxies in the Modular path — dependencies a feature module declares but cannot construct, which the app target wires at startup:

```swift
// In FeatureSearch — analytics is wired by the app target
var analytics: any AnalyticsProtocol {
    provide(.singleton) { unimplemented("analytics") } preview: { MockAnalytics() }
}
```

**Do not use `unimplemented()` in a Simple (single-`AppContainer`) app** — there is no other module to wire it from. Register the real implementation directly.

## Modular apps

For multi-module SPM workspaces, the pattern is:

1. **Per-module container** with `SharedContainer` and a local `Inject` typealias:
   ```swift
   typealias Inject<T> = ContainerInject<AuthContainer, T>

   final class AuthContainer: Container, SharedContainer {
       static let shared = AuthContainer()
       var authService: any AuthServiceProtocol {
           provide(.singleton) { AuthService() }
       }
   }
   ```

2. **Cross-module deps use `unimplemented` proxies** — feature modules declare the dep but don't import the implementation module.

3. **App target wires real implementations at launch** from a dedicated
   `CompositionRoot.swift` — a standalone `wireContainers()` function (NOT a method on
   `AppContainer`), called once from `App.init()`. Read each real from the module
   container that owns it:
   ```swift
   // CompositionRoot.swift (app target)
   func wireContainers() {
       let analytics = CoreAnalyticsContainer.shared.analytics  // owned by its module
       SearchContainer.shared.override(\.analytics) { analytics }
   }
   ```
   `AppContainer` is **optional** in a modular app — reals live in their owning module's
   container, so a thin app target never extends `AppContainer`. Use it only for genuine
   target-level services the app itself owns (register them in the same file under a
   `// MARK: - Target-level services` section).

Protocols live in a small `*Protocols` module that everyone can import without pulling in implementations.

### Consuming a module container from the app target

A module's local `Inject` typealias is internal to that module, so at the app target the bare `@Inject(\.x)` resolves only from `AppContainer`. To use a feature container's dependency from app-target code, don't fall back to `SomeContainer.shared.x` — use the property wrapper's explicit-container form (fully type-inferred):

```swift
final class RootCoordinator {
    @ContainerInject(TaskContainer.shared, \.taskService) private var taskService
}
```

For repeated use, declare a per-container typealias at the app target: `typealias TasksInject<T> = ContainerInject<TaskContainer, T>`. This is not a layering violation — the app target already imports every module. Bare `@Inject` stays single-container by design (cross-container resolution would be a service locator); prefer registering app-level needs on `AppContainer`.

## Common mistakes to avoid

- **Concrete return type on `provide`** — breaks override / mock substitution.
- **`.singleton` on a per-screen ViewModel** — state leaks across navigations. Use `.transient` or `.cached`.
- **Direct `.shared.override` in tests** without cleanup — use `withOverrides`.
- **Cross-module dep with `provide { Real() }` instead of `unimplemented`** — either won't compile, or silently runs the wrong code.
- **`unimplemented()` or composition-root wiring in a Simple app** — these are Modular-only. In a single-`AppContainer` app, register the real implementation directly.
- **`@Inject` in a SwiftUI View** — Views are value types; use `@State` + direct resolution.
- **Feature module importing another feature module's implementation** — use protocol modules + cross-module proxies.

## What Forge does NOT support

Do not propose or expect:
- Weak-reference or TTL-based scopes
- Named/tagged registrations
- Decorator or middleware hooks
- Circular dependency detection
- Auto-wiring or reflection-based resolution
- Codegen or build phases

Forge is intentionally minimal. If a feature request implies one of these, suggest a manual pattern instead.

## Quick API reference

| Type / function | Purpose |
|---|---|
| `AppContainer` | Built-in ready-to-use container. Extend it with your dependencies. |
| `Container` | Base class. Subclass and add computed properties. |
| `SharedContainer` | Protocol that adds a stable `static let shared` instance (requirement is `{ get }`). |
| `@Inject(\.x)` | Property wrapper for lazy injection (classes only). |
| `ContainerInject<C, T>` | Underlying type — aliased per module via `typealias Inject<T> = ContainerInject<MyContainer, T>`. |
| `Scope` | Enum: `.transient`, `.singleton`, `.cached`. |
| `provide(_:_:preview:)` | Register / resolve a dependency. |
| `withOverrides(_:run:)` | Scoped overrides for tests. Sync + async variants. |
| `override(\.x) { ... }` | Add a single override. Use inside `withOverrides` builders. First registration per KeyPath runs the factory once (key-discovery probe; value discarded). Target getter must call provide(...) with its own type or it traps; a same-type alias resolves to its backing registration. |
| `unimplemented(_:)` | Returns a value that crashes if resolved. For explicit test/wiring contracts. |
| `resetCached()` | Clear `.cached` values. |
| `resetAll()` | Clear all overrides + cached/singleton values. |
