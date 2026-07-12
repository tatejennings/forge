// Exercises the KeyPath override APIs in a binary that the harness script strips
// before running. Mirrors the composition-root wiring pattern that crashed
// consumer apps on Forge <= 0.5.1: in a stripped binary, "\(keyPath)" degrades to
// "<computed 0x… (Type)>", the override was stored under that garbage key, and
// resolution fell through to unimplemented() -> fatalError (observed as a
// TestFlight-only launch crash).
//
// Under the buggy implementation this process dies in unimplemented(); under the
// key-capture implementation it prints OK and exits 0.

import Foundation
import Forge

protocol AnalyticsProtocol: Sendable {
    var id: String { get }
}

struct LiveAnalytics: AnalyticsProtocol {
    let id = "live-analytics"
}

final class FeatureContainer: Container, SharedContainer, @unchecked Sendable {
    static let shared = FeatureContainer()

    // Cross-module proxy, wired by the "composition root" below.
    var analytics: any AnalyticsProtocol {
        provide(.singleton) { unimplemented("analytics") }
    }

    // Explicit-key registration — overridable only via key capture.
    var customKeyed: any AnalyticsProtocol {
        provide(.singleton, key: "legacy.analytics") { unimplemented("customKeyed") }
    }
}

// Diagnostic mode for the harness script: print the raw KeyPath description so
// the script can verify this binary really exhibits the degraded
// "<computed 0x… (Type)>" form the regression test exists to cover.
if CommandLine.arguments.contains("--describe-keypath") {
    print("\(\FeatureContainer.analytics)")
    exit(0)
}

func check(_ condition: Bool, _ label: String) {
    guard condition else {
        print("FAIL: \(label)")
        exit(1)
    }
    print("ok: \(label)")
}

// 1. override(_:with:) — the wiring path that broke in stripped builds.
FeatureContainer.shared.override(\.analytics) { LiveAnalytics() }
check(FeatureContainer.shared.analytics.id == "live-analytics", "override(_:with:) resolves in stripped binary")

// 2. Explicit-key property.
FeatureContainer.shared.override(\.customKeyed) { LiveAnalytics() }
check(FeatureContainer.shared.customKeyed.id == "live-analytics", "explicit-key override resolves in stripped binary")

// 3. withOverrides builder path.
var sawBuilderOverride = false
FeatureContainer.shared.withOverrides {
    $0.override(\.analytics) { LiveAnalytics() }
} run: {
    sawBuilderOverride = FeatureContainer.shared.analytics.id == "live-analytics"
}
check(sawBuilderOverride, "withOverrides builder resolves in stripped binary")

// 4. removeOverride round-trip: after removal the proxy would trap again, so we
//    only verify a re-registered override still lands on the same key.
FeatureContainer.shared.removeOverride(for: \.analytics)
FeatureContainer.shared.override(\.analytics) { LiveAnalytics() }
check(FeatureContainer.shared.analytics.id == "live-analytics", "removeOverride + re-override round-trip")

print("OK")
