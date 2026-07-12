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

        // Memoized keyPath → storage-key discoveries (see `_key(for:probe:expecting:evaluate:)`).
        // Type metadata, not user state, so `resetAll()` leaves it intact.
        var keyPathKeys: [AnyKeyPath: String] = [:]
    }

    private let lock = Lock()
    private var state = State()

    // MARK: - Key-Capture Context

    /// Receives the storage key from ``provide(_:key:_:preview:)``'s capture
    /// intercept. A class so the binding in ``CaptureContext`` can stay a `let`
    /// while the intercept writes through it. Only ever written and read on the
    /// thread running the discovery evaluation.
    internal final class CapturedKeyBox: @unchecked Sendable {
        var key: String?
    }

    /// The in-flight key discovery, bound as a task-local for the duration of one
    /// property evaluation. Scoping the capture to the task/thread (instead of
    /// container state guarded across the evaluation by ``lock``) means:
    /// no user code ever runs while the container lock is held, concurrent
    /// discoveries on one container don't serialize, nested discoveries restore
    /// the outer binding structurally, and a getter that hops threads simply
    /// fails discovery (a descriptive trap) instead of deadlocking.
    internal struct CaptureContext: Sendable {
        /// Only the container being discovered may consume the capture — a getter
        /// that forwards to a different container resolves there normally.
        let container: ObjectIdentifier
        /// Only a `provide` call whose inferred `T` equals the KeyPath's `Value`
        /// is the target registration; sibling `provide` calls of other types
        /// made during evaluation resolve normally instead of being mis-captured.
        let expected: Any.Type
        let probe: @Sendable () -> Any
        let box: CapturedKeyBox
    }

    @TaskLocal
    internal static var captureContext: CaptureContext?

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
        // 0. Key-capture intercept — `override(_:with:)` discovers this property's
        // storage key by evaluating it with a task-local capture bound (see
        // `_key(for:probe:expecting:evaluate:)`). Fires only for the container
        // being discovered AND only when this call's `T` is the KeyPath's Value
        // type, so sibling registrations of other types and other containers
        // touched during evaluation resolve normally. Records `key` and returns
        // the probe's value without touching overrides, previews, or caches.
        // Reading the task-local takes no lock, so normal resolution pays no
        // extra synchronization for this check.
        if let capture = Container.captureContext,
           capture.container == ObjectIdentifier(self),
           capture.expected == T.self {
            capture.box.key = key
            // The probe runs with the capture suppressed: anything it resolves
            // takes the normal path instead of re-entering this intercept
            // (which would recurse when the probe touches a same-type sibling).
            let result = Container.$captureContext.withValue(nil) { capture.probe() }
            guard let value = result as? T else {
                // Unreachable when `expected == T.self` (the probe wraps a
                // `() -> Value` factory); kept as defense in depth.
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
    /// with a task-local ``CaptureContext`` bound. ``provide(_:key:_:preview:)``
    /// intercepts the matching call (same container, `T` == the KeyPath's Value),
    /// records its own `key` parameter (the same `#function`-derived key used at
    /// resolution) into the context's box, and returns the probe's value instead
    /// of resolving normally.
    ///
    /// Discovered keys are memoized per KeyPath, so `probe` executes at most once
    /// per property per container (per distinct KeyPath root type). The lock is
    /// held only for the memo lookup and insert — never across `evaluate()` or
    /// the probe, so registration executes no user code under the container lock.
    /// Nested discoveries (an override factory registering another override) are
    /// safe: task-local bindings restore the outer context structurally.
    ///
    /// - Parameters:
    ///   - keyPath: The KeyPath whose backing key should be discovered.
    ///   - probe: Executed by `provide`'s intercept to produce the getter's return
    ///     value; typically the override factory being registered.
    ///   - expected: The KeyPath's Value type; the intercept fires only on a
    ///     `provide` call of exactly this type.
    ///   - evaluate: Must evaluate `self[keyPath: keyPath]` — the caller supplies
    ///     this because subscripting by `KeyPath<Self, T>` requires `Self`, which
    ///     only the `OverridableContainer` extension has.
    /// - Returns: The discovered key, or `nil` if evaluation reached no matching
    ///   `provide` call (not a provide-backed property of this type, or a getter
    ///   that hops threads/tasks before registering).
    internal func _key(
        for keyPath: AnyKeyPath,
        probe: @escaping @Sendable () -> Any,
        expecting expected: Any.Type,
        evaluate: () -> Void
    ) -> String? {
        if let known = lock.withLock({ state.keyPathKeys[keyPath] }) {
            return known
        }
        let box = CapturedKeyBox()
        let context = CaptureContext(
            container: ObjectIdentifier(self),
            expected: expected,
            probe: probe,
            box: box
        )
        Container.$captureContext.withValue(context) {
            evaluate()
        }
        guard let key = box.key else { return nil }
        lock.withLock { state.keyPathKeys[keyPath] = key }
        return key
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
    /// trapping if evaluation reaches no matching ``Container/provide(_:key:_:preview:)`` call.
    ///
    /// The first call per KeyPath executes `probe` once (as the property getter's
    /// return value); subsequent calls hit the memoized key and never run it.
    internal func resolveKey<T>(
        _ keyPath: KeyPath<Self, T>,
        probe: @escaping @Sendable () -> Any
    ) -> String {
        if let key = _key(
            for: keyPath,
            probe: probe,
            expecting: T.self,
            evaluate: { _ = self[keyPath: keyPath] }
        ) {
            return key
        }
        // Traps in release too: a silent no-op here would resurface at resolution
        // as a misleading crash far from the mistake — the failure mode this
        // mechanism exists to eliminate. The container type is named explicitly
        // because "\(keyPath)" degrades to "<computed 0x…>" in symbol-stripped
        // builds; reproduce in a Debug build to see the property name.
        preconditionFailure(
            "[Forge] An override on \(Self.self) targets a property of type \(T.self) "
            + "whose getter never calls provide(...) with that type "
            + "(KeyPath: \(keyPath) — this may display as '<computed 0x…>' in "
            + "stripped builds; reproduce in a Debug build to see the property name). "
            + "Only provide-backed container properties can be overridden. If the "
            + "property forwards to a differently-typed dependency or to another "
            + "container, override that dependency on its own container instead."
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
    ///   on every subsequent resolution. Wiring closures should therefore capture
    ///   an already-resolved value rather than resolve other dependencies inline,
    ///   or those resolutions happen eagerly at registration time.
    ///
    /// - Important: The target property must call `provide(...)` with the
    ///   property's own type, directly in its getter. Overriding a plain computed
    ///   property (or one that forwards to a *differently-typed* dependency or to
    ///   another container) traps immediately with a descriptive message — a loud
    ///   failure at wiring time rather than a misleading one at resolution.
    ///   A property that forwards to a provide-backed sibling of the **same type**
    ///   (`var alias: any P { backing }`) is discovered as its backing
    ///   registration: overriding the alias overrides `backing` container-wide.
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
    /// property, this is a safe no-op — there is nothing to remove.
    ///
    /// - Important: Removal matches by KeyPath identity, which includes the
    ///   KeyPath's *root type*: `\SubContainer.x` and `\BaseContainer.x` are
    ///   distinct keys, so remove with a KeyPath rooted at the same type the
    ///   override was registered with. Overrides registered through the
    ///   string-keyed `_storeOverride(key:factory:)` plumbing must be removed
    ///   with `_removeOverride(key:)`. When in doubt, ``Container/resetAll()``
    ///   or ``withOverrides(_:run:)-3qdpl`` guarantee cleanup.
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
