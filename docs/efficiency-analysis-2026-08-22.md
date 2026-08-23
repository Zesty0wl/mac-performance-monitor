# Live chart performance deep dive: 2026-08-22

## Executive summary

After the fixed-window ("scrolling strip chart") rework and the new 250 ms and
500 ms refresh choices, the app's CPU with the window open climbed to roughly
30%, and selecting 250 ms did not visibly deliver 4 Hz. This pass profiled the
running app, reproduced the cost offscreen, and fixed the pipeline so that the
three rules hold together:

1. Every live chart is a fixed trailing window that scrolls right to left as
   samples arrive (the newest sample anchors the right edge, anything older
   than the window falls off the left).
2. The charts update at the dial rate, including 4 Hz.
3. The per-tick cost is constant, independent of how long the app has run or
   how many samples the window holds.

Headline numbers (M-series MacBook Pro, release build, 250 ms dial, 1 h window):

| Measure | Before | After |
| --- | --- | --- |
| Dashboard, all live surfaces, 14,400 samples in window (host harness) | 44.8 ms per tick (~18% CPU at 4 Hz) | 17.0 ms per tick (~7%) |
| Same, Canvas drawing only (ImageRenderer harness) | 26.1 ms per tick | 3.0 ms per tick |
| Metric cards row alone, 14,400 samples | 23.9 ms per tick | 7.0 ms per tick |
| One timeline alone, 14,400 samples | 10.5 ms per tick | 4.7 ms per tick |
| Dashboard at 1,200 samples (5 min window) | 5.4 ms per tick | 12.9 ms per tick (see note) |
| Real app, SwiftUI transaction per Dashboard tick (xctrace) | 35 ms mean, 55 ms max | not re-measured (screen locked) |
| Real app, window occluded, 250 ms dial, 1 s logging, five-metric strip (top, 30 s) | 11.0% | 5.4% (tick diagnostics: 4.00 Hz achieved, process 5.7 to 6.6%, main thread 1.4 to 1.9%) |
| Real Dashboard page, 14,400 samples, table publishing at 1 Hz (host harness, fourth pass) | 17.0 ms per tick | 7.9 ms per tick (~3%) |
| Real Processes tab, 600 rows, one 1 Hz table update (host harness, fourth pass) | 44 ms (SwiftUI `Table`) | 23 ms (AppKit outline view) |
| Real Dashboard page, 14,400 samples, seeded window, table at 1 Hz (host harness, fifth pass) | 19 to 21 ms per tick (~8%) | 7.9 to 8.8 ms per tick (~3.2%), of which ~2.3 ms is the charts |
| Real app, window open on the Dashboard, 250 ms dial (top, 30 s, display on) | 53% | 14.8% before the renderer and relayout fixes; those measured a further 20 to 25% off with the display asleep (see the fourth pass) |
| Real app, window open (Processes tab), 250 ms dial, display on (tick diagnostics, fifth pass) | | 4.00 Hz, process 9.9 to 11.7%, main thread 6.5% |
| Real app, Processes tab, rows on screen at the dial rate, menu bar at the dial rate (sixth pass) | | 4.00 Hz, process 11.3%, main thread 6.5%; menu bar accounts for ~4% of main thread |

Note on the 1,200-sample row: the before figure is a window that had only just
started filling. The old pipeline's cost grew linearly with the window (5 ms at
1,200 samples, 45 ms at 14,400); the new one is flat at 13 to 17 ms in the host
harness whatever the window holds, and about 3 ms of that is actual drawing.
The remaining host-harness cost is SwiftUI's update and layout pass for five
charts and six cards, which the harness pays in full on every tick.

All 413 package tests pass and `swift format lint --strict` is clean.

## What was measured, and how

The installed build 196 (identical source to this working tree before the
changes) had been running for 24 hours with the window open on the Processes
tab, inspector open, dial at 250 ms, high-resolution logging at 1 s, and the
combined menu bar strip showing five metrics.

| Situation | CPU (top, 20 to 30 s mean) | RSS |
| --- | --- | --- |
| Window open (Processes tab + inspector), 250 ms | 29.4% to 31.5% | ~500 MB |
| Same app with the screen locked (window occluded, so process consumers released) | 11.0% | 243 MB |

Tools used, all reproducible from the repo:

- `sample <pid> 10` and a small tree analyser (busy samples per thread, pruned
  call tree). Sampler queue: ~3% of busy samples. Main thread: ~92%.
- `xctrace record --template SwiftUI --attach <pid>` with the
  `swiftui-update-groups`, `swiftui-updates`, and `time-profile` tables
  exported and aggregated. This is what attributed the per-tick cost to its
  causes (below).
- The new offscreen harness: `--benchmark-charts` (see "Measuring" below).
- The new opt-in tick diagnostics in the unified log (see "Measuring").

## Where the time went

From the 43 s SwiftUI trace of the real app (main thread, inclusive):

| Cause | Share of main-thread time |
| --- | --- |
| `DashboardTimelineStore.points.setter` transactions: 163 at 35 ms mean, 55 ms max | 13% of wall time on its own |
| `StackLayout` / `LayoutComputer` (SwiftUI layout) | 30% / 24% |
| `SizeFittingLayoutComputer` + `LazyStack` (the `ViewThatFits` over an HStack and a `LazyVGrid` in `MetricCardsRow`) | 19% |
| `AppKitOutlineTableCoordinator` / `NSTableView` (the 600-row process table, 1 Hz on the Processes tab) | 20% |
| `ScrollViewUtilities` (re-measuring the page's scroll content) | 15% |
| `CA::Transaction::commit` | 12% |
| `CombinedMenuBarImage` + `MenuBarReadoutImage` + `NSBitmapImageRep` (re-rasterising the menu bar strip at 4 Hz) | 5% |
| Canvas text resolution (axis labels) | 4% |
| `MetricCard` / `Sparkline` / `MetricChart` bodies | 3% / 1.4% / 1.6% |
| Actual Core Graphics drawing (`CGContextDrawPath` and friends) | under 1% |
| `ProcessDetailView.appendNewData` (inspector, 1 Hz): 26 transactions at 34 ms | 2% |
| `MenuListsModel.topFootprint.setter`: closed popovers still re-rendering at 1 Hz | 0.6% |

The important conclusion: drawing the lines was never the problem. The cost was
SwiftUI layout work triggered per tick, O(window) data handling per tick per
surface, and a few things that had no business running at 4 Hz.

### Specific findings

1. **The window grew without bound at subsecond dials.** Raw windows were no
   longer downsampled (so the open bucket would not reshape), and the live
   store appended every 4 Hz sample. An hour at 250 ms is 14,400 points; every
   chart and every card mapped and drew all of them, every 250 ms. This is why
   the app looked fine after launch and crept up over the hour.
2. **The store copied the whole window per tick** (`var next = points` plus
   `removeFirst`), once for every published change.
3. **`ViewThatFits` in `MetricCardsRow` measured both candidate layouts** (an
   HStack and a LazyVGrid) on every update, and the lazy grid rebuilt its items
   while being measured. At 4 Hz this was the largest single layout cost.
4. **`Sparkline` was a `Path` shape view.** SwiftUI hashes and diffs a shape's
   path in the display list on every update; with 14,400 segments per card
   that was far dearer than drawing it.
5. **Copying `SystemHistoryPoint` is not a memcpy.** The struct carries a
   resilient `Date` and five optionals, so every per-metric pass that pulled
   elements out of the array paid for value-witness copies. Even after
   decimation this dominated: 13 passes over 14,400 samples cost ~20 ms.
6. **Generic `View` structs ran unspecialised.** Making the chart wrappers
   generic over their point collection routed their bodies through the protocol
   witness, with per-element witness calls and struct copies. Same for a
   non-inlinable generic helper in Core called from the app.
7. **The menu bar strip re-rasterised at 4 Hz.** Its five readouts (network
   rates above all) change nearly every tick, defeating the signature check,
   and each render looked up SF Symbols and built fonts from descriptors.
8. **Closed popovers kept re-rendering.** Their hosting controllers stayed
   alive and observed the menu lists, so every table tick re-rendered hidden
   panels.
9. **The 4 Hz timer lost ticks while the window was open.** The per-process
   scan (libproc over ~600 processes plus the helper XPC round trip, 100 to
   300 ms) ran inline on the timer queue. A strict `DispatchSourceTimer`
   coalesces fires its handler missed, so at 250 ms roughly one tick in four
   disappeared whenever a scan ran, and the main thread's 35 to 55 ms
   transactions bunched the rest. That is the "we don't update at 4 Hz".
10. **`smoothedCPU` was recomputed on every read** (a per-core average over the
    5 s ring) by each status item and view, several times per tick.

Also observed, not changed here (see "Remaining work"): the Processes tab costs
about 20% of main-thread time at the 1 s table floor, the inspector's five
Swift Charts re-render at 1 Hz, and high-resolution logging at 1 s keeps the
process scan at 1 Hz even with everything closed.

## What changed

### Data path (MacPerfMonitorCore)

- `SystemHistoryWindow`: a trailing window stored column by column
  (`timeIntervalSinceReferenceDate` doubles plus one `[Double]` per metric),
  head-index trimming, amortised O(1) append, zero-copy `ArraySlice` reads, and
  one pre-window sample retained so a line enters from the left edge. This is
  what gives rule 1 exactly: a new sample pushes everything left and whatever
  has scrolled past the window is dropped.
- `LiveSeriesDecimator`: per-bucket minimum and maximum in time order, the
  classic oscilloscope reduction. Every spike survives at pixel resolution and
  the output is at most two points per bucket. A generic element-based form
  (`@inlinable`, so clients specialise it) and a columnar fast path.
- Tests for both, including a cross-check that the columnar and generic
  decimators agree on 14,400 samples.

### Rendering (MacPerfMonitor)

- `LiveColumn` / `LiveTrend`: chart wrappers take either a window column
  (Dashboard) or a small point array (Disk, Energy, Network tabs) and reduce to
  720 buckets before building `TrendPoint`s. No generics in views.
- `TrendChart`: two `Canvas` layers. The value axis, its labels and the
  threshold rules live in an `Equatable` layer SwiftUI leaves alone between
  ticks; the series and the moving time axis are in the live layer, which also
  decimates to the plot's pixel width as a backstop. Gap detection has a
  no-copy fast path.
- `Sparkline`: a `Canvas`, decimated to the card's pixel width for timestamped
  live traces.
- `MetricCardsRow`: picks a single row or a wrapped grid from the measured
  width (`onGeometryChange`) instead of `ViewThatFits` over a `LazyVGrid`.
- `MemoryMetrics.cards`: built from the window's columns (including the
  derived free column) with fixed scales computed once per range load.
- `DashboardTimelineStore`: owns the `SystemHistoryWindow`, publishes only a
  version counter; Y scales are cached at load time rather than rescanned per
  leaf per tick.

### Sampling and menu bar

- `SamplerModel`: the per-process scan runs on its own serial `scanQueue`;
  the 250 ms system tick publishes immediately and never waits behind a scan.
  `finishScan` hops back to the sampler queue for persistence, alerts and the
  process UI, with an in-flight guard so scans never pile up and a forced
  (pressure event) scan is remembered rather than dropped. `Sampler`'s two
  halves already kept disjoint state, so the split is safe; every `Sampler`
  call that touches the process side is dispatched to the scan queue.
- `smoothedCPU` is computed once per tick.
- `AlertEngine.evaluateLeaks` no longer builds a display name for every
  process on every table tick; names are resolved only for a leak that is
  about to be announced.
- `menuBarTick`: `liveTick` throttled to about 1 Hz for the status item
  images (the figures are 5 s averages; the popover charts keep the full rate).
- `CombinedMenuBarImage` caches configured SF Symbols; `MenuBarReadoutImage`
  caches fonts.
- Status item controllers release their popover (and its SwiftUI graph) when
  it closes, so hidden panels stop re-rendering.

## Measuring

Two new tools, both permanent:

- **Offscreen chart benchmark.** Launch the binary directly:

      "build/Mac Performance Monitor.app/Contents/MacOS/Mac Performance Monitor" \
          --benchmark-charts --scenario dashboard --points 14400 --span 3600 \
          --interval 0.25 --ticks 40 --mode host

  `--mode host` drives an `NSHostingView` through a published store (SwiftUI
  update + layout + commit per tick); `--mode image` renders through
  `ImageRenderer` (the Canvas drawing alone). Scenarios: `dashboard`, `trend`,
  `cards`, `menu`. It works with the screen locked, which is how the after
  numbers above were taken.

- **Tick diagnostics.**

      defaults write uk.co.bzwrd.macperfmonitor diagnostics.tickStats -bool YES
      log stream --predicate 'subsystem == "uk.co.bzwrd.macperfmonitor"' --info

  Every 30 s the sampler logs the achieved tick rate against the target, mean
  and worst cost of the system tick, the scan and the main-thread publish, and
  the process and main-thread CPU over the period. Delete the default to turn it
  off.

## Second pass (same day)

The remaining-work list from the first pass was worked through, in payoff order:

- **Processes inspector charts.** `MetricChart` is now a thin wrapper over the
  Canvas `TrendChart`, which gained what the inspector needed: hover/drag
  scrubbing with a read-out of the nearest point, a relative "now / 15m / 1h"
  time axis at fixed positions, a plot border, and an explicit gap threshold
  (the inspector splits its raw series before downsampling and passes the runs
  as separate series). The bucket-peak downsampling and gap rules are
  unchanged. Harness, five charts over an hour of 1 s samples at 1 Hz:
  **10.9 ms per tick** (host) and **1.4 ms** of drawing, against the 34 ms per
  tick the SwiftUI trace recorded for the Swift Charts version.
- **Wall-clock axis labels** are SwiftUI `Text` views keyed by their tick time
  and positioned each tick; the Canvas no longer resolves label text on every
  redraw. A single timeline at 14,400 points went from 4.7 to about 3 to 4 ms
  per tick in the host harness.
- **The Dashboard page no longer observes the model.** It reads the model
  through an unobserved `\.samplerModel` environment value for its own calls
  (history loads, the live tick), and every live read-out (system subtitle,
  processor stats, cores, composition, network and disk rates) is a leaf that
  observes the model itself. A table tick now re-renders a handful of leaves,
  not the page and its `ScrollView`.
- **The database insert runs on the scan queue**, decided on the timer queue
  (where the persist clock lives) and written right after the scan; the
  checkpoint and retention bookkeeping stay on the timer queue. The 250 ms tick
  never waits on the ~15 ms write.
- **`DiskReader` keeps its IOKit handles.** `BlockStorageEnumerator` walks the
  `IOBlockStorageDriver` services every 5 s (or as soon as a statistics read
  fails, so hot-plug still works within a tick) and the per-tick read is one
  property fetch per disk. The sampler queue's busy samples fell from 84 to 30
  per 10 s in the locked-screen profile, with the disk reader no longer visible.
- **`NetworkInfoReader` caches its configuration half** (SystemConfiguration
  service names and types, the global primary/router/DNS, the host name,
  CoreWLAN radio details) for 5 s; only `getifaddrs` runs every poll. The
  Network tab polls at the dial, down to 250 ms, and `Host.current()` alone was
  far too dear for that.
- **`AlertEngine.evaluateLeaks`** resolves display names only for a leak that
  is about to be announced, instead of for every process on every table tick.
- **Settings** now says what 1 s high-resolution logging costs (a per-process
  scan every second even with the window closed).

Locked-screen runtime check of this build (window occluded, 250 ms dial, 1 s
logging): 4.00 Hz achieved, 5.4 to 6.3% process CPU over 30 to 40 s, main
thread about 2%.

## Third pass: the Processes tab at its 1 s cap

The table is capped at one update per second by design (it follows
max(dial, 1 s)). This pass made that update cheaper rather than rarer. A new
harness scenario (`--scenario processes --interval 1`) mounts the real
Processes tab (processor header, 600-row table, inspector open) against a
`SamplerModel` that a synthetic scan publishes into each second, which made the
cost measurable with the screen locked:

| Scenario (host harness) | Before | After |
| --- | --- | --- |
| Processes tab, 600 rows, inspector open, 1 Hz | 43.7 ms per tick | ~37 ms per tick |
| Inspector alone (five charts, 3,600 samples), 1 Hz | 11.8 ms | 7.6 ms |
| Main-thread busy samples in 10 s of the Processes scenario | 359 | 261 |

What changed:

- **The row sort.** `sorted(using:)` over the table's `KeyPathComparator`s
  applied each key path dynamically on every comparison: about 5 ms per second
  for 600 rows (14% of the tab's main-thread time). Each comparator is now
  matched to its column once and an index permutation is sorted, so the
  200-byte samples are not shuffled. Strings keep the comparators' localized
  standard ordering; an unknown column falls back to the comparator.
- **The inspector page no longer observes the model.** `ProcessDetailView`
  reads the model through `\.samplerModel`; its chart series live in a store
  observed only by the charts leaf, and the header, description and details
  are leaves that observe the model themselves. The glossary description (a
  longest-match scan of the glossary) is resolved once per process and
  glossary version instead of on every tick, and the details card's
  `DateComponentsFormatter` is built once.
- **Auto-scaled axes snap to a nice ceiling** (`LiveChartGeometry.niceCeiling`:
  1, 1.2, 1.5, 2, 2.5, 3, 4, 5, 6, 8 or 10 times a power of ten, so the data
  still fills at least ~75% of the plot). The inspector's and any auto-scaled
  timeline's static axis layer now holds still between ticks instead of
  re-resolving its labels for every new peak.
- A `dashboardPage` harness scenario mounts the real `DashboardView`, which
  confirms the non-observing page works end to end (about 17 ms per tick in
  the host harness at 4 Hz with the table also publishing at 4 Hz, 3.9 ms of
  drawing).

What remains on this tab is the SwiftUI `Table` itself (the AppKit coordinator
diff and NSTableView reload, about 7 ms per update) and the header and
inspector leaves' layout, which is the cost of a live 600-row table at 1 Hz.

## Fourth pass: AppKit surfaces for everything that moves

After the third pass the app still sat at 26% with the Dashboard open and the
Processes tab was not reaching 4 Hz on its header and charts. The question
that framed this pass was "how does a game repaint at 60 Hz when we cannot
draw a table at 4 Hz?", and the answer is the rendering model, not the
drawing. A game owns a buffer and writes pixels from its data; the per-frame
cost is proportional to pixels. SwiftUI is retained-mode: every update is a
diff of a view tree, then layout, then a display-list rebuild, and the cost is
proportional to the number of views touched. Three things made that expensive
here:

- Any leaf update inside a `ScrollView` re-measured the whole page
  (`StackLayout`, `ScrollViewUtilities` in the profile) because the scroll
  content's size depends on every child, even ones whose size cannot change.
- SwiftUI's `Table` is an AppKit `NSTableView` behind a coordinator that
  diffs every cell view on every update: about 4 ms per visible row, 140 ms a
  second for a 35-row viewport at 1 Hz once the inspector and header were
  added.
- Swift Charts views (the core grid, the memory taxonomy bar) re-laid their
  marks on every tick.

So the fourth pass takes SwiftUI out of the per-tick path altogether. SwiftUI
still builds the page chrome (panels, titles, sheets, the range picker), but
every element whose content changes on a tick is now an AppKit view fed
directly from the store:

- **Feeds and surfaces.** `TrendFeed` / `TrendSurfaceView` (timeline charts),
  `MetricCardFeed` / `LiveSparkline` + `LiveValueLabel` (cards), `TextFeed` /
  `LiveText` (stat read-outs), `CoreGridFeed` / `CoreGridSurface` (per-core
  bars) and `TaxonomyFeed` / `TaxonomySurface` (memory composition). A feed
  holds the latest model and a list of observers; publishing is a field
  assignment plus `needsDisplay = true` on the surface. The SwiftUI wrapper
  (`NSViewRepresentable`) only attaches the view to its feed once; its
  `updateNSView` does nothing on a tick because nothing in the SwiftUI tree
  changes.
- **`DashboardTimelineStore`** owns the `SystemHistoryWindow`, appends the
  tick, decimates each column and publishes into the feeds. Its only
  `@Published` values are `rangeVersion` and `hasEnoughHistory`, which change
  when the user picks a range or the first window fills, so the page body and
  its leaves re-evaluate a handful of times per session, not per tick.
- **`ProcessOutlineTable`** replaces the SwiftUI `Table` with an
  `NSOutlineView`. In flat (unsorted-by-group) mode the rows are slot items
  updated in place and only the visible cells are refreshed; cells lay
  themselves out manually and skip redraws whose text, icon and colour are
  unchanged. A naive `reloadData` cost 140 ms per update; this costs about
  23 ms for 600 rows, still capped at 1 Hz.
- **`MetricChart`** (inspector) is a `TrendChart` wrapper, and the inspector
  page reads the model through the `\.samplerModel` environment key instead
  of observing it.

### Renderer costs, once drawing was the only cost left

With SwiftUI out of the loop the Dashboard profile was almost entirely Core
Graphics, and three things in the renderer were worth fixing:

- **Label drawing.** `NSAttributedString.draw(at:)` runs the Cocoa text
  layout engine on every call; at a few dozen axis and legend labels per tick
  it was about a fifth of a chart's draw time. `ChartLabelCache` now caches a
  `CTLine` per label and style and draws it with `CTLineDraw`; colours are
  resolved when the entry is made and the cache is cleared on an appearance
  change.
- **Round joins.** A 1,200-vertex polyline with round joins and caps adds arc
  geometry at every vertex. Bevel joins and butt caps are indistinguishable
  at 1.5 pt and stroke noticeably faster.
- **Backing store format.** On this wide-gamut display AppKit gave each
  drawing view a 16-bit float backing store, and `sample` showed `draw(_:)`
  being recorded into a display list that Core Animation replayed into that
  store on every commit (`CABackingStoreUpdate_` > `CGDisplayListDrawInContext`
  > `RGBAf16_mark_*`, about 60% of the main thread). Asking for `RGBA8Uint`
  (`LiveSurfaceView`, the shared base of the four surfaces) draws straight into
  the store; nothing here uses extended-range colour.
- A flat fill instead of the gradient under each line, and a fill clipped
  without anti-aliasing, were both tried and made no measurable difference
  (harness or live), so the gradient stays as it was.

### What the harness could not see: the window relayout cascade

With the renderer fixed, the real window still ran at 17 to 18% main thread
(22 to 24% process) with the Dashboard open, against the harness's 3%. A
`sample` of the live app showed why: every tick ended in a full layout pass
of the `NSHostingView` (`NSHostingView.layout`, `_willUpdateConstraintsForSubtree`,
`SizeConstraints.update`), which re-solved the window's Auto Layout
constraints and, through `preferencesDidChange`, rebuilt the window toolbar
(`ToolbarBridge.makeStorage`, `AppKitToolbarStrategy.makeContent`,
`NSToolbarView layout`, new item views added to the toolbar), about 30 ms per
tick. The harness window is borderless with no toolbar, so there the same
pass cost under a millisecond and went unnoticed.

The trigger was `NSTextField`: `setStringValue:` calls
`invalidateIntrinsicContentSize`, and SwiftUI's representable host treats any
intrinsic-size invalidation from its platform view as "re-lay out the whole
hosting view". The live read-outs (`LiveTextField`, `LiveValueField`) have a
fixed height and no intrinsic width, so the invalidation carried no
information. They now override `invalidateIntrinsicContentSize` to drop it
(a font change, the one thing that can alter the size, lets it through
explicitly). Main thread with the window open fell from 17.2 to 18.3% to
10.9 to 13.5%, process from 22 to 24% to 19%, measured with the display
asleep (see the numbers below for why that matters).

The rule this adds to the architecture: an AppKit view fed at tick rate must
never let AppKit's layout system hear about the update. `needsDisplay` is the
only signal it may raise; anything that reaches `invalidateIntrinsicContentSize`,
`needsLayout` or `needsUpdateConstraints` turns a 2 ms repaint into a window
relayout.

### Numbers

Host harness, real `DashboardView` with 14,400 samples in the window and the
table publishing at 1 Hz, quiet machine, median of runs:

| Step | ms per tick | CPU at 4 Hz |
| --- | --- | --- |
| Third pass (SwiftUI page with leaf observers) | 17.0 | ~7% |
| Live surfaces, first cut | 15.5 | ~6% |
| + `CTLine` labels, bevel joins | 9.4 | ~3.8% |
| + 8-bit backing store | 7.9 | ~3.1% |

Of the remaining 8 ms about 2.4 ms is the harness's own synthetic 1 Hz table
publish (trails, smoothing, row rebuild), 2 ms is the five chart surfaces'
`draw(_:)`, about 2 ms is Core Animation committing and clearing the layers,
and under 1 ms is SwiftUI (the `onReceive` hop into the store).

Real Processes tab with 600 rows: 10.5 ms per tick mean at 4 Hz with the 1 Hz
table, and a 0.7 ms median, so the three ticks in four that do not touch the
table are essentially free.

Real app, window open on the Dashboard, `top` over 30 s at the 250 ms dial:
53% at the start of the day, 26% after the third pass, 17.4% with the AppKit
table, 14.8% with the first live surfaces, all measured with the display on.
The renderer steps and the relayout fix landed after the display had gone to
sleep, and in that state the same builds read higher (the first-surfaces
build showed 31 to 34% with the display asleep against 14.8% awake: AppKit
re-records and replays the layers of a window that has no screen to be on),
so the later figures are only comparable with each other: 22 to 24% process
(17 to 18% main thread) before the relayout fix, 17 to 19% process (9 to
13.5% main thread) after it, still holding 4.00 Hz. What is left on the main
thread in that profile is Core Animation rasterising the five chart layers
(`CABackingStoreUpdate_` > `CGDisplayListDrawInContext` > `aa_render`), which
is the cost of repainting five retina-resolution area charts four times a
second; the remaining levers (fewer columns per chart, stroke-only series, or
repainting charts at 2 Hz while sampling at 4 Hz) all trade fidelity, so they
are left as choices rather than made here. The tick diagnostics default is
still set on this Mac, so a `log show` after the screen is back on gives the
awake figure directly. With the window closed the build holds 4.00 Hz at
5.6 to 7.6% process CPU (2.0 to 2.4% main thread) with 1 s logging on, which
is the scan and the database, not the UI.

## Fifth pass: strip charts that scroll instead of repainting

With SwiftUI out of the tick path and the relayout cascade fixed, the main
thread's remaining work with the Dashboard open was Core Graphics
rasterising the chart layers four times a second, and every one of those
repaints produced almost the same pixels as the one before, shifted left by
a fraction of a point. This pass makes the charts scroll the way a chart
recorder does: paint each column once, slide it.

### How it works

- **`LiveStripBuckets` (Core)** reduces a raw column to per-bucket extremes
  with buckets anchored to absolute time (`bucket b` covers `[b*w, (b+1)*w)`
  seconds since the reference date). A completed bucket's extremes can never
  change, so its column can be drawn once. `LiveSeriesDecimator` anchors to
  the window's moving left edge, which is right for a full repaint and wrong
  for this. Unit-tested, including slices with different start indices (a
  trimmed window column beside a derived one).
- **`TrendSurfaceView`** is now four layers. Its own content layer holds the
  static parts (value axis, rules, border, the "ago" axis). A plot-sized clip
  layer holds the **strip layer**, a quarter-window wider than the plot, one
  point per bucket; on a tick the view repaints only the bucket still filling
  and its three neighbours (whose joins depend on it), then moves the strip
  by the tick's share of a column, snapped to the device pixel grid. The
  **axis layer** redraws the wall-clock labels only when one crosses a
  pixel, and the wall-clock gridlines live in the strip, so they scroll with
  the data. The **overlay layer** holds the scrub read-out. A full strip
  repaint happens only when something that changes every column changes: the
  range, the value axis (snapped to round ceilings, so rare), the plot size, a
  series colour, the appearance, or the strip running out of room on the
  right, when it is re-homed (once per quarter window; on the 5 minute range
  that is every 74 s and the harness confirmed the chart stays continuous
  across it).
- **Feeds carry raw columns** (`TrendSurfaceSeries.column`, zero-copy slices
  of the `SystemHistoryWindow`) instead of decimated point arrays, so the
  store no longer decimates anything per tick, and the surface buckets only
  the tail it repaints (a binary search plus a few dozen samples).
- **The card sparklines are bare strips**: `MetricCardFeed` republishes its
  column into a `TrendFeed` with `TrendModel.bare` set (no axes, no
  padding), and `LiveSparkline` hosts a `TrendSurfaceView`. Their detail
  sheet decimates on demand instead of per tick.
- **Every surface paints into a `CALayer` of its own** (`LiveSurfaceView`)
  rather than through `draw(_:)`. The layer-display probe added to the
  harness (`MPM_LAYERDEBUG=1`, which logs every layer Core Animation
  displays during a tick) showed why: AppKit records a view's `draw(_:)` into
  a display list and replays it into a float-format "ContentLayer" sized to
  the drawing on every repaint, and for the six sparklines that replay
  (`aa_render` over a 416-vertex min/max zigzag) was 5.6 ms per tick, several
  times the drawing itself. A delegate-drawn layer with an 8-bit store is
  painted directly, and `setNeedsDisplay(_:)` on it repaints only the given
  rectangle, which is what makes the strip possible at all.
- The wall-clock label cache stops the surface formatting six dates per chart
  per tick (`DateFormatter` was 2 ms per tick across the page).

- **No explicit `CATransaction` per surface.** The first live run of the
  strips read no better than the fourth pass (13% main thread with the
  display asleep), and the profile showed `layoutSubtreeIfNeeded` and
  `NSHostingView.layout` eleven times per tick. The surfaces had wrapped
  their layer updates in `CATransaction.begin()`/`commit()` to suppress
  implicit animations; on the tick's main-queue block that is the outermost
  transaction, so every `commit()` ran AppKit's whole display cycle, window
  layout included, once per chart and once per sparkline. The painter
  delegate's `action(for:forKey:)` already returns `NSNull`, so the explicit
  transactions were removed and the layer changes ride the implicit
  transaction that commits once at the end of the run-loop pass. The harness
  fell from 7.9 to 5.2 ms per tick on the same change.

### What the harness had been measuring

The `dashboardPage` scenario mounts the real Dashboard, which loads its
window through `SamplerModel.loadSystemHistory`; with no store that returned
nothing, so every earlier `dashboardPage` figure was for an almost empty
window (only the ticks of the run) and never exercised the raster cost the
live app paid. `SamplerModel.benchmarkSystemHistory` now seeds the page with
`--points` synthetic samples, `--snapshot` writes a PNG of the rendered
window (the AppKit surfaces included) to check the drawing by eye, and
`--range` starts the page on a short window to exercise re-homing.

### Numbers

Host harness, real `DashboardView`, 14,400 samples in the window (seeded),
table publishing at 1 Hz, quiet machine:

| Build | ms per tick (mean / median) | CPU at 4 Hz |
| --- | --- | --- |
| Fourth pass, full repaint each tick | 19.2 to 21.0 / 18.7 to 21.1 | ~8% |
| Strips, sparklines still `draw(_:)` | 20.9 / 20.8 | ~8.4% |
| Strips everywhere, painter layers | **7.9 to 8.8 / 6.5 to 7.5** | **~3.2%** |

Of the 8 ms that remain, about 3.5 ms is the harness's own synthetic 1 Hz
table publish (trails, smoothing, the 600-row rebuild), about 2.3 ms is the
five charts and six sparklines together (store publish, bucketing, the
column repaints and Core Animation's commit), and the rest is timers and
bookkeeping. The per-tick cost no longer depends on the window: an empty
window and a full hour cost the same.

### Live, and what actually moves at 4 Hz

Relaunched with the window open (the display woke part-way through the
30 s window): 4.00 Hz, process 9.9 to 11.7%, main thread 6.5%, against 17 to
19% and 9 to 13.5% for the fourth pass in the asleep state. The window was on
the Processes tab, which is worth spelling out because "nothing looks like
4 Hz" is true there by design: the table is capped at 1 s, and so far its
header cards, sparklines and core grid ride the same 1 s publish through the
older SwiftUI path. The Dashboard is the 4 Hz page, and even there the eye
has little to see on the default 1 hour range: one tick moves the trace by
0.07 px (one device pixel every 1.8 s), the live column is 2 px wide, and the
read-outs show 5 s averages rounded to whole percents. On the 5 minute range
the trace advances about half a pixel per tick, which does read as motion.
That is the cost of a fixed window combined with honest smoothing, not a
cadence problem; making 4 Hz visible is a presentation choice (a live-edge
marker, instantaneous rather than averaged read-outs, the Processes header on
the live feeds).

The same profile showed the outline view rebuilding its visible cells every
second: in flat mode a change in the process count (most seconds) went
through `reloadData`, which discards every row view and asks the data source
for new ones (`ProcessCellView.init`, `ValueCellView.init`, icon placeholders,
about 17 ms per update). The slot list now grows or shrinks at its end with
`insertItems`/`removeItems` and the visible cells are re-configured in place.

## Sixth pass: the table at the dial rate, the full calc every 5 s

Neil's rule, clarified: the process table's *values* should move at the dial
rate; it was the *re-ordering* that need not be faster than once a second.
Running the full scan four times a second would have cost about 7% (2,200
syscalls plus the helper round trip per scan) and the cell refresh another
9%, so the table is split in two:

- **A dial-rate read of the rows on screen.** The outline view reports the
  pids of its visible rows as they scroll (`onVisibleRowsChange`, from the
  clip view's bounds notifications). Between full publishes the sampler runs
  `Sampler.refreshProcesses(pids:)` on the scan queue: task info and rusage
  for those pids only, the privileged helper in one round trip for the ones
  the user cannot read, no descriptor listing, no path or code-sign work, and
  no change to the scan's own delta state. About a millisecond for thirty
  rows. `SamplerModel.applyFastRefresh` turns the reads into patched samples
  (CPU as the trailing 5 s mean of dial-rate deltas, so the figure does not
  jump when the scan re-sorts; footprint, threads and CPU time straight from
  the read) and sends them on `processValuesTick`, a plain subject like
  `liveTick`. The table coordinator subscribes directly, patches its items and
  re-configures only the value cells on screen. No SwiftUI view is involved.
- **The full calc every 5 s** (`LiveRefreshCadence.fullProcessInterval`): the
  scan for the UI, the re-sort, `latest`, alerts. History logging keeps its
  own cadence (the scan still runs every second on this Mac because high-res
  logging is set to 1 s; it just no longer drives the table). Every 1 s scan
  also patches *all* rows' values in place, so a row scrolled into view is
  as fresh as the scan.
- **The Processes header** moved onto live feeds (`ProcessHeaderStore`: the
  usage card's value and sparkline strip, the core grid, the load figure) so
  it follows the dial rather than the 5 s publish, and the inspector pulls
  new history rows on a 1 s throttle of `liveTick` instead of the table
  publish.
- **The menu bar follows the dial.** It had been throttled to ~1 Hz while
  every tick re-rendered unconditionally; all six status items compare the
  figures they would draw with the ones they last drew, so at 250 ms a status
  item repaints when a digit moves. See the numbers for what that costs.
- **A live-edge dot** on every chart rides the newest raw sample. It is a
  plain layer moved by Core Animation, never repainted, and it is what makes
  the dial rate visible on a long range where a tick moves the trace by a
  fraction of a pixel.
- Also found on the way: in flat mode a change in the process count (most
  seconds) went through `reloadData`, rebuilding every visible cell (about
  17 ms); the slot list now grows or shrinks at its end.

### Numbers

Live, display on, 250 ms dial, 1 s logging:

| State | Process | Main thread |
| --- | --- | --- |
| Window closed, menu bar at ~1 Hz (fourth and fifth passes) | 5.6 to 7.6% | 2.0 to 2.4% |
| Window closed, menu bar at the dial rate | 8.5% | 4.8% |
| Processes tab open, rows at the dial rate, menu bar at ~1 Hz | 8.3% (`top`) | about 5% |
| Processes tab open, rows at the dial rate, menu bar at the dial rate | 11.3% | 6.5% |

The dial-rate row refresh itself is a few samples per second; the cost that
remains on the main thread with the window open is the status items: with
several figures in the strip (rates change every tick) the combined item
re-renders on most ticks, and each render is an `NSImage`, the button's
redraw and AppKit's replicant snapshot, about 4% of the main thread at 4 Hz.
That is a standing cost (the menu bar is always up), so it is the one to
decide on: keep it at the dial, cap it at 2 Hz, or give the status item a
painter layer of its own so a change costs a small repaint instead of an
image and a snapshot.

Harness numbers are no longer comparable across these runs: the live app
now runs a dial-rate table alongside the harness on the same machine, and the
seeded Dashboard page read 10 ms per tick against 5.2 ms on a quiet machine
with the same renderer.

## Idle floor

With everything closed and 1 s high-resolution logging on, the app sits at 5
to 6% on this Mac, and the profile is now the sampling itself: the 1 Hz
per-process scan (`proc_pidinfo` task info, `proc_pid_rusage`, and the
file-descriptor list per process, 2,200 syscalls a second for 743 processes,
plus the helper XPC round trip for the system-owned ones), the 1 Hz database
insert, and the 4 Hz system tick at about 1 ms of reader work. Skipping the
rusage and descriptor reads for processes whose CPU time did not advance would
save roughly a quarter of the scan but trades certainty for it, so it was not
done; the lever that matters is the logging frequency, which Settings now
explains.

## Notes on measuring

Host-harness numbers vary by a few milliseconds run to run, and anything else
compiling or benchmarking on the machine skews them; for before/after
comparisons use `--mode image` (stable) or take the median of several quiet
runs.
