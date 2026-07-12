/// Accumulates override registrations for use with ``Container/withOverrides(_:run:)-3qdpl``.
///
/// The builder is passed into the configuration closure of `withOverrides`.
/// Register overrides by calling ``override(_:with:)`` with a KeyPath to the
/// container property you want to override.
///
/// - Important: The builder is only meaningful inside the `configure` closure.
///   A copy stashed and used after `withOverrides` returns still runs key
///   discovery against the live container (executing the factory once), but its
///   registrations are silently discarded — don't escape it.
///
/// ```swift
/// container.withOverrides {
///     $0.override(\.authService) { MockAuthService() }
/// } run: {
///     // test code...
/// }
/// ```
public struct OverrideBuilder<C: Container>: Sendable {

    /// The container the overrides are destined for. Needed at registration time
    /// because storage keys are discovered by evaluating the target property on
    /// the container itself (see `OverridableContainer.resolveKey(_:probe:)`).
    let container: C

    var factories: [String: @Sendable () -> Any] = [:]

    init(container: C) {
        self.container = container
    }

    /// Registers an override factory for the dependency at the given KeyPath.
    ///
    /// Compile-time safe — the property must exist on the container and
    /// Xcode rename refactoring works correctly. The storage key is discovered
    /// from the property's own `provide(...)` registration, so it always matches
    /// the key used at resolution.
    ///
    /// - Note: The first time a given KeyPath is used on a container, `factory`
    ///   runs once during registration to complete the key discovery; its value
    ///   is discarded — and this happens during `configure`, before any of the
    ///   builder's overrides are installed, so the factory must not resolve
    ///   sibling dependencies it expects to be overridden. The property must call
    ///   `provide(...)` with its own type — targeting a plain computed property
    ///   (or one forwarding to a differently-typed dependency or another
    ///   container) traps with a descriptive message; a same-type alias is
    ///   discovered as its backing registration.
    ///
    /// - Parameters:
    ///   - keyPath: A KeyPath to the container property to override.
    ///   - factory: A closure that produces the override value.
    public mutating func override<T>(_ keyPath: KeyPath<C, T>, with factory: @escaping @Sendable () -> T) {
        let key = container.resolveKey(keyPath, probe: factory)
        factories[key] = factory
    }
}
