/// The base class for all dependency containers in Forge.
///
/// Subclass `Container` to define your module's dependencies as computed properties.
/// Each property calls ``provide(_:key:_:preview:)`` to register its factory and scope.
///
/// ```swift
/// final class AppContainer: Container, SharedContainer {
///     static let shared = AppContainer()
///
///     var authService: any AuthServiceProtocol {
///         provide(.singleton) { AuthService() } preview: { MockAuthService() }
///     }
/// }
/// ```
///
/// Conform to ``SharedContainer`` to enable the zero-argument
/// ``ContainerInject`` syntax (`@Inject(\.property)`).
///
/// - Important: Always use protocol return types on dependency properties
///   to enable mock substitution in tests and previews.
///
/// - Note: All cache and override access is protected by a recursive lock,
///   making `Container` safe to use from multiple threads. A dependency's factory
///   runs *inside* the lock so that a `.singleton`/`.cached` value is built exactly
///   once, even under concurrent first resolution; the lock is recursive because a
///   factory may resolve sibling dependencies, re-entering ``provide(_:key:_:preview:)``.
///   Override methods use KeyPath references for compile-time safety — the storage
///   key is discovered by evaluating the property's own `provide` registration, so
///   it always matches the key used at resolution.
///
///   The lock synchronizes the *cache*, not your *values*: resolved dependencies are
///   not `Sendable`-checked, so a `.singleton`/`.cached` instance shared across threads
///   must be thread-safe on its own. This is deliberate — requiring `Sendable` would
///   prevent registering `@MainActor`-isolated dependencies such as cached view models.
///
/// - Note: `Container` is `@unchecked Sendable` — not because access is unsynchronized
///   (it is fully serialized by the lock), but because Swift only permits *checked*
///   `Sendable` conformance on `final` classes, and `Container` is `open` so it can be
///   subclassed. The conformance is sound: every mutable field lives in the
///   lock-guarded `State`.
///
/// ## Topics
///
/// ### Creating a Container
/// - ``init()``
///
/// ### Resolving Dependencies
/// - ``provide(_:key:_:preview:)``
///
/// ### Testing and Overrides
/// - ``withOverrides(_:run:)-3qdpl``
/// - ``withOverrides(_:run:)-4eui2``
/// - ``override(_:with:)``
/// - ``removeOverride(for:)``
/// - ``resetAll()``
/// - ``resetCached()``
open class Container: @unchecked Sendable {

    // MARK: - Internal Storage

    /// All mutable container state, guarded as a unit by ``lock``.
    private struct State {
        var singletonCache: [String: Any] = [:]
        var cachedCache: [String: Any] = [:]
        var overrides: [String: @Sendable () -> Any] = [:]

        // Key-capture handshake (see `_key(for:probe:evaluate:)`). `pendingCapture`
        // and `capturedKey` are only ever non-nil while the thread that set them
        // holds `lock`, so re-entrant `provide` calls on that thread are the only
        // observers. `keyPathKeys` memoizes discovered keys — it is type metadata,
        // not user state, so `resetAll()` leaves it intact.
        var pendingCapture: (@Sendable () -> Any)?
        var capturedKey: String?
        var keyPathKeys: [AnyKeyPath: String] = [:]
    }

    private let lock = Lock()
    private var state = State()

    // MARK: - Initialization

    /// Creates an empty container with no cached values or overrides.
    public init() {}

    // MARK: - Core Resolution

    /// Resolves a dependency using the given scope and factory.
    ///
    /// Call this from computed properties on your ``Container`` subclass.
    /// The generic type `T` is inferred from the computed property's return type,
    /// so factories can return concrete types without explicit casting:
    ///
    /// ```swift
    /// var authService: any AuthServiceProtocol {
    ///     provide(.singleton) {
    ///         LiveAuthService()
    ///     } preview: {
    ///         MockAuthService()
    ///     }
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - scope: The lifecycle scope for this dependency. Defaults to `.transient`.
    ///   - key: The registration key. Defaults to the property name via `#function`.
    ///   - factory: The factory closure that creates the dependency.
    ///   - preview: An optional factory used when running inside an Xcode preview.
    ///     Preview values are never cached regardless of the declared scope.
    /// - Returns: The resolved dependency instance.
    ///
    /// - Note: Resolution follows a strict precedence order:
    ///   1. **Overrides** — checked first. A type-mismatched override triggers an
    ///      `assertionFailure` (crashing in debug/test builds so the mistake surfaces
    ///      immediately) and, in release builds, falls through to the real factory.
    ///   2. **Preview factory** — used when running inside an Xcode preview and a
    ///      `preview` closure was provided. Preview values are never cached.
    ///   3. **Normal factory** — the default path for transient, singleton, and cached scopes.
    public func provide<T>(
        _ scope: Scope = .transient,
        key: String = #function,
        _ factory: () -> Any,
        preview: (() -> Any)? = nil
    ) -> T {
        // 0. Key-capture handshake — `override(_:with:)` discovers this property's
        // storage key by evaluating it with a pending capture set (see
        // `_key(for:probe:evaluate:)`). Record `key` and return the probe's value
        // without touching overrides, previews, or caches. The whole handshake runs
        // on the thread that holds the lock, so no other thread can observe or
        // clear the pending state between these two acquisitions.
        if let probe = lock.withLock({ state.pendingCapture }) {
            lock.withLock {
                state.pendingCapture = nil
                state.capturedKey = key
            }
            let result = probe()
            guard let value = result as? T else {
                fatalError(
                    "[Forge] Override for '\(key)' returned \(type(of: result)) but expected \(T.self)."
                )
            }
            return value
        }

        // 1. Check overrides first — overrides are never cached
        if let overrideFactory = lock.withLock({ state.overrides[key] }) {
            let result = overrideFactory()
            if let value = result as? T {
                return value
            }
            assertionFailure(
                "[Forge] Override for '\(key)' returned \(type(of: result)) but expected \(T.self). "
                + "Fix the override's return type. Release builds fall through to the real factory."
            )
        }

        // 2. Preview factory — never cached
        if PreviewContext.isPreview, let preview {
            guard let value = preview() as? T else {
                fatalError("[Forge] Preview factory for '\(key)' returned wrong type. Expected \(T.self).")
            }
            return value
        }

        // 3. Transient — always create fresh
        if scope == .transient {
            guard let value = factory() as? T else {
                fatalError("[Forge] Factory for '\(key)' returned wrong type. Expected \(T.self).")
            }
            return value
        }

        // 4. Singleton / Cached
        return resolveScoped(scope: scope, key: key, factory: factory)
    }

    // MARK: - Scoped Resolution

    private func resolveScoped<T>(scope: Scope, key: String, factory: () -> Any) -> T {
        // Swift dictionaries are value types — concurrent read + write is UB — so every
        // cache access is locked. The factory runs *inside* the lock so that a
        // `.singleton`/`.cached` value is built exactly once: a second thread blocks
        // until the first has finished building and storing. The lock is recursive
        // because a factory may resolve sibling dependencies, re-entering `provide`.
        lock.withLock {
            if let cached: T = cachedValue(scope: scope, key: key) {
                return cached
            }

            let result = factory()
            guard let value = result as? T else {
                fatalError("[Forge] Factory for '\(key)' returned \(type(of: result)) but expected \(T.self).")
            }
            switch scope {
            case .singleton: state.singletonCache[key] = value
            case .cached: state.cachedCache[key] = value
            case .transient: break // handled in `provide`; never reached here
            }
            return value
        }
    }

    /// Reads the cached value for `key` in the given scope and casts it to `T`.
    ///
    /// - Important: The caller must already hold ``lock`` — this method touches
    ///   ``state`` without locking.
    private func cachedValue<T>(scope: Scope, key: String) -> T? {
        let cache = scope == .singleton ? state.singletonCache : state.cachedCache
        return cache[key] as? T
    }

    // MARK: - Internal Override Storage Access

    // These methods expose the locked override storage to the `OverridableContainer`
    // protocol extension, which provides the public KeyPath-based API.
    // They are public because protocol requirements must match the conforming type's
    // access level, but they are not intended for direct use — use the KeyPath-based
    // methods (`override(_:with:)`, `removeOverride(for:)`, `withOverrides`) instead.

    public func _storeOverride(key: String, factory: @escaping @Sendable () -> Any) {
        lock.withLock { state.overrides[key] = factory }
    }

    public func _removeOverride(key: String) {
        _ = lock.withLock { state.overrides.removeValue(forKey: key) }
    }

    public func _withOverrides(
        factories: [String: @Sendable () -> Any],
        body: () throws -> Void
    ) rethrows {
        let snapshot = lock.withLock {
            let saved = state.overrides
            for (key, factory) in factories {
                state.overrides[key] = factory
            }
            return saved
        }

        defer { restoreOverrides(snapshot) }
        try body()
    }

    public func _withOverridesAsync(
        factories: [String: @Sendable () -> Any],
        body: () async throws -> Void
    ) async rethrows {
        let snapshot = lock.withLock {
            let saved = state.overrides
            for (key, factory) in factories {
                state.overrides[key] = factory
            }
            return saved
        }

        defer { restoreOverrides(snapshot) }
        try await body()
    }

    // MARK: - Internal Key Discovery

    /// Discovers the storage key backing `keyPath` by evaluating the property once
    /// while a pending capture is set. ``provide(_:key:_:preview:)`` intercepts the
    /// call, records its own `key` parameter (the same `#function`-derived key used
    /// at resolution), and returns the probe's value instead of resolving normally.
    ///
    /// Discovered keys are memoized per KeyPath, so `probe` executes at most once
    /// per property per container. The entire handshake runs inside ``lock`` — the
    /// same thread re-enters `provide` freely (the lock is recursive) while other
    /// threads block, which is what makes the pending state in ``State`` race-free.
    ///
    /// - Parameters:
    ///   - keyPath: The KeyPath whose backing key should be discovered.
    ///   - probe: Executed by `provide`'s intercept to produce the getter's return
    ///     value; typically the override factory being registered.
    ///   - evaluate: Must evaluate `self[keyPath: keyPath]` — the caller supplies
    ///     this because subscripting by `KeyPath<Self, T>` requires `Self`, which
    ///     only the `OverridableContainer` extension has.
    /// - Returns: The discovered key, or `nil` if the property never called
    ///   `provide` (not a Forge-registered dependency).
    internal func _key(
        for keyPath: AnyKeyPath,
        probe: @escaping @Sendable () -> Any,
        evaluate: () -> Void
    ) -> String? {
        lock.withLock {
            if let known = state.keyPathKeys[keyPath] {
                return known
            }
            state.pendingCapture = probe
            evaluate()
            let captured = state.capturedKey
            state.pendingCapture = nil
            state.capturedKey = nil
            if let captured {
                state.keyPathKeys[keyPath] = captured
            }
            return captured
        }
    }

    /// Returns the previously discovered key for `keyPath`, if any.
    ///
    /// Used by ``OverridableContainer/removeOverride(for:)``: a KeyPath that was
    /// never used to register an override has no discovered key, and removal is a
    /// no-op by definition.
    internal func _cachedKey(for keyPath: AnyKeyPath) -> String? {
        lock.withLock { state.keyPathKeys[keyPath] }
    }

    // MARK: - Reset

    /// Removes all registered overrides and clears all cached and singleton values.
    ///
    /// - SeeAlso: ``resetCached()`` to clear only cached-scope values.
    public func resetAll() {
        lock.withLock {
            state.overrides.removeAll()
            state.singletonCache.removeAll()
            state.cachedCache.removeAll()
        }
    }

    /// Clears only cached-scope values. Leaves singletons and overrides intact.
    ///
    /// Use this to reset ``Scope/cached`` dependencies between test cases while
    /// preserving longer-lived singletons.
    ///
    /// - SeeAlso: ``resetAll()`` to clear everything including singletons and overrides.
    public func resetCached() {
        lock.withLock {
            state.cachedCache.removeAll()
        }
    }

    // MARK: - Private Helpers

    private func restoreOverrides(_ snapshot: [String: @Sendable () -> Any]) {
        lock.withLock {
            state.overrides = snapshot
        }
    }
}

// MARK: - OverridableContainer Protocol

/// Enables KeyPath-based override methods on ``Container`` subclasses.
///
/// You do not conform to this protocol directly — ``Container`` conforms automatically.
/// The protocol extension provides the public ``override(_:with:)``,
/// ``removeOverride(for:)``, and ``withOverrides(_:run:)-3qdpl`` methods that use
/// KeyPath references for compile-time safety.
///
/// - Note: This protocol exists because Swift requires `Self` in parameter position
///   to be defined in a protocol extension rather than directly on a class.
public protocol OverridableContainer: Container {
    func _storeOverride(key: String, factory: @escaping @Sendable () -> Any)
    func _removeOverride(key: String)
    func _withOverrides(factories: [String: @Sendable () -> Any], body: () throws -> Void) rethrows
    func _withOverridesAsync(factories: [String: @Sendable () -> Any], body: () async throws -> Void) async rethrows
}

extension Container: OverridableContainer {}

// MARK: - KeyPath-Based Override API

extension OverridableContainer {

    /// Resolves the storage key for `keyPath` via the key-capture handshake,
    /// trapping if the property is not backed by ``Container/provide(_:key:_:preview:)``.
    ///
    /// The first call per KeyPath executes `probe` once (as the property getter's
    /// return value); subsequent calls hit the memoized key and never run it.
    internal func resolveKey<T>(
        _ keyPath: KeyPath<Self, T>,
        probe: @escaping @Sendable () -> Any
    ) -> String {
        if let key = _key(for: keyPath, probe: probe, evaluate: { _ = self[keyPath: keyPath] }) {
            return key
        }
        // Traps in release too: a silent no-op here would resurface at resolution
        // as a misleading crash far from the mistake — the failure mode this
        // mechanism exists to eliminate.
        preconditionFailure(
            "[Forge] override(\(keyPath)) targets a property that never calls "
            + "provide(...). Only provide-backed container properties can be "
            + "overridden. If this property delegates to another dependency, "
            + "override that dependency instead."
        )
    }

    /// Overrides the dependency at the given KeyPath with the provided factory.
    ///
    /// Compile-time safe — the property must exist on the container and the
    /// return type is inferred from the KeyPath. Works with Xcode rename refactoring.
    /// The storage key is discovered by evaluating the property's own
    /// ``Container/provide(_:key:_:preview:)`` registration, so it always matches
    /// the key used at resolution — including properties registered with an
    /// explicit `key:` parameter, and regardless of build settings such as symbol
    /// stripping.
    ///
    /// Use this for `setUp`/`tearDown` patterns where the closure-based
    /// ``withOverrides(_:run:)-3qdpl`` is impractical.
    ///
    /// ```swift
    /// AppContainer.shared.override(\.authService) { MockAuthService() }
    /// ```
    ///
    /// - Note: The first time a given KeyPath is overridden on a container, the
    ///   `factory` runs once during registration to complete the key discovery.
    ///   Its value is discarded; overrides are still resolved fresh (never cached)
    ///   on every subsequent resolution.
    ///
    /// - Important: The target property must call `provide(...)`. Overriding a
    ///   plain computed property traps immediately with a descriptive message —
    ///   a loud failure at wiring time rather than a misleading one at resolution.
    ///
    /// - Parameters:
    ///   - keyPath: A KeyPath to the container property to override.
    ///   - factory: A closure that produces the override value.
    public func override<T>(_ keyPath: KeyPath<Self, T>, with factory: @escaping @Sendable () -> T) {
        let key = resolveKey(keyPath, probe: factory)
        _storeOverride(key: key, factory: factory)
    }

    /// Removes the override registered for the given KeyPath.
    /// The original factory behavior is restored on next resolution.
    ///
    /// If no override was ever registered through the KeyPath-based APIs for this
    /// property, this is a safe no-op — there is nothing to remove. (Overrides
    /// registered through the string-keyed `_storeOverride(key:factory:)` plumbing
    /// must be removed with `_removeOverride(key:)`.)
    ///
    /// ```swift
    /// AppContainer.shared.removeOverride(for: \.authService)
    /// ```
    public func removeOverride<T>(for keyPath: KeyPath<Self, T>) {
        guard let key = _cachedKey(for: keyPath) else { return }
        _removeOverride(key: key)
    }

    /// Registers overrides for the duration of a closure, then automatically restores
    /// the previous state.
    ///
    /// Overrides registered via the builder take precedence over original factories
    /// within the closure body. Cleanup is guaranteed even if the body throws.
    ///
    /// ```swift
    /// container.withOverrides {
    ///     $0.override(\.authService) { MockAuthService() }
    /// } run: {
    ///     let vm = LoginViewModel()
    ///     // test assertions...
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - configure: A closure that registers overrides via an ``OverrideBuilder``.
    ///   - body: The closure to execute with overrides active.
    public func withOverrides(
        _ configure: (inout OverrideBuilder<Self>) -> Void,
        run body: () throws -> Void
    ) rethrows {
        var builder = OverrideBuilder<Self>(container: self)
        configure(&builder)
        try _withOverrides(factories: builder.factories, body: body)
    }

    /// Registers overrides for the duration of an async closure, then automatically
    /// restores the previous state.
    ///
    /// This is the async variant of ``withOverrides(_:run:)-3qdpl``. Use it when your
    /// test body contains `await` calls.
    ///
    /// - Parameters:
    ///   - configure: A closure that registers overrides via an ``OverrideBuilder``.
    ///   - body: The async closure to execute with overrides active.
    public func withOverrides(
        _ configure: (inout OverrideBuilder<Self>) -> Void,
        run body: () async throws -> Void
    ) async rethrows {
        var builder = OverrideBuilder<Self>(container: self)
        configure(&builder)
        try await _withOverridesAsync(factories: builder.factories, body: body)
    }
}
