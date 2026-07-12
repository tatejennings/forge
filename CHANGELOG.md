# Changelog

All notable changes to Forge are documented here. This project adheres to
[Semantic Versioning](https://semver.org). While the framework is in the `0.x`
series, breaking changes are released as minor version bumps.

## [0.6.0] - 2026-07-11

Released as a minor (not patch) bump per this file's 0.x policy: the fix changes
observable override behavior in addition to fixing the stripped-build bug.

### Fixed

- **KeyPath overrides were silently mis-keyed in symbol-stripped builds, crashing
  consumer apps at launch.** On all previous versions, `override(_:with:)`,
  `removeOverride(for:)`, and the `withOverrides` builder derived their storage key
  by parsing the KeyPath's description. In archived builds (`STRIP_INSTALLED_PRODUCT`,
  i.e. TestFlight/App Store — but not Xcode Debug *or* Release runs, which is why it
  escaped local testing) that description degrades to `<computed 0x… (Type)>`, the
  override was stored under a key that can never match, and resolution fell through
  to the real factory — for `unimplemented()` cross-module proxies, a launch crash.
  Overrides are now keyed by a task-scoped capture: registering evaluates the
  property once and the `provide` call matching the property's type reports the key
  it was actually called with, so the key always matches resolution regardless of
  build settings. **Workaround on ≤ 0.5.1:** set `STRIP_STYLE = debugging` on the
  app target (verified to preserve KeyPath descriptions).
- `override(\.x)` on a property registered with an explicit `key:` argument now
  works (it previously mis-keyed silently, for the same reason).

### Changed

- The first registration for a given KeyPath runs the override factory once (as the
  key-discovery probe); its value is discarded. Overrides are still resolved fresh
  on every resolution and never cached. Consequences: tests counting
  override-factory invocations should expect one extra call on the first
  registration (1 + resolutions), and composition-root wiring closures execute at
  wiring time — prefer capturing an already-resolved real over read-through
  closures, and wire cross-dependent proxies in dependency order.
- `override(\.x)` targeting a property whose getter never calls `provide(...)`
  with the property's own type now traps in all build configurations with a
  descriptive message (previously it registered a dead override silently). A
  same-type alias (`var alias: any P { backing }`) does not trap — it is
  discovered as its backing registration, so overriding the alias overrides
  `backing` container-wide.
- Key discovery runs no user code while the container lock is held (the capture
  is task-local, not lock-guarded state), keeps resolution's hot path at a single
  lock acquisition, and supports nested registration (an override factory that
  registers another override).
- `removeOverride(for:)` for a KeyPath that was never used to register an override
  is a documented no-op. KeyPath-based removal matches by KeyPath identity,
  including the root type: remove with a KeyPath rooted at the same type the
  override was registered with; string-keyed `_storeOverride` registrations are
  removed with `_removeOverride(key:)`.
- `Sources/Forge/Internal/KeyPathName.swift` (the description-parsing helper) is
  deleted; no public API signatures changed.

### Added

- Stripped-binary regression harness (`scripts/stripped-override-test.sh` +
  `IntegrationTests/StrippedOverrideRepro/`): builds a release executable, strips it
  the way an archive would, and asserts the KeyPath override APIs still resolve.
  Runs as a CI job — regular test bundles are never stripped, so the ordinary test
  suite cannot cover this failure mode.

## [0.5.1]

Tagged release covering documentation and Claude Code plugin updates. No CHANGELOG
entry was published for this version. Ships the same override implementation as
0.5.0, including the stripped-build mis-keying bug fixed in 0.6.0.

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

[0.6.0]: https://github.com/tatejennings/Forge/releases/tag/0.6.0
[0.5.1]: https://github.com/tatejennings/Forge/releases/tag/0.5.1
[0.5.0]: https://github.com/tatejennings/Forge/releases/tag/0.5.0
[0.4.0]: https://github.com/tatejennings/Forge/releases/tag/0.4.0
