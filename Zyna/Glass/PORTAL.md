# Portal Notes

Current behavior at commit `a2342a2`. See [PERFORMANCE.md](PERFORMANCE.md)
for gradient caching, capture scheduling, and device measurements.

## Current capture path

On screen, `BubblePortalBackgroundNode` uses a private `_UIPortalView`
to display a shared `PortalSourceView` through the compositor. The CPU
capture path does not reproduce that portal content with `layer.render`.

`BubblePortalCaptureRenderer` substitutes the background during capture:

1. Identify the bubble portal layer and resolve its source.
2. Map the source into the bubble's coordinates and apply its mask.
3. Draw the cached gradient image when eligible; otherwise render the
   source layer directly.

This substitution follows presentation geometry and active capture
predictions during scrolling, shrink, swipe, and menu dismissal. It does
not change the on-screen portal.

The glass backdrop comes from direct capture of the chat table. Portal
substitution handles bubble backgrounds within that capture; there is no
whole-chat portal or proxy source in the production pipeline.

## Earlier experiments

The following results describe the tested configurations, not guarantees
about every portal or iOS version:

- Generic `_UIPortalView` content rendered empty in the tested manual
  capture paths. It did not provide a usable general glass backdrop.
- `drawHierarchy` on a portal host was slower and did not produce a usable
  result in those tests.
- Whole-chat proxy and snapshot-tree experiments did not establish a
  consistent advantage over direct table capture. Proxies carrying real
  image bitmaps did not improve the tested image-heavy cases.

These alternatives were not retained. Further historical experiments are
recorded in [RESEARCH.md](RESEARCH.md).
