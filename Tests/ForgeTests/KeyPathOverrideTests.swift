import Testing
import Foundation
@testable import Forge

@Suite("KeyPath-based override behavior")
struct KeyPathOverrideTests {

    @Test("override(keyPath:) correctly overrides the intended dependency")
    func overrideKeyPathCorrectlyOverrides() {
        let container = TestContainer()
        container.override(\.transientService) { SimpleService(id: "overridden") as any ServiceProtocol }

        let resolved = container.transientService
        #expect(resolved.id == "overridden")
    }

    @Test("removeOverride(for keyPath:) restores original factory behavior")
    func removeOverrideKeyPathRestoresFactory() {
        let container = TestContainer()

        let original = container.singletonService
        container.override(\.singletonService) { SimpleService(id: "overridden") as any ServiceProtocol }

        let overridden = container.singletonService
        #expect(overridden.id == "overridden")

        container.removeOverride(for: \.singletonService)

        let restored = container.singletonService
        #expect(restored.id == original.id)
    }

    @Test("withOverrides with KeyPath overrides applies correctly within closure")
    func withOverridesKeyPathAppliesWithinClosure() {
        let container = TestContainer()

        container.withOverrides {
            $0.override(\.transientService) { SimpleService(id: "scoped") as any ServiceProtocol }
        } run: {
            let inside = container.transientService
            #expect(inside.id == "scoped")
        }
    }

    @Test("withOverrides with KeyPath overrides restores after closure exits normally")
    func withOverridesKeyPathRestoresAfterNormalExit() {
        let container = TestContainer()

        container.withOverrides {
            $0.override(\.transientService) { SimpleService(id: "scoped") as any ServiceProtocol }
        } run: {
            // override is active inside
        }

        let after = container.transientService
        #expect(after.id != "scoped")
    }

    @Test("withOverrides with KeyPath overrides restores after closure throws")
    func withOverridesKeyPathRestoresAfterThrow() {
        let container = TestContainer()

        struct TestError: Error {}

        do {
            try container.withOverrides {
                $0.override(\.transientService) { SimpleService(id: "will-throw") as any ServiceProtocol }
            } run: {
                let inside = container.transientService
                #expect(inside.id == "will-throw")
                throw TestError()
            }
        } catch {
            // Expected
        }

        let after = container.transientService
        #expect(after.id != "will-throw")
    }

    @Test("withOverrides async variant works with KeyPath overrides")
    func withOverridesAsyncKeyPathWorks() async throws {
        let container = TestContainer()

        try await container.withOverrides {
            $0.override(\.transientService) { SimpleService(id: "async-override") as any ServiceProtocol }
        } run: {
            try await Task.sleep(for: .milliseconds(1))
            let inside = container.transientService
            #expect(inside.id == "async-override")
        }

        let after = container.transientService
        #expect(after.id != "async-override")
    }

    @Test("Multiple KeyPath overrides in a single withOverrides closure all apply")
    func multipleKeyPathOverridesInSingleClosure() {
        let container = TestContainer()

        container.withOverrides {
            $0.override(\.transientService) { SimpleService(id: "mock-transient") as any ServiceProtocol }
            $0.override(\.singletonService) { SimpleService(id: "mock-singleton") as any ServiceProtocol }
        } run: {
            #expect(container.transientService.id == "mock-transient")
            #expect(container.singletonService.id == "mock-singleton")
        }
    }

    @Test("override(keyPath:) on a singleton-scoped property overrides correctly")
    func keyPathOverrideOnSingletonScope() {
        let container = TestContainer()

        // Populate the singleton cache first
        let original = container.singletonService

        // Override should take precedence over cached singleton
        container.override(\.singletonService) { SimpleService(id: "singleton-override") as any ServiceProtocol }

        let resolved = container.singletonService
        #expect(resolved.id == "singleton-override")
        #expect(resolved.id != original.id)
    }

    @Test("override(keyPath:) on a cached-scoped property overrides correctly")
    func keyPathOverrideOnCachedScope() {
        let container = TestContainer()

        // Populate the cached cache first
        let original = container.cachedService

        // Override should take precedence over cached value
        container.override(\.cachedService) { SimpleService(id: "cached-override") as any ServiceProtocol }

        let resolved = container.cachedService
        #expect(resolved.id == "cached-override")
        #expect(resolved.id != original.id)
    }

    @Test("override(keyPath:) on a property using unimplemented works correctly")
    func keyPathOverrideOnUnimplementedProperty() {
        let container = TestContainer()

        // Without override, accessing the property would fatalError. The
        // override must prevent that — including during key discovery, whose
        // probe runs the override factory, never the unimplemented() factory.
        container.override(\.unimplementedProxy) { SimpleService(id: "wired") as any ServiceProtocol }

        let resolved = container.unimplementedProxy
        #expect(resolved.id == "wired")
    }
}
