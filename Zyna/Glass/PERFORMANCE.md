# Glass Capture Performance

Implementation reviewed at commit `a2342a2` on September 22, 2026.
Covers gradient caching, capture scheduling, and device measurements on
iOS 26.3. See [RESEARCH.md](RESEARCH.md) for historical capture experiments
and [PORTAL.md](PORTAL.md) for portal behavior.

## Decisions

| Change | Outcome |
| --- | --- |
| Gradient image cache | Reduced portal substitution cost; retained. |
| CPU/GPU overlap | Glass GPU: about 65–72 → 120 commands/s; retained. |
| Capture buffer ownership | Required for safe overlap. |
| Per-submission `autoreleasepool` | Retained; isolated benefit not measured. |
| Background drawable acquisition | No consistent A/B benefit; removed. |

Glass rendering throughput increased from about 65–72 to 120 GPU command
completions per second. These figures describe the glass pipeline;
overall chat scrolling FPS was not measured.

Texture/Core Animation can continue scrolling the chat while the glass
shows its last rendered frame. The earlier glass throughput therefore
does not imply that chat scrolling ran at 65–72 FPS. Device checks showed
smoother menu dismissal under the glass, with no visual artifacts observed
in the tested scenarios.

## Static gradient cache

On screen, the compositor still renders bubble backgrounds through
portals. During CPU capture, `BubblePortalCaptureRenderer` substitutes
the portal source manually. Previously, each bubble invoked
`sourceLayer.render(in:)` for the shared gradient on every capture.

[BubbleGradientCanvasView][gradient] stores one `CGImage` per source
instance. Capture draws it with the existing mask and coordinate mapping.
The cache holds the gradient's local content: scrolling, shrink, swipe,
and reparenting do not themselves require a new image.

Correctness rules:

- The bounds size and origin, resolution, and color space must match the
  capture requirements. A sharper image can serve a lower scale. Scale
  rounds up to an integer so small transform noise does not rebuild the
  image every frame.
- Theme color or gradient size changes invalidate the cache. Memory
  warnings and removal of the source from its window also release it.
- Local source or gradient animations use direct layer rendering.
  Presentation layers also require matching gradient geometry, colors,
  and stop locations before the cached image can be used.
- An incompatible source, unsupported color space, or image creation
  failure falls back to direct layer rendering.
- Each raster is limited to 8,388,608 pixels, approximately 32 MiB of RGBA
  data before overhead. This limit applies per source.

Images are rasterized in the destination color space. The cache key
includes that space, so captures in different spaces do not reuse a raster.

## Overlapping capture and GPU work

Previously, a busy renderer stopped the tick before CPU capture. With an
8.33 ms period, the previous command often had not released its buffers
by the next tick, so glass missed an opportunity to update.

[GlassService](GlassService.swift) can now capture the next frame into a
free buffer while the GPU reads the previous one.
[GlassRenderer](GlassRenderer.swift) keeps at most one submitted GPU
command and one pending frame. New frames replace the pending frame;
stale frames do not accumulate. Once the GPU command completes, its
callback submits the pending frame on main without waiting for a new tick.

`nav` and `input` retain separate captures. Their results are drawn by the
shared renderer for the corresponding host container. UIKit/Texture
capture remains on main, including view and layer tree traversal.

### Buffer ownership is part of the algorithm

[GlassCaptureBuffer.swift](GlassCaptureBuffer.swift) enforces these rules:

1. Each registration ID and capture size has a pool of two buffers.
   Equal-sized anchors do not share writable memory.
2. CPU capture selects only buffers without GPU readers. Alternating
   indices alone is insufficient: retaining an `MTLTexture` does not stop
   `CGContext` from overwriting its shared memory.
3. `GlassCaptureReadLease` retains the buffers when a command is submitted.
   Completion releases the lease on main even if the renderer is gone.
   Repeated `release()` calls are safe. Reader counts allow two hosts to
   read one buffer temporarily while an anchor moves between them.
4. Pending frames in every host are discarded before writing a new
   capture. They do not yet hold read leases; their old geometry must not
   be submitted with pixels that have since been overwritten. A drawable
   resize also discards pending geometry and requests a fresh capture.
5. Capture is deferred when both buffers are busy. The renderer does not
   receive an incomplete set of bars, since the first pass's clear could
   otherwise erase the missing glass bar.
6. Each buffer's `generation` increases after capture. The blur cache
   checks both texture identity and generation. This prevents stale blur
   after overwriting the same texture, including when a render-only frame
   replaces a pending capture frame.

The device path remains zero-copy: `CGContext → MTLBuffer → MTLTexture`.
Intel simulator uses a separate texture and `replace()`.
The pool cache has a soft 96 MiB budget. Pools used in the current tick
are not evicted. A registration's last capture and active leases can
retain evicted buffers, so the budget does not cap all live memory.

## Drawable acquisition and autoreleasepool

`nextDrawable()` runs synchronously on main. Each submission, including a
pending frame submitted from completion, is wrapped in `autoreleasepool`.
Temporary Objective-C references are released after submission instead of
waiting for the outer autorelease pool.

The background queue experiment started drawable acquisition before CPU
capture. However, a control run on the same code with that path disabled
retained about 120 GPU completions/s and short drawable waits. No separate
benefit from the queue was established. The provider, its metrics and
dedicated tests, and the `GLASS_ASYNC_DRAWABLE` flag were removed.

Both branches of this comparison already used `autoreleasepool`. Its
isolated contribution is therefore unproven and would require a separate
A/B test.

## Measurements

All series below used an iPhone 16 Pro Max running iOS 26.3, a Debug build,
`thermal=0`, `lowPower=false`, and a requested period of about 8.33 ms.
The scenarios were short messages with occasional images and long text
messages.
Scrolling was manual; these are recorded runs rather than a deterministic
benchmark. Other devices and energy consumption were not measured.

Calculations include full logging windows with `spanSec >= 2.9`. Rates
use total events divided by total `spanSec`; mean times are weighted by
the corresponding sample counts. Per-window p95 values are not averaged.
Raw benchmark logs are not checked into the repository. Window IDs below
identify the samples from each run.

### Portal source substitution cost

`sourceRender`, mean milliseconds per capture of the corresponding bar.
This includes all source substitutions in that capture.

| Scenario / bar | Cache off | Cache on |
| --- | ---: | ---: |
| Short / nav | 0.326 | 0.054 |
| Short / input | 0.649 | 0.122 |
| Long / nav | 0.337 | 0.046 |
| Long / input | 0.598 | 0.087 |

Cache on: windows `#5–13` / `#15–25`; off: `#4–12` / `#15–23`, for short
and long scenarios respectively. This stage became roughly 5–7 times
cheaper. Total capture improved less because tree traversal, text, images,
and other composition remain. The cache alone did not eliminate skipped
ticks while the renderer was busy.

### Throughput with CPU/GPU overlap

The gradient cache was enabled in all three series below.

| Scenario / series | Glass GPU completions/s | Capture ticks/s |
| --- | ---: | ---: |
| Short, before overlap | 65.31 | 63.85 |
| Short, initial overlap | 119.52 | 109.60 |
| Short, final sync + pool | 119.56 | 113.08 |
| Long, before overlap | 72.40 | 71.53 |
| Long, initial overlap | 119.66 | 113.50 |
| Long, final sync + pool | 119.72 | 111.11 |

Short / long windows: before overlap `#4–11` / `#13–22`, initial overlap
`#10–17` / `#18–25`, final sync `#3–9` / `#11–15`.
The final series was recorded before removing the async code, with
`GLASS_ASYNC_DRAWABLE=0`. No separate device measurement followed cleanup.

GPU commands include render-only frames, so their rate differs from the
fresh capture rate. Higher throughput does not imply that an individual
frame takes half as long: stages overlap, and the CPU performs more useful
captures per second.

### Async drawable control

Both paths used overlap, the gradient cache, and `autoreleasepool`.

| Scenario / drawable | Glass GPU completions/s | Main wall time, ms/s |
| --- | ---: | ---: |
| Short / async | 119.76 | 492.9 |
| Short / sync | 119.56 | 474.3 |
| Long / async | 119.69 | 465.7 |
| Long / sync | 119.72 | 479.1 |

Async windows: `#25–30` / `#31–38`; sync: `#3–9` / `#11–15`.
Main wall time includes waits within the measured main-thread sections.
There was no consistent async advantage.

## Reproducing the measurements

Profiling is compiled out by default, including hooks, timers, and
submission metadata. All instrumentation requires
`#if DEBUG && GLASS_PROFILING`. The recorded runs above had profiling
compiled in and `.glassPerf` enabled.

1. Use the same build configuration, device, theme, and chat. Check thermal
   state and Low Power Mode in the log header.
2. Add `GLASS_PROFILING` to the project's Debug **Active Compilation
   Conditions**. Preserve the existing conditions and `$(inherited)`;
   the app and test targets must inherit the same profiling condition.
   Rebuild. This is a compilation flag, not a scheme environment variable.
3. Enable `.glassPerf` in `LogConfig.enabled` and filter the console by
   `GLASSPERF`. Reports aggregate roughly three seconds of samples;
   sorting and formatting run on a utility queue. The log scope can stop
   collection without rebuilding, but only removing the compilation flag
   removes the hooks themselves.
4. Repeat sustained scrolling for both scenarios. Keep short tails after
   scrolling stops separate from full windows of active scrolling.
5. Change one setting per run and restart the app: flags are read once.
   Repeat A/B/A to check that the result holds.

| Debug environment variable | Effect of `0` |
| --- | --- |
| `GLASS_GRADIENT_CACHE` | Render the gradient directly instead of caching. |
| `GLASS_CAPTURE_OVERLAP` | Skip capture/render while the renderer is busy. |

Both optimizations default to enabled and are always enabled in Release.
Release excludes profiling even if `GLASS_PROFILING` is defined.
The overlap flag retains the new buffer ownership even at `0`, so it
compares scheduling rather than restoring the entire old implementation.

Reading the logs:

- `callbackGap` measures display link cadence; `gpuN / spanSec` measures
  accepted GPU completions. Neither measures displayed FPS. Completions
  arriving after a logging window closes are excluded from its `gpuN`.
- `captureTicks` counts ticks with at least one capture; `bar=... n` counts
  capture attempts for a specific bar. Check `failedCaptures` as well.
- With overlap, `busyTicks` does not mean dropped frames: the CPU can
  capture while the GPU is busy. Also inspect `queued` and `discarded`.
- `cpuTick` excludes rendering from completion. Total measured main wall
  time requires both sums: `avg(cpuTick) * ticks` plus
  `avg(queuedRenderCPU) * queuedRenderN`, divided by `spanSec`.
- Drawable wait is also split between `drawableWait` inside the tick and
  `queuedDrawableWait` when submitting a pending frame.
- `pipeline=capture` and `pipeline=renderOnly` separate different kinds of
  work. `tickToGPUend` measures latency, not throughput.
- `imageDraws`, `cacheBuilds`, and `cacheBuildTotalMs` identify cache use
  and rebuilds. Evaluate cold start separately.

## Correctness checks

After removing the async path and fixing pending frames on resize,
49 tests in eight suites passed on iOS Simulator in both normal Debug and
Debug with `GLASS_PROFILING`. These checks cover correctness; performance
measurements came from the physical device logs.

- [GlassCapturePipelineTests][pipeline-tests]: busy buffers, multiple
  readers, equal-sized anchors, pool eviction, latest-frame submission,
  blur generations, resize, and host removal. Latest-frame submission is
  checked without profiling hooks in a normal Debug build, and with
  collection enabled and disabled in a profiling build. Blur checks use
  actual encoded pass counts instead of elapsed time.
- [BubblePortalCaptureRendererTests][portal-tests]: cached and direct
  rendering during scroll, shrink, reparenting, affine transforms, and
  viewport prediction; cache invalidation and animated gradient fallback.
- Also checked: `ScrollRenderingTests`, `ContextMenuDismissalTests`,
  `GlassCaptureAnimationTests`, `GlassCaptureScaleAnimationTests`,
  `GlassCaptureViewportAnimationTests`, and `DisplayLinkDriverTests`.

[gradient]: ../Chat/Nodes/BubbleGradientSource.swift
[pipeline-tests]: ../../ZynaTests/GlassCapturePipelineTests.swift
[portal-tests]: ../../ZynaTests/BubblePortalCaptureRendererTests.swift
