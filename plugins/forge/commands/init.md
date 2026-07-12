---
description: Add Forge to the current project and scaffold the first AppContainer extension or custom Container.
argument-hint: "[simple|modular]  # optional setup style; auto-detected if omitted"
---

You are running `/forge:init` to add the Forge dependency injection framework to the user's project. The argument (if provided) is `$ARGUMENTS` — either `simple` (extend `AppContainer`), `modular` (custom `Container` per module), or empty (auto-detect).

Use the `using-forge` and `forge-modular` skills as the authoritative source for conventions.

## Steps

1. **Inspect the project structure.** Apply the "Which path am I in?" decision rule from the `using-forge` skill (the authoritative wording).
   - Look for `Package.swift`, `.xcodeproj`, or `.xcworkspace` at the working directory and one level down.
   - Count the number of `.target(...)` / library targets in any `Package.swift` files.
   - Single target → suggest `simple` setup unless the user passed `modular`.
   - Multiple targets / workspace → suggest `modular` unless the user passed `simple`.
   - If Forge code already exists, detect from the code, not just the target count: any custom `Container` subclass, module-local `typealias Inject<T> = ContainerInject<…>`, `unimplemented()`, or composition-root wiring means Modular — an `AppContainer` extension alone does not.

2. **If the setup style is still ambiguous, ask the user** (one question, multi-choice):
   - Simple — extend the built-in `AppContainer`. Best for single-target apps.
   - Modular — one `Container` per module, composition root in the app target. Best for SPM workspaces or large apps.

3. **Add the Forge SPM dependency.**
   - If a `Package.swift` is present, add to `dependencies:` and to the target's `dependencies:`:
     ```swift
     .package(url: "https://github.com/tatejennings/Forge.git", from: "0.1.0")
     ```
     Target dependency: `.product(name: "Forge", package: "Forge")`.
   - If an Xcode project is present (no `Package.swift`), explain that the user needs to add the package via Xcode (File → Add Package Dependencies…) and provide the URL. Do not attempt to edit `.xcodeproj` files directly.

4. **Scaffold the container file.**
   - **Simple style:** create `<MainTargetDir>/DI/AppContainer+DI.swift` with:
     ```swift
     import Forge

     extension AppContainer {
         // Add your dependencies here as computed properties.
         // Example:
         // var networkClient: any NetworkClientProtocol {
         //     provide(.singleton) { URLSessionNetworkClient() }
         // }
     }
     ```
   - **Modular style:** create `<ModuleDir>/<ModuleName>Container.swift` with:
     ```swift
     import Forge

     typealias Inject<T> = ContainerInject<<ModuleName>Container, T>

     final class <ModuleName>Container: Container, SharedContainer {
         static let shared = <ModuleName>Container()

         // Add your dependencies here.
     }
     ```
     AND scaffold the app target's composition root `<AppTarget>/CompositionRoot.swift`:
     ```swift
     import Forge
     // import your feature + service modules

     // MARK: - Target-level services (OPTIONAL — only if the app target owns any)
     // extension AppContainer { /* register here */ }

     // MARK: - Composition root — call once from App.init()
     func wireContainers() {
         // Wire each feature container's `unimplemented()` proxy to the real impl
         // owned by its module container. Resolve the real first, then wire the
         // captured value (the first registration per KeyPath runs its closure
         // once as a key-discovery probe, so a read-through closure would resolve
         // the real at wiring time anyway), e.g.:
         // let x = ServicesContainer.shared.x
         // FeatureContainer.shared.override(\.x) { x }
     }
     ```
     Note `AppContainer` is optional in a modular app — a thin app target whose modules
     own everything never extends it.
   - Match the target's existing folder conventions if there's an obvious DI / Dependencies folder. Otherwise create a `DI/` folder.

5. **Report what you did.**
   - Files created.
   - Whether SPM was updated automatically or the user needs to add the package in Xcode.
   - Next steps: `/forge:add-dependency <name>` to register the first dependency.

## Idempotence

- If `Forge` is already in `Package.swift`, skip the add and say so.
- If the scaffolded file already exists with non-comment content, do NOT overwrite. Print the existing path and ask the user whether to merge or skip.

## Do not

- Run `swift build` or `swift test` — leave that to the user.
- Edit `.xcodeproj` files directly.
- Add example dependencies unrelated to what the user has actually expressed interest in.
