# Xcode Preview Support

Provide preview-safe mock factories that activate automatically in Xcode Previews.

## Overview

Dependencies that hit the network, access the file system, or perform heavy
computation are problematic in Xcode Previews. Forge lets you provide a `preview`
factory that is used automatically when running inside a preview — no conditional
checks needed in your view code.

## The preview Parameter

Pass a `preview` closure to ``Container/provide(_:key:_:preview:)`` alongside the
normal factory:

```swift
public var authService: any AuthServiceProtocol {
    provide(.singleton) {
        AuthService(network: self.networkClient)
    } preview: {
        MockAuthService()
    }
}

public var networkClient: any NetworkClientProtocol {
    provide(.singleton) {
        URLSessionNetworkClient()
    } preview: {
        MockNetworkClient()
    }
}
```

When the code runs inside an Xcode Preview, `MockAuthService()` is returned. In
production, `AuthService(network:)` is returned.

## How Preview Detection Works

Forge detects the preview environment by checking for the `XCODE_RUNNING_FOR_PREVIEWS`
environment variable, which Xcode sets to `"1"` when rendering previews. This is the
standard detection mechanism used across the Swift community.

### Resolution Precedence

When ``Container/provide(_:key:_:preview:)`` is called, resolution follows this order:

1. **Overrides** — always checked first (test overrides take priority)
2. **Preview factory** — used if running in a preview and a `preview` closure was provided
3. **Normal factory** — the default production path

## Preview Values Are Never Cached

Preview factories are called fresh on every resolution, regardless of the declared
``Scope``. Even if a dependency is registered as `.singleton`, the preview factory
runs every time in a preview context. This ensures previews always reflect the latest
mock state.

## When to Provide a Preview Factory

**Provide one for:**
- Network clients and API services
- Database and file system access
- Analytics and logging services
- Any dependency that performs I/O or has side effects

**Skip it for:**
- Pure in-memory services (formatters, validators, parsers)
- Simple value types or data transformations
- Dependencies that already work correctly without network access

## Multiple Preview Variants

Use different overrides within `#Preview` blocks to show different states:

```swift
#Preview("Logged In") {
    AuthContainer.shared.override(\.authService) {
        MockAuthService(isLoggedIn: true)
    }
    return ProfileView()
}

#Preview("Logged Out") {
    AuthContainer.shared.override(\.authService) {
        MockAuthService(isLoggedIn: false)
    }
    return ProfileView()
}

#Preview("Error State") {
    AuthContainer.shared.override(\.authService) {
        MockAuthService(shouldFail: true)
    }
    return ProfileView()
}
```

This lets you preview the same view in multiple states without changing any production
code.

> Note: The first `override(\.authService)` for a KeyPath runs its closure once
> at registration to discover the property's storage key — here that just builds
> one extra discarded `MockAuthService`, which is harmless. See
> ``OverridableContainer/override(_:with:)`` for the discovery rules.

## Testing Preview Behavior

The framework includes an internal `_isPreviewOverride` property (accessible via
`@testable import`) that lets tests simulate the preview environment:

```swift
@testable import Forge

PreviewContext._isPreviewOverride = true
defer { PreviewContext._isPreviewOverride = nil }

// Dependencies now use their preview factories
let service = MyContainer.shared.authService
// service is MockAuthService
```

> Note: Tests using `_isPreviewOverride` must be marked `.serialized` to prevent
> data races, since this is a global mutable state.
