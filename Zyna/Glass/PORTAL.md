# Portal Notes

> Findings from portal experiments around chat glass and bubble rendering.

## What Worked

- Portal-backed bubble backgrounds are useful as an on-screen compositor effect.
- A thin `BubblePortalBackgroundNode` over a shared `PortalSourceView` gives the right visual result in chat bubbles.
- Glass can capture the correct portal bubble color only through a manual fallback:
  - detect the bubble portal layer
  - resolve its `PortalSourceView`
  - render the source subtree manually under the same bubble mask

## What Did Not Work

- Generic `_UIPortalView` does not snapshot reliably through `layer.render(in:)`.
- Using a portal as a general-purpose glass source did not produce a usable backdrop:
  generic `_UIPortalView` rendered empty in our manual capture paths.
- `drawHierarchy` on a portal host was much slower and still did not give a usable result.
- Whole-chat proxy/snapshot-tree experiments did not beat direct table capture in a reliable way.
- A proxy source that still carried real image bitmaps did not help image-heavy cases.

## Practical Rule

- Keep direct table capture as the real glass backdrop path.
- Use portals only where they are already cheap and visually correct on screen.
- Treat portals as a narrow special-case in capture, not as a universal backdrop replacement.

## Production Decision

- Bubble portal background:
  - kept
  - captured through manual source substitution
- Whole-chat portal/proxy backdrop source:
  - abandoned
  - not part of the production glass pipeline
