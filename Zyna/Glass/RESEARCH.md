# Glass Capture Research and Architecture

Original research: March 22, 2026; deeper probes: March 24, 2026;
chat profiling update: April 22, 2026. The notes identify the device as
an iPhone 16 Pro Max running iOS 26.3.

The current architecture below was reviewed at commit `a2342a2`.
Everything under **Archived experiments** preserves earlier observations,
measurements, and hypotheses. Those probes were not rerun for this review;
their raw logs and complete setups are not included here. Private API
names, indices, and behavior describe those experiments only.

See [PERFORMANCE.md](PERFORMANCE.md) for recent optimization measurements
and [PORTAL.md](PORTAL.md) for bubble portal capture.

## Current architecture

The goal is to supply background pixels to a custom Metal shader with
control over blur, refraction, and chromatic aberration.

- Capture a selected `sourceView` without the glass UI. This avoids
  self-capture without the earlier overlay-window architecture.
- Keep navigation and input captures separate. A shared `GlassRenderer`
  and `CAMetalLayer` draw the bars for each host container.
- Capture on main through layer rendering and manual portal substitution.
  Eligible static gradients use cached images under the bubble mask.
- On the device, `CGContext → MTLBuffer → MTLTexture` shares memory.
  Intel simulator uses a separate texture and `replace()`.
- Overlap CPU capture with the previous GPU command. Each registration
  and capture size has two buffers; write only into a buffer without GPU
  readers. Read leases protect submitted buffers until completion.
- Each renderer keeps one submitted command and at most one pending
  frame. New pending frames replace older ones. Completion can submit the
  pending frame without waiting for another display-link tick.
- Use presentation geometry and capture predictions for moving content.
  Convert shared output placement through presentation layers as well.

The older rule “skip before capture whenever the renderer is busy” is
superseded by overlap. Buffer selection uses reader counts, not a blind
alternation of slots. Ownership, invalidation, memory limits, gradient
caching, and profiling controls are detailed in
[PERFORMANCE.md](PERFORMANCE.md).

### Capture triggers and lifecycle

`GlassAnchor.didMoveToWindow()` calls
`GlassService.shared.register(anchor:)`. Removing the anchor releases its
`GlassRegistration`; deinitialization deregisters it. `GlassService`
coordinates capture and the shared renderers. Basic usage:

```swift
let glass = GlassAnchor()
glass.cornerRadius = 20
glass.sourceView = contentView
someView.addSubview(glass)
// Remove with glass.removeFromSuperview().
```

`DisplayLinkDriver` requests up to 120 Hz; that is not a measured display
rate. Capture work is driven by:

- `setNeedsCapture()`: a one-shot request for scroll, layout, or content.
- `captureFor(duration:)`: a timed burst, including menu transitions.
- `anchor.isAnimating`: checks `animationKeys()` along the layer's
  ancestor chain, rather than comparing model and presentation frames.
- `GlassCaptureSource`: requires `needsGlassCapture` and intersection
  of the source frame with a glass region, e.g. for Lottie or GIF.

The display link stops after three idle ticks. A watchdog checks anchor
animations every 0.05 seconds; explicit requests also wake the driver.
No current idle CPU-cost measurement is claimed here.

## Archived experiments

### 1. Earlier backdrop capture path

The original notes described a working pre-iOS-26 sequence:

1. Create a view with `layerClass = CABackdropLayer`.
2. Call `layer.setValue(true, forKey: "windowServerAware")`.
3. Capture the backdrop using `drawHierarchy`.
4. Transfer pixels through `ZeroCopyBridge`
   (`CVPixelBuffer + IOSurface → MTLTexture`).

The accompanying model attributed backdrop acquisition to a Mach IPC
request to `backboardd`, which composited lower layers into an IOSurface.
This internal mechanism was an interpretation, not a verified trace.

On iOS 26.3, `windowServerAware` was absent from the inspected properties
and methods, and the earlier capture path did not work. The notes
attributed this to a Liquid Glass redesign using a single compositor
`glassBackground` pass, with speed and isolation benefits. That proposed
explanation, the exact removal version, and possible replacement paths
were not established by the probes.

### 2. Initial runtime probes

#### Probes 1–2: CABackdropLayer

The runtime dump reported **25 properties and 61 methods**:

- `windowServerAware`: not found.
- `enabled`: observed as `true`; `contents` remained `nil`.
- `captureOnly`: present, but did not expose captured contents.
- `groupNamespace = "owningContext"`.
- `scale = 0.25`: an observed configuration, not a universal default.
- `_mt_applyMaterialDescription:removingIfIdentity:`: found.
- `rasterizationPrefersWindowServerAwareBackdrops`: present on
  `CALayer`; setting it to `true` did not fix capture.

More than 30 candidate KVC keys were tried as possible replacements.
`contents` remained `nil` in the tested filter and setting combinations.

#### Probe 3: UIVisualEffectView

Observed hierarchy and filters:

- `subviews[0]`: `_UIVisualEffectBackdropView`, with
  `UICABackdropLayer`.
- `subviews[1]`: `_UIVisualEffectSubview`, described as the tint overlay.
- `gaussianBlur` and `colorSaturate` filters.

`drawHierarchy` returned `false` and a black image: **0/100 nonblack
samples**. Sample locations were not preserved; these counts should not
be interpreted as image coverage measurements.

#### Probe 4: CAFilter

`+[CAFilter filterWithType:]` created the following filter types:

`glassBackground`, `liquidGlass`, `glass`, `refraction`, `backdrop`,
and `materialBackground`.

Attaching them to `CABackdropLayer` did not yield a usable capture.
Availability of a filter name did not establish CPU capture support.

#### Probe 5: CAContext

- `CAContext.currentContext` returned `nil`.
- The window layer exposed `contextId = 0xc9157caf`
  (a value from that run, not a reusable identifier).
- `renderContext` and `createImageSlot:hasAlpha:` were found, but the
  experiment did not obtain a readable render surface through them.

#### Probe 6: Alternative snapshots

| Method | Recorded result |
| --- | --- |
| `window.drawHierarchy` | Returned `true`; 22/100 nonblack samples. |
| `hostView.drawHierarchy` | 11/100 nonblack samples. |
| `layer.render(in:)` | Partial content; 5/100 nonblack samples. |
| `CARenderer` | Empty pixels; reported duration 0.00 ms. |
| `UIScreen.snapshotView` | Black capture. |
| `window.snapshotView` | Black capture. |

The `CARenderer` result was originally described as a no-op. The rounded
duration and empty output do not establish that it cannot render in other
configurations.

#### Probe 7: drawHierarchy into a CVPixelBuffer context

The attempted `UIGraphicsPushContext` path did not write into the supplied
`CGContext`. `UIGraphicsBeginImageContextWithOptions` worked. An
intermediate `CGImage` was therefore needed in that experiment; this did
not rule out every possible buffer-sharing integration.

#### Probe 8: UIWindow.createIOSurfaceWithFrame:

This private selector returned an IOSurface usable as a Metal texture.
The archived invocation was:

```swift
let sel = Selector(("createIOSurfaceWithFrame:"))
typealias Func = @convention(c) (
    AnyObject, Selector, CGRect
) -> Unmanaged<AnyObject>?
let fn = unsafeBitCast(window.method(for: sel), to: Func.self)
let unmanaged = fn(window, sel, frame)
// IOSurfaceRef → device.makeTexture(iosurface:) → MTLTexture
```

The notes labeled the following benchmark as **ten iterations**:

| Case | Recorded mean |
| --- | ---: |
| Glass rect, 392 × 120 | 1.93 ms |
| Full window, 440 × 956 | 3.63 ms |
| Small rect, 50 × 50 | 0.88 ms |
| IOSurface + MTLTexture pipeline | 1.78 ms |
| Hide → capture → show cycle | 0.81 ms |

The last two rows lack region/setup details and are not additive to the
snapshot rows. These numbers are historical measurements, not current
glass frame costs.

The observed pixel format was `bgr10a2Unorm` (10-bit color, 2-bit alpha).
`makeTexture(descriptor:iosurface:plane:)` exposed the same surface
memory to Metal.

### 3. Self-capture and the earlier two-window solution

Window snapshots included the glass output, causing feedback that
converged toward gray. Results recorded for attempts to exclude it:

| Attempt | Recorded result |
| --- | --- |
| `layer.isHidden = true`, no flush | Gray feedback remained. |
| Hide + `CATransaction.flush()` | Gray feedback remained. |
| `layer.opacity = 0` + flush | Gray feedback remained. |
| Glass in an overlay window | Avoided feedback in this test. |

The notes interpreted this as capture of the committed render tree, with
uncommitted changes or render-server delay explaining the failed hiding
attempts. The exact timing mechanism was not independently established.

The resulting architecture put glass in a `PassthroughWindow` and
captured the main window with `createIOSurfaceWithFrame:`. It was later
replaced by source-view isolation and `layer.render` in one window.

### 4. April chat profiling and implementation changes

#### Capture and output

The April implementation retained separate `nav` and `input` captures.
A large union rectangle spanning the screen was more expensive in the
tested scene than two local regions with sublayer culling.

Two separate output `CAMetalLayer` instances showed a wait in
`nextDrawable()` for the second renderer. Changing render order moved
the wait between the bars. A shared output renderer was retained, and the
visible shaking was reported resolved.

At that stage, a busy renderer caused a skip **before CPU capture**.
The diagram called the buffer storage `CaptureCache` and described two
alternating slots. That historical scheduling and ownership description
is superseded by the current read leases and overlap.

Other recorded optimizations:

- A `CGContext` backed by `MTLBuffer(.shared)`, exposed through
  `buffer.makeTexture()`, avoided the CPU-to-GPU pixel copy.
- Capturing at 2× instead of 3× reduced pixel count by about 56%.
  The visual check reported no visible difference behind blur.
- Culling used intersection, `isHidden`, and `opacity`.
- `memset` replaced `ctx.clear()` for clearing capture memory.
- Intel simulator used `texture.replace()` as a fallback.
- Removing the blue underlay beneath portal bubbles removed observed
  artifacts; the notes also reported a small capture-cost reduction
  without an isolated measurement.

#### Navigation transition drift

The backdrop was correct, but the shared glass output quad lagged during
push/pop. `anchor.presentationFrame()` used presentation geometry while
the destination frame used `UIView.convert(...)` and model geometry.

The recorded fix converted through
`renderHostContainer.layer.presentation()` and
`window.layer.presentation()` when placing the shared output.

#### Historical timing summary

The April notes recorded these ranges on iPhone 16 Pro Max, iOS 26.3:

| Stage | Recorded time |
| --- | ---: |
| Navigation capture | Approximately 0.7–1.8 ms |
| Input capture | Approximately 1.5–3.5 ms |
| Shared render | Approximately 0.2–0.4 ms |
| Typical total | Approximately 3.7–5.6 ms |
| Occasional input capture spike, e.g. a large image | Up to 10 ms |

They described skipped busy ticks as nearly free and `pass/blur` timing
as tenths of a millisecond. CPU encoding time does not establish GPU
shader cost. The old “120fps” label was not backed by displayed-FPS
measurements in these notes.

Two other estimates are preserved here without treating them as verified
benchmarks: idle watchdog work of approximately **16 μs/s** (“~0% CPU”),
and a concluding **~1.8 ms total at 120fps** claim. Neither includes
enough measurement context to substantiate it or reconcile it with the
stage timings above. Current idle behavior and throughput are documented
separately.

Whole-chat portals and source proxies did not replace direct table
capture: generic `_UIPortalView` content was empty in the tested manual
capture path. Bubble backgrounds instead used a narrow fallback that
rendered `PortalSourceView` under the bubble mask.

### 5. Additional backdrop and render-server probes

#### MaterialKit and live backdrop configuration

The notes recorded successful `responds(to:)` checks for:

- `mt_applyMaterialDescription:removingIfIdentity:`.
- `_mt_configureFilterOfType:ifNecessaryWithFilterOrder:`.
- `_mt_setValue:forFilterOfType:valueKey:filterOrder:removingIfIdentity:`.

The initial runtime notes separately spelled the first selector with a
leading underscore. Both spellings are preserved; the discrepancy was
not resolved during this review.

Copying filters and KVC values from a live `UIVisualEffectView` backdrop
to a fresh `CABackdropLayer` left `contents = nil`. The live
configuration recorded in this probe was:

- `groupName = nil`, `groupNamespace = "owningContext"`.
- `scale = 0.25`.
- `luminanceCurveMap`, `colorSaturate`, and `gaussianBlur` filters.

The hypothesis was that `UIVisualEffectView` performed an additional
render-server registration, and MaterialKit configured style rather than
capture access. The failed copy did not verify that mechanism.

Found classes and selectors:

- `MTVisualStyling`: `initWithCoreMaterialVisualStyling:`,
  `applyToView:withColorBlock:`, and `_layerConfig`.
- `MTMaterialView`: `materialViewWithRecipe:configuration:`, which
  created system materials in the experiment.

The probes did not find `MTMaterialDescription`,
`MTCoreMaterialDescription`, `_MTBackdropCompoundEffect`, or
`_MTBackdropEffect`.

The observed layer hierarchy was
`UICABackdropLayer → CABackdropLayer → CALayer → NSObject`.
The dump reported `setValue:forKeyPath:` as the added method on
`UICABackdropLayer`, used inside `_UIVisualEffectBackdropView`.

#### UIWindow.createIOSurface without a frame

This returned a full-window **1320 × 2868** IOSurface in approximately
**2.69 ms**. The framed variant allowed a smaller requested region.

#### CARenderServerRenderDisplay

The C function was found through `dlsym`. The notes attributed the
following declaration to WebKit's `QuartzCoreSPI.h` and RecordMyScreen;
it is retained as the signature used by the probe, not a verified ABI:

```c
void CARenderServerRenderDisplay(
    mach_port_t port, CFStringRef displayName,
    IOSurfaceRef surface, int x, int y
);
// Probe: CARenderServerRenderDisplay(0, CFSTR("LCD"), surface, 0, 0);
```

The call completed without crashing in **1.56 ms**, but wrote no pixels.
The notes attributed this to sandbox restrictions and referred to the
jailbreak-based RecordMyScreen implementation. The failure's cause was
not established.

Also recorded as present in `QuartzCore.tbd`:
`CARenderServerCaptureDisplay`, `CARenderServerRenderLayer`,
`CARenderServerRenderDisplayExcludeList`, and
`CARenderServerCaptureDisplayExcludeList`. Symbol presence alone did
not establish working capture or the reason a call might fail.

#### _UIVisualEffectViewBackdropCaptureGroup

Recorded selectors and configuration:

- `initWithName:scale:`: create a group.
- `addBackdrop:update:`: add a backdrop view.
- `setCaptureGroup:`: attach it to `_UIVisualEffectBackdropView`.
- `scale` / `setScale:`: an observed system value was **0.125**.
- `updateAllBackdropViews`: request an update.

Creating a group and backdrop, then calling `setCaptureGroup:`,
`addBackdrop:update:`, and `applyRequestedFilterEffects`, left
`contents = nil`. Adding a backdrop to a live effect view's group had
the same result. The proposed deeper Mach IPC registration remained a
hypothesis; these tests did not establish a necessary activation sequence.

#### CAWindowServer

Accessing `CAWindowServer.server` and reading its displays crashed.
The earlier sandbox explanation was not verified.

### 6. Deeper probes: March 24, 2026

The original notes describe eleven phases of experiments on the same
device and OS.

#### Working model of the rendering pipeline

The investigation used this schematic to guide probes. Internal stages
and their relationships were not independently traced end to end:

```text
App process                      backboardd                GPU / display
UIView / CALayer
  → CATransaction.commit()
  → CA::Render::Encoder
  → Mach IPC ------------------> CA::Render::Decoder
    (IOSurface ports,            → compositor
     layer-tree changes)         → display IOSurface
                                   → IOMobileFramebuffer → screen
```

The IPC service was identified in the notes as
`com.apple.CARenderServer`. The conclusion that
`createIOSurfaceWithFrame:` was the *only* route back to app pixels was
not established by this investigation.

#### CA::Render and C entry points

None of 25 requested C++ mangled symbols resolved via `dlsym`, including
symbols sought for `CA::Render::Encoder`, `Decoder`, `Filter::encode`,
and `Object::decode`. The notes contrasted this with macOS exports, but
did not establish a complete iOS symbol inventory or removal history.

| Function | Recorded result |
| --- | --- |
| `CARenderServerGetPort` | Nonzero Mach port; roughly 30K–86K in runs. |
| `CARenderServerGetServerPort` | 0. |
| `CARenderServerRenderLayer` | Crash; call signature uncertain. |
| `CARenderServerRenderDisplayClientList` | Crash; signature uncertain. |
| `CARenderServerRenderDisplay` | No pixels written. |
| `CARenderServerCaptureDisplayClientList` | `nil`. |

#### CAFilter types, attributes, and render values

The probes reported **42 filter types**, including `glassBackground`,
`glassForeground`, `liquidGlass`, `refraction`, `glass`,
`chromaticAberration`, `chromaticAberrationMap`, `displacementMap`,
and `variableBlur`.

Values read from the private `_type` ivar:

| Filter | Decimal | Hex |
| --- | ---: | --- |
| `colorMatrix` | 113 | `0x71` |
| `colorSaturate` | 117 | `0x75` |
| `chromaticAberration` | 96 | `0x60` |
| `displacementMap` | 202 | `0xCA` |
| `gaussianBlur` | 280 | `0x118` |
| `glassBackground` | 283 | `0x11B` |
| `liquidGlass` | 867 | `0x363` |
| `refraction` | 868 | `0x364` |
| `glass` | 869 | `0x365` |

Test KVC keys were accepted through `setValue:forKey:` and stored in an
`_attr` dictionary. This did not identify which attributes the renderer
actually consumed.

`CA_copyRenderValue` (not `copyRenderValue:`) returned an opaque value
interpreted as a `CA::Render::Object*`. The notes described nested
objects as:

```text
displacementMap → glassBackground → chromaticAberration
                                      → vibrantColorMatrix
```

That interpretation is preserved without treating it as a verified binary
layout. No `registerFilter`, plugin mechanism, or loadable module path
was found. The stronger claim that custom filters were impossible because
of a compiled-in table was not established.

#### CAPortalLayer filter experiment

Configuration: `_UIPortalView` with
`layer.filters = [gaussianBlur(20)]`.

| Capture | Recorded result |
| --- | --- |
| `drawHierarchy` | 0% nonblack. |
| `layer.render` | 0% nonblack. |
| `createIOSurfaceWithFrame:` | 100% nonblack; 0% diff with/without blur. |
| Blur radius sweep, 0–50 | 0% diff at every step. |

The original interpretation was that portal redirection skipped
`filters` and `backgroundFilters`. The result applies to the tested
configuration; it does not prove that all portal filters are ignored.

#### _UIReplicantView and CASlotProxy

`UIScreen._snapshotExcludingWindows:withRect:` returned
`_UIReplicantView`:

- `layer.contents` was `CASlotProxy`, not IOSurface; recorded
  `CFTypeID = 1`.
- The proxy dump listed one ivar, `_proxy` (`void*`), and three methods:
  `initWithName:`, `CA_copyRenderValue`, and `dealloc`.
- `_UIReplicantLayer._slotId` was an opaque `_UISlotId` ObjC object.

The notes interpreted the proxy as a token for pixels held by
`backboardd`; they did not demonstrate direct pixel access through it.

The sequence “snapshot excluding windows → replicant → temporary window
→ IOSurface” produced pixels in **10.5 ms**, compared with **6.7 ms** for
a direct `createIOSurfaceWithFrame:` call in that comparison. The recorded
**101/100 nonblack** count is internally inconsistent and is preserved as
an unresolved logging or transcription error, not a valid sample count.

#### IOSurface global scan

`IOSurfaceLookup(id)` returned surfaces in the tested app environment.
Scanning IDs **1–2000** found **three surfaces**, all **1320 × 471**.
None matched the full-screen **1320 × 2868** dimensions, and neither
their seeds nor pixels changed during observation. Their attribution to
system UI was a hypothesis.

Surfaces from `createIOSurfaceWithFrame:` also stayed unchanged during
observation, with **seed = 1**. IDs were reused after release, suggesting
a pool. The scan did not establish global framebuffer availability or
prove kernel/entitlement restrictions on `IOMobileFramebuffer`; those
were explanations proposed in the original summary.

#### Context-ID capture

`+[UIWindow createIOSurfaceWithContextIds:count:frame:]` returned
**100/100 nonblack samples** in **1.53 ms**, compared with **1.11 ms**
for `createIOSurfaceWithFrame:` in that experiment.

Also recorded as available, without separate timing results:

- `+createIOSurfaceWithContextIds:count:frame:outTransform:`.
- `+createIOSurfaceWithContextIds:count:frame:usePurpleGfx:outTransform:`.
- `+createIOSurfaceOnScreen:withContextIds:count:frame:baseTransform:`.

#### ReplayKit

The `RPScreenRecorder.startCapture` run recorded:

- **6633 ms** to the first frame, including the consent dialog.
- About **21 fps**, at **884 × 1920**.
- A working `IOSurface`-backed `CVPixelBuffer → MTLTexture` path.

That run did not meet the desired 120 Hz cadence. The observed rate and
startup delay are not general ReplayKit limits.

Additional SPI names noted for investigation: `setWindowToRecord:`,
`checkContextID:withHandler:`, and `pauseInAppCapture`.

#### Timing figures from the original cross-method summary

The original summary also listed framed IOSurface snapshots at roughly
**1–5 ms**, `layer.render(in:)` at roughly **5–7 ms**, and
`IOSurfaceLookup` as “instantaneous” without a numeric duration. The
regions and workloads were not recorded alongside those summary figures,
so they cannot rank the methods under equivalent conditions.

### 7. Research conclusions and limits

The retained capture strategy was direct source-layer rendering into
buffer-backed memory, with culling and explicit portal substitution.
The experiments also found usable window IOSurface snapshots, but their
self-capture behavior led to an extra overlay window in that prototype.

Several original conclusions went beyond the recorded evidence:
universal sandbox explanations, Apple's redesign motives, the absence of
every possible live capture route, and “App Store-safe.” They are not
supported conclusions of this archive. The observations above preserve
what was tried and what it returned, including unsuccessful probes that
may be worth revisiting with a different setup or OS.

## Historical reading

These links were collected during the original investigation. They are
background material, not verification of current iOS behavior.

- [CAPluginLayer and CABackdropLayer — Aditya Vaidyam][backdrop]
- [The Secret Life of Core Animation — Aditya Vaidyam][core-animation]
- [ShatteredGlass — AlexStrNik][shattered-glass]
- [LiquidGlassKit — DnV1eX][liquid-glass-kit]
- [VariableBlurView — aheze][variable-blur]
- [iOS Rendering Docs — EthanArbuckle][rendering-docs]
- [Reverse Engineering NSVisualEffectView — Oskar Groth][visual-effect]
- [WebKit QuartzCore SPI change][webkit-spi]
- [RecordMyScreen capture implementation][record-my-screen]
- [On-Device Render Debugging — Bryce Bostwick][render-debugging]

The original notes cited LiquidGlassKit as corroborating an iOS 26.2
breakage. That attribution was not rechecked in this review.

[backdrop]: https://aditya.vaidyam.me/blog/2018/02/17/
[core-animation]:
  https://medium.com/@avaidyam/the-secret-life-of-core-animation-e0966f942a71
[shattered-glass]: https://github.com/AlexStrNik/ShatteredGlass
[liquid-glass-kit]: https://github.com/DnV1eX/LiquidGlassKit
[variable-blur]: https://github.com/aheze/VariableBlurView
[rendering-docs]: https://github.com/EthanArbuckle/ios-rendering-docs
[visual-effect]:
  https://oskargroth.com/blog/reverse-engineering-nsvisualeffectview
[webkit-spi]:
  https://www.mail-archive.com/webkit-changes@lists.webkit.org/msg104923.html
[record-my-screen]:
  https://github.com/coolstar/RecordMyScreen/blob/master/RecordMyScreen/CSScreenRecorder.m
[render-debugging]: https://bryce.co/on-device-render-debugging/
