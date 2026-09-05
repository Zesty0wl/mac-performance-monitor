# Chart rules

How this app draws data over time. One set of rules for every chart, so the
next fix is a policy change rather than another local patch.

Status: agreed for 2.0.0. The audit at the end says which surfaces already
follow the rules and which do not.

## The problem these rules exist to solve

A performance monitor samples faster than a screen can show. At a one second
cadence an hour is 3,600 samples, and the Dashboard's Processor chart is around
1,500 pixels wide. Something has to decide what happens to the other 2,100
samples, and today different charts decide differently.

Measured on this app before the rules, points actually drawn:

| Range | Samples in range | Points drawn | Result |
| --- | --- | --- | --- |
| 5 min | 300 | 300 | fine |
| 30 min | 1,800 | 1,800 | crowded |
| 1 hr | 3,600 | 3,600 | unreadable |
| 6 hr | 21,600 | 360 | fine |
| 24 hr | 86,400 | 360 | fine |

The live path decimates to 720 buckets and emits the minimum *and* maximum of
each, which is honest: no spike is ever hidden. For a volatile metric it is also
unreadable, because almost every bucket contains a spike, so the chart becomes a
solid band whose height is worst case rather than typical. The Processor chart
reading 7 percent while the plot is a wall of green is exactly this.

For contrast, [beszel](https://github.com/henrygd/beszel), which Neil rates,
never draws more than about ninety points at any range. It rolls records up in
the backend, 1m into 10m into 20m into 120m into 480m, storing an average for
metrics like CPU and memory and a peak for throughput, and the front end picks
the tier that matches the range:

| Range | Record tier | Points on screen |
| --- | --- | --- |
| 1 hr | 1m | about 60 |
| 12 hr | 10m | about 72 |
| 24 hr | 20m | about 72 |
| 1 week | 120m | about 84 |
| 30 days | 480m | about 90 |

The lesson is not the exact numbers. It is that the point count is roughly
constant whatever the range, and that the reduction is chosen per metric rather
than per chart.

## The rules

**1. The line carries about 120 points across the plot, whatever the range, and
the reduction happens as late as possible.**

Pixels are the wrong budget. A plot 1,500 columns wide showing an hour puts two
or three samples in each column, and the mean of three noisy samples is still
noisy: bucketing to pixel resolution barely smooths anything, which is why the
first attempt at this looked almost as bad as no reduction at all. Sizing the
reduction to a target point count is what actually works, and it is what beszel
does: roughly thirty seconds behind each point at an hour, three minutes at six
hours, two seconds at five minutes where the detail is still the point.

Do the reduction at draw time, not on the way into the window or out of the
database, because rule 3 needs the real minimum and maximum of each bucket and
an average taken earlier has thrown them away. Keeping full resolution in memory
is the cheap part: an hour at one second is 3,600 doubles per metric.

The line through those points is a monotone cubic curve, the same construction
beszel draws with (d3's `curveMonotoneX`). A polyline through 120 points reads
as jagged, and an ordinary spline smooths it by overshooting, which on a
monitoring chart invents a peak between two real ones. The monotone curve stays
inside the vertical range of each pair of points it joins, so every bump is one
that was measured. `MonotoneCubic` in Core holds the tangent rule and its tests;
`MonotoneCurve` turns it into a path for both the layer-backed strips and the
Canvas charts.

**2. How a bucket is reduced belongs to the metric, and is decided once.**

| Kind of metric | Reduction | Why |
| --- | --- | --- |
| Utilisation and rates: CPU, memory, network, disk, GPU | mean, with a min and max band | the question is "how loaded", and the band keeps the spikes visible |
| Temperature, fan speed | maximum | a thermal spike is the event; an average erases it |
| Levels and states: pressure band, thermal pressure | last in bucket | a state is not an average |
| Counters shown as totals | last in bucket | a mean of a monotonic series is meaningless |

**3. A volatile series is a line plus a band, never a forest.** Draw the mean of
each bucket as the line, and the minimum to maximum range as a translucent band
of the same hue behind it. That keeps the worst case visible without letting it
own the plot. The live decimator already computes both ends of the range, so
this is a drawing change rather than a data change.

**4. No range is special.** Every range goes through the same reduction, and it
is the plot width that decides how much reduction happens. Five minutes at one
second is 300 samples and most of them survive; an hour is 3,600 and most do
not. Nothing is special-cased by name. Ranges long enough to be served by the
stored minute and hour tiers arrive as means, but each row carries its bucket's
peak (`SystemHistoryPoint.peaks`, from the `_max` columns the tiers already
kept), and the band rises to it: at six hours and beyond the line is the mean
and the shading above it reaches what the spikes hit. The tiers store no
minimum, so the band's floor there is the mean itself. Those ranges also run
right up to the present: a tier only holds buckets that were complete when
retention last ran, so the query tops up from the finer tiers past each
watermark down to the raw rows, and the live samples join on without a hole.

**5. The y axis fits the data, with a floor on the span.** A fixed wide axis
wastes the plot: a die sensor pinned to 0 to 110 draws a flat ribbon through the
middle. A tight auto-fit does the opposite and turns a degree of idle noise into
a mountain range. `ChartDomain.fitted` does both, and every chart states its
minimum span. Percentages that genuinely use their range, like total CPU, keep
0 to 100 so that half the chart always means the same thing.

**6. The domain is stable while the chart is live.** Recompute it on a range
change, or when the data leaves it, not on every tick. A y axis that rescales
each second makes a steady signal look alive.

**7. Gaps are gaps.** A missing sample breaks the line. Never interpolate across
a hole, because on a monitoring chart a straight line means "we measured this"
and a gap means "we were not looking". The threshold comes from the spacing the
data legitimately has (`ChartGap.threshold`: three times the coarsest expected
spacing, floored at fifteen seconds), never from the span. For a live range that
is the logging interval; for a range served by a stored tier it is the tier's
row spacing, a minute or an hour, or every stored row is its own island and the
chart draws dots. A run resumes from its first real sample: the sampler's first
tick after launch has nothing to difference against and reports zeros, so it is
neither recorded nor charted, otherwise every run after a gap begins with a
vertical climb from the axis.

**8. Every chart says what it is showing against.** Where there is room, a
labelled y axis, a time axis, and a caption. On a card strip there is not room,
so it gets the two marks that matter: a baseline to sit on, and the window's
peak in the corner. A sparkline with no anchor at all is decoration, not data.

**9. Fill is for calm series only.** An area fill under a volatile line becomes
a solid block. Swap and free space may be filled; CPU, temperature, network and
disk may not.

**10. Say what the reduction is.** When a chart is showing means of ten second
buckets rather than samples, the caption says so. A smoothed line that claims to
be raw data is a lie the user cannot see.

## What enforces each rule

| Rule | Where it lives |
| --- | --- |
| 1, 4 | `TrendRenderer.smoothingSeconds` sets the window from the span; `LiveStripBuckets` supplies the per-column extremes behind it, raised to the stored peaks where a row carries them; `MonotoneCurve` draws the line. The history window keeps every sample on purpose |
| 2 | `TrendSurfaceSeries.reduction`, declared per series where the model is built |
| 3 | `TrendRenderer.drawSeries`, the one routine every series is drawn with: the layer-backed strips call it for their live columns, the Canvas `TrendChart` (every tab chart, the detail charts, the battery chart) calls it for its points |
| 5, 6 | `ChartDomain.fitted`, called by each chart with its own minimum span |
| 7 | `TrendModel.gapThreshold`, sized by `ChartGap.threshold` from the loaded tier's spacing; a `TrendChart` given no threshold reads its series' own spacing with `ChartGap.expectedSpacing`; `Sampler.hasBaseline` keeps the zero tick out |
| 8 | `TrendChartGeometry` for full charts, `ScaledSparkline` for strips |
| 9, 10 | review, and the captions each panel already carries |

## Audit

Verified by reading the code on 5 September 2026. "Follows" means the rule is
met today; everything else is work.

| Surface | Rules met | Work needed |
| --- | --- | --- |
| Dashboard: pressure, processor, network, disk, swap | 1, 2, 3, 4, 7, 9 | none |
| Dashboard: thermals | 1, 2, 3, 4, 5, 7, 9 | none |
| Dashboard: metric cards | 1, 2, 3, 4, 5, 7, 9 | 8: no peak label, unlike the Processes header |
| Processes header: CPU, load (1, 5 and 15 minute), die | 1, 2, 3, 4, 5, 8, 9 | none |
| Metric card detail sheets (Dashboard, Processes, Energy) | 1, 2, 3, 4, 5, 7, 8, 9 | none |
| Energy tab cards | 1, 2, 3, 4, 7, 8, 9 | 5 |
| GPU tab: utilisation, power, temperature | 1, 2, 3, 4, 7, 9 | 5 for power, which still runs from zero to a rounded peak; utilisation keeps 0 to 100 on purpose |
| Energy tab: thermals, fan, charge | 1, 2, 3, 4, 5, 7, 9 | none |
| Disk tab: throughput, operations, latency, free space | 1, 2, 3, 4, 7, 9 | 5 for latency; free space keeps 0 to capacity on purpose |
| Network tab and adapter detail | 1, 2, 3, 4, 7, 9 | 5 |
| Process and group detail charts | 1, 2, 3, 4, 7, 9 | 5 |
| Menu bar panels | 8, 9 | 1, 3, 5: the curve is shared, the reduction and band are not |
| Process performance chart (Processes tab, trace viewer) | 7 | to audit: a separate Canvas with its own scrubber |
| Insights and Analytics | to audit | to audit |

## Rollout

One pull request per rule group, applied across every surface at once rather
than per tab, because the point of writing this down is to stop fixing charts
one at a time.

1. **Resolution and reduction** (rules 1 to 4, 9): done for every chart but
   the menu bar panels and the process performance chart. `LiveStripBuckets`
   carries each bucket's mean alongside its extremes, and
   `TrendRenderer.drawSeries` draws the mean as a monotone curve inside a
   translucent band of the spread, for the live strips and the Canvas charts
   alike. Series declare their reduction, so temperature and fan speed follow
   the maximum while everything else follows the mean, the area fills are gone
   from the volatile series, and the tabs load every stored row instead of
   thinning to 360 points on the way in.
2. **Axes** (rules 5 and 6): `ChartDomain.fitted` everywhere, with a stated
   minimum span per metric, and hysteresis on live recomputation. Done for the
   two temperature surfaces; the GPU, Energy, Disk and Network tabs still carry
   fixed domains.
3. **Annotation** (rules 8 and 10): peak labels on every card strip, captions
   that name the reduction. Done for the Processes header only.
4. **Stored tiers** (rule 4's exception): the tiers' stored maxima now ride
   along with the means, so ranges of six hours and longer get a band from the
   mean up to the peak. Storing a minimum as well, so the band has a floor
   below the mean, is the remaining piece.

Rules 7 and 9 are met everywhere the audit does not list an exception.
