# Changelog

All notable changes to Forge are documented here. This project adheres to
[Semantic Versioning](https://semver.org). While the framework is in the `0.x`
series, breaking changes are released as minor version bumps.

## [0.5.2] - 2026-07-11

### Fixed

- **KeyPath overrides were silently mis-keyed in symbol-stripped builds, crashing
  consumer apps at launch.** On all previous versions, `override(_:with:)`,
  `removeOverride(for:)`, and the `withOverrides` builder derived their storage key
  by parsing the KeyPath's description. In archived builds (`STRIP_INSTALLED_PRODUCT`,
  i.e. TestFlight/App Store — but not Xcode Debug *or* Release runs, which is why it
  escaped local testing) that description degrades to `<computed 0x… (Type)>`, the
  override was stored under a key that can never match, and resolution fell through
  to the real factory — for `unimplemented()` cross-module proxies, a launch crash.
  Overrides are now keyed by a capture handshake: registering evaluates the property
  once and `provide` reports the key it was actually called with, so the key always
  matches resolution regardless of build settings. **Workaround on ≤ 0.5.1:** set
  `STRIP_STYLE = debugging` on the app target.
- `override(\.x)` on a property registered with an explicit `key:` argument now
  works (it previously mis-keyed silently, for the same reason).

### Changed

- The first registration for a given KeyPath runs the override factory once (as the
  key-discovery probe); its value is discarded. Overrides are still resolved fresh
  on every resolution and never cached. Tests that count override-factory
  invocations should expect one extra call on first registration.
- `override(\.x)` targeting a property that never calls `provide(...)` now traps
  in all build configurations with a descriptive message (previously it registered
  a dead override silently).
- `removeOverride(for:)` for a KeyPath that was never used to register an override
  is a documented no-op. (KeyPath-based removal only sees overrides registered
  through the KeyPath APIs.)
- `Sources/Forge/Internal/KeyPathName.swift` (the description-parsing helper) is
  deleted; no public API signatures changed.

### Added

- Stripped-binary regression harness (`scripts/stripped-override-test.sh` +
  `IntegrationTests/StrippedOverrideRepro/`): builds a release executable, strips it
  the way an archive would, and asserts the KeyPath override APIs still resolve.
  Runs as a CI job — regular test bundles are never stripped, so the ordinary test
  suite cannot cover this failure mode.

## [0.5.0] - 2026-06-07

### Breaking

- **`SharedContainer.shared` is now `{ get }` only** (was `{ get set }`), and
  `AppContainer.shared` is a `static let`. The shared instance is stable for the
  lifetime of the process and can no longer be reassigned. For test isolation, use
  `resetAll()` / `withOverrides(_:run:)` on the shared container instead of swapping
  it. (If you specifically want swap-based tests, you can still declare your own
  container's `shared` as a `static var` — the protocol requirement is only `{ get }`.)
- **Wrong-type overrides now fail loudly.** A type-mismatched override triggers an
  `assertionFailure` (crashing in debug/test builds) instead of silently falling
  through to the real factory. Release builds still fall through. A test that relied
  on the old silent fall-through will now crash in debug — fix the override's return
  type.

### Changed

- **`Forge.defaultContainer` is now fully thread-safe.** Reads and writes are guarded
  by an internal lock, so it is safe to access from any thread. The previous "set it on
  the main thread before any background work" restriction is lifted (configuring it once
  at startup is still recommended).
- `unimplemented(_:)` captures `#fileID` instead of `#file`, keeping absolute source
  paths out of diagnostics and release binaries.
- Documentation reframes "compile-time safe" as "compile-time-safe at the call site,
  with loud, fail-fast runtime checks underneath."

### Added

- CI workflow running the full test suite across Swift 5.10 / 6.0 / 6.1 / 6.2 on Linux
  and macOS. This is the safeguard for the KeyPath name-extraction format that the
  override system depends on.
- **Strict-concurrency CI job** compiling the library with
  `-strict-concurrency=complete -swift-version 6`, plus `StrictConcurrency` enabled on
  the target itself — Forge builds with no concurrency warnings under the Swift 6
  language mode. (`Container` stays `@unchecked Sendable` because it is `open`; the
  conformance is sound — all mutable state lives behind the lock.)
- Scope-contract tests asserting factory invocation counts: `.transient` builds on
  every resolution, `.singleton` / `.cached` build exactly once (including under
  concurrent first resolution via a 1000-way race), and `.cached` rebuilds after
  `resetCached()`.
- README "Known constraint" note documenting the KeyPath string-interpolation
  dependency, and a "Thread safety" section.

### Notes

- `.singleton` and `.cached` resolution is **exactly-once**: the factory runs inside a
  recursive lock, so a side-effectful initializer never runs more than once even when
  multiple threads race to resolve it for the first time.

## [0.4.0]

Tagged release covering documentation and Claude Code plugin updates. No CHANGELOG was
published for this version.

[0.5.2]: https://github.com/tatejennings/Forge/releases/tag/0.5.2
[0.5.0]: https://github.com/tatejennings/Forge/releases/tag/0.5.0
[0.4.0]: https://github.com/tatejennings/Forge/releases/tag/0.4.0
