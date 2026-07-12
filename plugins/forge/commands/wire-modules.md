---
description: Generate composition-root wiring in the app target for cross-module unimplemented() proxies declared in per-module Forge containers.
---

You are running `/forge:wire-modules` to ensure the app target's composition root overrides every `unimplemented(...)` proxy declared in per-module Forge containers. This is the wiring that turns a `unimplemented` default into a real implementation at app launch.

Use the `forge-modular` skill as the authoritative source for the pattern.

## Steps

1. **Discover containers and their `unimplemented` proxies.**
   - Find all `Container` subclasses across the workspace.
   - For each, find computed properties whose `provide(...)` body calls `unimplemented("<name>")`. These are the cross-module proxies that need wiring.
   - Record each finding as `(ContainerName, propertyName, expectedSource)` where `expectedSource` is the property name on `AppContainer` (or another container) that supplies the real implementation.

2. **Find the app target's composition root.**
   - Look for a file with `@main` and `App` conformance (SwiftUI) OR `@UIApplicationMain`/`AppDelegate` (UIKit).
   - The composition root is a standalone `wireContainers()` function (NOT a method on `AppContainer`), invoked from `App.init()` / `applicationDidFinishLaunching`.
   - If no obvious composition root exists, create a new file `<AppTarget>/CompositionRoot.swift` with a top-level `func wireContainers()`, and invoke it from the app's init / launch path.

3. **Discover the source container** (where the real implementations live).
   - Prefer the module container that owns each real (e.g. a Core/services module's
     own container). `AppContainer` is only the source for genuine *target-level*
     services the app itself owns; a thin modular app may not use `AppContainer` at all.
   - If multiple containers supply reals, resolve each proxy from its true owner.

4. **Generate the wiring lines.**
   - For each `(ContainerName, propertyName, expectedSource)`, generate the
     capture-first form — resolve the real once, then wire the captured value:
     ```swift
     let <propertyName> = source.<propertyName>
     <ContainerName>.shared.override(\.<propertyName>) { <propertyName> }
     ```
   - `source` is the owning module container that supplies the real, e.g.
     `let infra = InfrastructureContainer.shared` (or `AppContainer.shared` only if the
     app target itself owns the service).
   - Do NOT generate read-through closures (`override(\.x) { source.x }`): the first
     registration per KeyPath runs its closure once as a key-discovery probe, so a
     read-through closure resolves the real eagerly at wiring time anyway — the
     capture-first form makes that resolution explicit and keeps `wireContainers()`
     order-insensitive at a glance. If one source real transitively depends on a proxy
     wired by another line, order the capture lines so dependencies are wired first,
     and emit a `// NOTE(forge): wiring order matters here` comment.
   - If no source container has a property matching `<propertyName>`:
     - Look for fuzzy matches (e.g. `analyticsService` vs `analytics`).
     - If found, generate with the matched name and emit a `// NOTE:` comment recording the name mismatch so the user can confirm.
     - If not found, emit a `// TODO(forge): supply \(propertyName) from its owning module container` comment so the user can wire it.

5. **Insert the wiring idempotently.**
   - If a wiring line for the same `(Container, property)` already exists in the composition root, skip it.
   - Group wirings by container, alphabetical by property within each group, alphabetical by container name across groups — EXCEPT where a source real transitively depends on another proxy: its capture line must come after that proxy's wiring (see step 4's ordering note).

6. **Report what you did.**
   - Wirings discovered.
   - Wirings added.
   - Wirings skipped (already present).
   - Any `TODO` comments inserted (missing source properties).
   - Any `NOTE` comments inserted (fuzzy name matches that need user confirmation).

## Idempotence

- This command is designed to be re-runnable. Running it twice should produce no changes the second time.

## Do not

- Modify the per-module containers themselves — only the composition root.
- Invent source properties on `AppContainer`. If a source is missing, leave a `TODO` for the user.
- Reorder unrelated code in the composition root. Insert wirings as a contiguous block.
