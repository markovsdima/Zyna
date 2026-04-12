# Zyna — Critical Rules

iOS messenger: AsyncDisplayKit (Texture) + GRDB + matrix-rust-sdk.
Full conventions in CONVENTIONS.md — read it when working on
unfamiliar areas. This file has only the pitfalls that break things.

## Pitfalls

- **`UIImage(systemName:)` returns nil off-main.** Texture creates
  nodes on background threads. Use `AppIcon` (pre-rendered
  `static let`) instead.
- **`ASDisplayNode.init()` runs off-main.** Put gesture recognizers,
  `view`/`layer` config, anything UIKit into `didLoad()`, not `init()`.
- **`SDK uniqueId` is not stable** across Timeline recreation.
  TimelineDiffBatcher uses `eventId` collision resolution.
- **Main thread is sacred.** DB reads, parsing, image decoding,
  model construction — all off-main. `DispatchQueue.main` only
  for the final UI mutation step.
- **Zyna span carrier:** custom event data rides in `formatted_body`
  as `<span data-zyna="{...}">`. SDK's HTML sanitizer strips it —
  we parse raw event JSON directly.

## Project facts

- Xcode uses **folder references**, not groups. New files on disk
  are picked up automatically — no pbxproj edits needed.
- Custom navigation: `ZynaNavigationController` (not
  `UINavigationController`), `ZynaTabBarController` (not
  `UITabBarController`). Child VCs use `zynaNavigationController`
  / `zynaTabBarController` parent-chain accessors.
- US English in comments and identifiers (`color`, not `colour`).
- Commits: conventional style (`feat:`, `fix:`, `chore:`), title
  ≤ 72 chars, body at natural line breaks (not hard-wrapped).
- User commits manually; Claude does NOT commit unless asked.
