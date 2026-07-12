---
name: forge-testing
description: Use when writing or editing Swift tests (XCTest or Swift Testing) that involve Forge — files under Tests/ that reference @Inject, Container, withOverrides, override(\.x), unimplemented, resetAll, or resetCached. Covers Forge's testing patterns for swapping dependencies safely.
---

# Forge Testing Patterns

Forge gives you scoped overrides via `withOverrides`. The overrides apply only inside the closure; cleanup is automatic, even if the closure throws.

## The default pattern: `withOverrides`

```swift
@Test("Login calls auth service")
func loginCallsAuthService() async throws {
    let mock = MockAuthService(shouldSucceed: true)

    try await AppContainer.shared.withOverrides {
        $0.override(\.authService) { mock }
    } run: {
        let viewModel = LoginViewModel()
        await viewModel.login(username: "user", password: "pass")
        #expect(mock.loginCalled)
    }
    // Overrides are automatically restored here.
}
```

**Rules:**
- Always prefer `withOverrides` over mutating the container directly. Direct mutation persists across tests and causes order-dependent failures.
- Each `override(\.keyPath)` call inside the builder swaps one dependency.
- The closure can be sync or async; pick the matching `withOverrides` overload.

## Single override, no builder

For one override, you can call `override(\.x)` on the container directly — but you MUST pair it with cleanup. `withOverrides` does the cleanup for you, so prefer it. Reach for raw `override` only in narrow setup/teardown blocks (e.g. `XCTestCase.setUp` paired with `tearDown`).

## `unimplemented` in test containers

When a test container should reject any unexpected dependency call, override with `unimplemented`:
```swift
final class TestAuthContainer: AuthContainer {
    override var authService: any AuthServiceProtocol {
        provide { unimplemented("authService") }
    }
}
```
Any code path that resolves `authService` without an explicit override will crash with a clear message — much better than silently using a production implementation in a test.

## Resetting state

| Method | What it clears |
|---|---|
| `resetCached()` | `.cached`-scope values only. Singletons and overrides are preserved. |
| `resetAll()` | All overrides AND all cached/singleton values. The container is fully fresh. |

When to use which:
- **`resetCached()`** — between tests that exercise `.cached` ViewModels.
- **`resetAll()`** — between tests, when you want a guaranteed clean slate. Common pattern: call in `setUp` / `@Suite.init`.

## Avoid: mutating `Container.shared` directly

```swift
// ❌ Don't do this — leaks across tests
AppContainer.shared.override(\.authService) { mock }
```

Even with `removeOverride(for:)` in tearDown, this is brittle. Use `withOverrides` instead.

## Async tests

`withOverrides` has both sync and async overloads:
```swift
// async
try await container.withOverrides { $0.override(\.x) { mock } } run: {
    let result = try await sut.doWork()
    #expect(result == .success)
}

// sync
try container.withOverrides { $0.override(\.x) { mock } } run: {
    let result = sut.doWork()
    #expect(result == .success)
}
```

## Multiple overrides

`OverrideBuilder` supports any number of overrides in a single call:
```swift
try await AppContainer.shared.withOverrides {
    $0.override(\.authService) { mockAuth }
    $0.override(\.networkClient) { mockNetwork }
    $0.override(\.analytics) { mockAnalytics }
} run: {
    // run test
}
```

## Common pitfalls

- **Tests pass alone, fail in the suite** — almost always means a previous test mutated the container without cleanup. Switch to `withOverrides`, or call `resetAll()` in setUp.
- **Mock not called** — the dependency's return type is concrete, not a protocol. The override isn't being substituted because the type doesn't match. Fix the registration in the container, not the test.
- **Test crashes with "Override … returned … but expected …"** — an override factory returned the wrong type. Forge fires an `assertionFailure` on a type-mismatched override (debug/test builds) instead of silently running the real dependency. Fix the override's return type. (The KeyPath API — `override(\.x) { ... }` — normally catches this at compile time; raw/`Any`-typed overrides can still trip it at runtime.)
- **Test sees a real network call** — the dependency wasn't overridden, OR the override is on the wrong container (e.g., overriding `AuthContainer.shared.x` but the code under test uses `AppContainer.shared.x`).
- **Override factory invoked one extra time** — the first registration for a given KeyPath on a container runs the factory once as a key-discovery probe (Forge evaluates the property's `provide(...)` call to learn its storage key; the probe's value is discarded). A spy that counts factory invocations should expect **1 + resolutions** — the probe fires only on the first registration per KeyPath, never on re-registration — and overrides are still never cached. In a `withOverrides` builder the probe runs during `configure`, before the builder's other overrides are installed, so an override factory must not resolve sibling dependencies it expects to be mocked.
- **Crash: "An override on … targets a property … whose getter never calls provide(...)"** — `override(\.x)` only works on properties whose getter calls `provide(...)` with the property's own type. It traps at registration time in all build configurations for plain computed properties, differently-typed forwards, and forwards to other containers. A **same-type alias** (`var alias: any P { backing }`) does NOT trap — it is discovered as `backing`'s registration, so overriding the alias overrides `backing` container-wide. Properties registered with an explicit `key:` parameter ARE overridable — key discovery reads the real key.

## Related skills

- `using-forge` — registration and injection conventions
- `forge-modular` — overriding cross-module proxies in tests
