# Testing with Forge

Mock dependencies in tests using scoped overrides, container reset, and explicit test contracts.

## Overview

Forge provides three mechanisms for overriding dependencies in tests, listed in order
of preference. All examples use Swift Testing (`@Test`, `@Suite`, `#expect`).

## Scoped Overrides with withOverrides (Preferred)

``Container/withOverrides(_:run:)-3qdpl`` registers overrides for the duration of a
closure, then automatically restores the previous state. No manual cleanup required:

```swift
@Test("Login succeeds with valid credentials")
func testLoginSuccess() async throws {
    let mock = MockAuthService(shouldSucceed: true)

    try await AuthContainer.shared.withOverrides {
        $0.override(\.authService) { mock }
    } run: {
        let viewModel = LoginViewModel()
        await viewModel.login(username: "user", password: "pass")
        #expect(mock.loginCalled)
    }
}
```

Cleanup is guaranteed via `defer` — even if the body throws, overrides are restored.
Both sync and async variants are available:

- ``Container/withOverrides(_:run:)-3qdpl`` — synchronous
- ``Container/withOverrides(_:run:)-4eui2`` — async (use when your test body contains `await`)

## Fresh State Between Tests

``SharedContainer/shared`` is a stable `let` for the lifetime of the process — you
don't (and can't) swap the instance. For test suites where every test needs a clean
slate, reset the shared container in place with ``Container/resetAll()`` in the
suite's `init`. `resetAll()` clears all cached singletons, cached values, and
registered overrides:

```swift
@Suite("LoginViewModel behavior", .serialized)
struct LoginViewModelTests {

    init() {
        AuthContainer.shared.resetAll()
    }

    @Test("Login calls the auth service")
    func testLoginCallsService() async throws {
        let mock = MockAuthService()

        try await AuthContainer.shared.withOverrides {
            $0.override(\.authService) { mock }
        } run: {
            let vm = LoginViewModel()
            await vm.login(username: "test", password: "pass")
            #expect(mock.loginCalled)
        }
    }
}
```

Each test gets a fresh starting point with no leftover state from previous tests.
Mark such suites `.serialized` so the in-place resets don't race across tests.

## Direct Overrides (Escape Hatch)

When `withOverrides` closures are impractical, use ``Container/override(_:with:)``
directly:

```swift
init() {
    AuthContainer.shared.resetAll()
    AuthContainer.shared.override(\.authService) { MockAuthService() }
}
```

This is the escape hatch — prefer `withOverrides` wherever possible because direct
overrides require manual cleanup via ``Container/removeOverride(for:)`` or
``Container/resetAll()``.

> Note: The first time a given KeyPath is overridden on a container (through either
> API), the override factory runs once during registration — Forge discovers the
> property's storage key by evaluating its `provide(...)` call, and the factory
> supplies the getter's return value. The probe's value is discarded, and overrides
> are still resolved fresh (never cached) on every resolution. If a test spy counts
> factory invocations, expect one extra call on first registration. The target
> property must call `provide(...)`; overriding a plain computed property traps
> with a descriptive message.

## The TestContainer Pattern with unimplemented

``unimplemented(_:file:line:)`` makes dependency contracts explicit — any dependency
that isn't overridden crashes immediately instead of silently running the wrong code.
This is valuable in tests (shown here) and in cross-module proxies (see
<doc:ModularArchitecture>).

Use it to define a test container where every dependency fails loudly if called
without being explicitly overridden:

```swift
final class TestAuthContainer: AuthContainer {
    override var authService: any AuthServiceProtocol {
        provide { unimplemented("authService") }
    }

    override var networkClient: any NetworkClientProtocol {
        provide { unimplemented("networkClient") }
    }
}
```

Then in your tests, build the test container as an instance, override only what you
need, and resolve through it explicitly with ``ContainerInject``:

```swift
@Test("Login success flow")
func testLoginSuccess() async throws {
    let container = TestAuthContainer()

    try await container.withOverrides {
        $0.override(\.authService) {
            MockAuthService(shouldSucceed: true)
        }
        // networkClient is unimplemented — if login accidentally
        // calls it, the test fails loudly instead of silently
        // executing live code
    } run: {
        let authService = ContainerInject(container, \.authService).wrappedValue
        let vm = LoginViewModel(authService: authService)
        await vm.login(username: "user", password: "pass")
    }
}
```

This makes test contracts explicit — you declare exactly which dependencies a test
exercises. Anything else is a bug.

> Tip: If you want the zero-argument `@Inject(\.x)` to resolve from a test container
> without threading it through initializers, declare that container's `shared` as a
> `static var` (the ``SharedContainer`` requirement is only `{ get }`, so a `var`
> satisfies it) and assign it in a `.serialized` suite's `init`. Forge permits this;
> it just isn't the default — prefer the stable `let` plus ``Container/resetAll()``.

## Best Practices

- **Prefer `withOverrides`** — automatic cleanup prevents test state leakage
- **Call `resetAll()` in suite `init()`** — gives each test a fresh starting point
- **Use `unimplemented` for test containers** — makes dependency boundaries explicit
- **Use `.serialized` on suites** that reset or mutate `shared` — prevents data races
- **Use protocol return types** on container properties — this is what makes mocks
  substitutable for live implementations
