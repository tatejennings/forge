import Testing
import Foundation
@testable import Forge

@Suite("Override behavior")
struct OverrideTests {

    @Test("Override takes precedence over original factory")
    func overrideTakesPrecedence() {
        let container = TestContainer()
        container.override(\.transientService) { SimpleService(id: "overridden") as any ServiceProtocol }

        let resolved = container.transientService
        #expect(resolved.id == "overridden")
    }

    @Test("Override is NOT cached — each resolution calls the override factory")
    func overrideNotCached() {
        let container = TestContainer()
        let callCounter = Counter()
        container.override(\.singletonService) {
            let count = callCounter.increment()
            return SimpleService(id: "override-\(count)") as any ServiceProtocol
        }

        let first = container.singletonService
        let second = container.singletonService

        #expect(first.id != second.id)
        // 3, not 2: the first registration for a KeyPath runs the factory once as
        // the key-discovery probe (its value is discarded), then each resolution
        // runs it again — overrides are never cached.
        #expect(callCounter.value == 3)
    }

    @Test("removeOverride restores original factory behavior")
    func removeOverrideRestoresFactory() {
        let container = TestContainer()

        let original = container.singletonService
        container.override(\.singletonService) { SimpleService(id: "overridden") as any ServiceProtocol }

        let overridden = container.singletonService
        #expect(overridden.id == "overridden")

        container.removeOverride(for: \.singletonService)

        // Should return the cached singleton from before the override
        let restored = container.singletonService
        #expect(restored.id == original.id)
    }

    @Test("resetAll removes all overrides")
    func resetAllRemovesOverrides() {
        let container = TestContainer()
        container.override(\.transientService) { SimpleService(id: "overridden") as any ServiceProtocol }

        container.resetAll()

        let resolved = container.transientService
        #expect(resolved.id != "overridden")
    }

    @Test("withOverrides applies overrides within closure and restores after exit")
    func withOverridesSyncAppliesAndRestores() {
        let container = TestContainer()

        _ = container.transientService.id

        container.withOverrides {
            $0.override(\.transientService) { SimpleService(id: "scoped-override") as any ServiceProtocol }
        } run: {
            let inside = container.transientService
            #expect(inside.id == "scoped-override")
        }

        let afterId = container.transientService.id
        #expect(afterId != "scoped-override")
        // Transient creates new instances, so before and after won't match either,
        // but neither should be the override value.
    }

    @Test("withOverrides async variant works correctly")
    func withOverridesAsync() async throws {
        let container = TestContainer()

        try await container.withOverrides {
            $0.override(\.transientService) { SimpleService(id: "async-override") as any ServiceProtocol }
        } run: {
            // Perform an async operation to validate the async variant
            try await Task.sleep(for: .milliseconds(1))
            let inside = container.transientService
            #expect(inside.id == "async-override")
        }

        let after = container.transientService
        #expect(after.id != "async-override")
    }

    @Test("withOverrides restores overrides even when body throws")
    func withOverridesRestoresOnThrow() {
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

        // Override should be restored even after the throw
        let after = container.transientService
        #expect(after.id != "will-throw")
    }
}
