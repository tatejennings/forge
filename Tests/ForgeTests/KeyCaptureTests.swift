import Testing
import Foundation
@testable import Forge

/// Pins the key-capture handshake that backs the KeyPath-based override APIs.
///
/// Storage keys are discovered by evaluating the target property with a pending
/// capture set — never by parsing the KeyPath's description, which degrades to
/// `<computed 0x… (Type)>` in symbol-stripped release binaries and silently
/// mis-keyed every override registered through `override(_:with:)` (the
/// TestFlight-only launch-crash bug fixed in 0.6.0).
@Suite("KeyPath key-capture discovery")
struct KeyCaptureTests {

    @Test("Override of a property registered with an explicit key: takes effect")
    func explicitKeyOverride() {
        let container = TestContainer()
        container.override(\.customKeyedService) { SimpleService(id: "custom-overridden") as any ServiceProtocol }

        // The property registers under "legacy.customService", not the property
        // name — capture discovers the real key, so the override must match.
        #expect(container.customKeyedService.id == "custom-overridden")
    }

    // Wiring an unimplemented() proxy is covered by
    // KeyPathOverrideTests.keyPathOverrideOnUnimplementedProperty; the builder
    // variant below also exercises the proxy fixture.

    @Test("A getter that resolves a sibling in its body still captures its own key")
    func siblingResolutionInGetterBodyCapturesOwnKey() {
        let container = TestContainer()
        container.override(\.composedCounted) { SimpleService(id: "composed-mock") as any ServiceProtocol }

        // The sibling (countedSingleton) must be untouched by discovery: its
        // factory never ran, no override landed on it, and the target's
        // override is live under the target's own key.
        #expect(container.singletonBuildCount.value == 0)
        #expect(container.composedCounted.id == "composed-mock")
        _ = container.countedSingleton
        #expect(container.singletonBuildCount.value == 1) // real factory, not the mock
    }

    @Test("Same-type alias is discovered as its backing registration")
    func aliasTargetsBackingRegistration() {
        let container = TestContainer()
        container.override(\.aliasToSingleton) { SimpleService(id: "alias-mock") as any ServiceProtocol }

        // Documented behavior: overriding the alias overrides `singletonService`
        // container-wide, and removal through the alias restores both.
        #expect(container.aliasToSingleton.id == "alias-mock")
        #expect(container.singletonService.id == "alias-mock")

        container.removeOverride(for: \.aliasToSingleton)
        #expect(container.singletonService.id != "alias-mock")
    }

    @Test("An override factory can register another override (nested discovery)")
    func nestedRegistrationInsideProbe() {
        let container = TestContainer()
        container.override(\.transientService) {
            container.override(\.cachedService) { SimpleService(id: "nested-inner") as any ServiceProtocol }
            return SimpleService(id: "nested-outer") as any ServiceProtocol
        }

        #expect(container.transientService.id == "nested-outer")
        #expect(container.cachedService.id == "nested-inner")
    }

    @Test("Probe runs once per KeyPath — re-registration uses the memoized key")
    func probeRunsOncePerKeyPath() {
        let container = TestContainer()
        let firstCounter = Counter()
        let secondCounter = Counter()

        container.override(\.singletonService) {
            _ = firstCounter.increment()
            return SimpleService(id: "first") as any ServiceProtocol
        }
        #expect(firstCounter.value == 1) // exactly the discovery probe

        container.override(\.singletonService) {
            _ = secondCounter.increment()
            return SimpleService(id: "second") as any ServiceProtocol
        }
        #expect(secondCounter.value == 0) // memoized key — no probe

        #expect(container.singletonService.id == "second")
        #expect(secondCounter.value == 1)
        #expect(firstCounter.value == 1) // replaced override never ran again
    }

    @Test("Key discovery never runs the real factory or populates the cache")
    func discoveryHasNoResolutionSideEffects() {
        let container = TestContainer()
        container.override(\.countedSingleton) { SimpleService(id: "no-side-effects") as any ServiceProtocol }

        #expect(container.singletonBuildCount.value == 0)

        _ = container.countedSingleton
        _ = container.countedSingleton
        #expect(container.singletonBuildCount.value == 0)

        // Removing the override must expose the real factory (nothing was cached
        // during discovery), which then builds normally.
        container.removeOverride(for: \.countedSingleton)
        _ = container.countedSingleton
        #expect(container.singletonBuildCount.value == 1)
    }

    @Test("removeOverride for a never-overridden KeyPath is a safe no-op")
    func removeWithoutOverrideIsNoOp() {
        let container = TestContainer()

        // Establish state a broken no-op could damage: a live override on one
        // property and a cached singleton on another.
        container.override(\.transientService) { SimpleService(id: "kept-override") as any ServiceProtocol }
        let cachedSingleton = container.singletonService

        container.removeOverride(for: \.cachedService) // never overridden

        // Neither the unrelated override nor the caches may be disturbed.
        #expect(container.transientService.id == "kept-override")
        #expect(container.singletonService.id == cachedSingleton.id)
    }

    @Test("withOverrides builder discovers keys, including explicit key: registrations")
    func builderDiscoversKeys() {
        let container = TestContainer()

        container.withOverrides {
            $0.override(\.customKeyedService) { SimpleService(id: "builder-custom") as any ServiceProtocol }
            $0.override(\.unimplementedProxy) { SimpleService(id: "builder-proxy") as any ServiceProtocol }
        } run: {
            #expect(container.customKeyedService.id == "builder-custom")
            #expect(container.unimplementedProxy.id == "builder-proxy")
        }

        // Restored: the custom-keyed singleton resolves its live factory again.
        #expect(container.customKeyedService.id == "custom-keyed-live")
    }

    @Test("Thread safety: concurrent registration and resolution do not corrupt state")
    func concurrentRegistrationRace() {
        let container = TestContainer()
        let collector = IDCollector()

        DispatchQueue.concurrentPerform(iterations: 1000) { i in
            if i % 2 == 0 {
                container.override(\.transientService) { SimpleService(id: "race") as any ServiceProtocol }
            } else {
                collector.append(container.transientService.id)
            }
        }

        // After the race settles, the override must be cleanly in effect.
        #expect(container.transientService.id == "race")

        // Every mid-race resolution must have returned a coherent value: either
        // the override ("race") or a real transient (a 36-char UUID) — never a
        // torn/empty value or an escaped probe artifact.
        let uuidLength = 36
        for id in collector.uniqueIDs {
            #expect(id == "race" || id.count == uuidLength)
        }
    }
}
