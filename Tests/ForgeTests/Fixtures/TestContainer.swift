@testable import Forge

final class TestContainer: Container, SharedContainer, @unchecked Sendable {
    nonisolated(unsafe) static var shared = TestContainer()

    var transientService: any ServiceProtocol {
        provide(.transient) { SimpleService() }
    }

    var singletonService: any ServiceProtocol {
        provide(.singleton) { SimpleService() }
    }

    var cachedService: any ServiceProtocol {
        provide(.cached) { SimpleService() }
    }

    var previewableService: any ServiceProtocol {
        provide(.singleton) { SimpleService(id: "live") } preview: { SimpleService(id: "preview") }
    }

    var transientPreviewable: any ServiceProtocol {
        provide(.transient) { SimpleService(id: "live-transient") } preview: { SimpleService(id: "preview-transient") }
    }

    /// Registered under an explicit key that differs from the property name —
    /// exercises key discovery for custom-keyed registrations.
    var customKeyedService: any ServiceProtocol {
        provide(.singleton, key: "legacy.customService") { SimpleService(id: "custom-keyed-live") }
    }

    /// A cross-module-style proxy: resolving it without an override traps.
    var unimplementedProxy: any ServiceProtocol {
        provide(.singleton) { unimplemented("unimplementedProxy") }
    }

    // MARK: - Build-count instrumentation
    //
    // Each counting property's factory increments a per-instance counter every time it
    // actually runs, so tests can assert how many times a factory was invoked — which
    // is what pins the scope contracts (transient = every resolution, singleton/cached
    // = exactly once) rather than just observing the returned identity.

    let transientBuildCount = Counter()
    let singletonBuildCount = Counter()
    let cachedBuildCount = Counter()

    var countedTransient: any ServiceProtocol {
        provide(.transient) {
            _ = self.transientBuildCount.increment()
            return SimpleService()
        }
    }

    var countedSingleton: any ServiceProtocol {
        provide(.singleton) {
            _ = self.singletonBuildCount.increment()
            return SimpleService()
        }
    }

    var countedCached: any ServiceProtocol {
        provide(.cached) {
            _ = self.cachedBuildCount.increment()
            return SimpleService()
        }
    }
}
