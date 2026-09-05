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

**1. Never draw more points than there are pixels, and reduce as late as
possible.** The budget comes from the plot width, not from the range: one bucket
per column of the plot. Do the reduction at draw time, not on the way into the
window or out of the database, because rule 3 needs the real minimum and maximum
of each bucket and an average taken earlier has already thrown them away. Keeping
full resolution in memory is the cheap part; an hour at one second is 3,600
doubles per metric.

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
stored minute and hour tiers arrive pre-averaged, so their bands are flat: giving
those tiers a stored minimum and maximum is the one piece of this that is not
done.

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
and a gap means "we were not looking".

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
| 1, 4 | `LiveStripBuckets` at draw time, one bucket per plot column. The window keeps every sample on purpose |
| 2 | one table in Core, keyed by `SystemHistoryWindow.Column` |
| 3 | `TrendSurface` band drawing, fed by the decimator's existing min and max |
| 5, 6 | `ChartDomain.fitted`, called by each chart with its own minimum span |
| 7 | `TrendModel.gapThreshold` |
| 8 | `TrendChartGeometry` for full charts, `ScaledSparkline` for strips |
| 9, 10 | review, and the captions each panel already carries |

## Audit

Verified by reading the code on 5 September 2026. "Follows" means the rule is
met today; everything else is work.

| Surface | Rules met | Work needed |
| --- | --- | --- |
| Dashboard: pressure, processor, network, disk, swap | 1, 2, 3, 4, 7, 9 | none |
| Dashboard: thermals | 2, 5, 7 | 3: drawn by `TemperatureChart`, which has no band yet |
| Dashboard: metric cards | 1, 2, 3, 4, 5, 7, 9 | 8: no peak label, unlike the Processes header |
| Processes header: CPU, load, die | 1, 2, 3, 4, 5, 8, 9 | none |
| GPU tab | 7 | 1, 3, 5: fixed 0 to 100 and 0 to peak domains |
| Energy and battery | 7, 9 | 1, 3, 5 |
| Disk tab | 7 | 1, 3, 5 |
| Network tab | 7 | 1, 3, 5 |
| Menu bar panels | 8, 9 | 3, 5 |
| Insights and Analytics | to audit | to audit |

## Rollout

One pull request per rule group, applied across every surface at once rather
than per tab, because the point of writing this down is to stop fixing charts
one at a time.

1. **Resolution and reduction** (rules 1 to 4, 9): done for every live surface.
   `LiveStripBuckets` carries each bucket's mean alongside its extremes, and
   `TrendSurface` draws the mean as the line inside a translucent band of the
   spread. Series declare their reduction, so temperature follows the maximum
   while everything else follows the mean, and the area fills are gone from the
   volatile series.
2. **Axes** (rules 5 and 6): `ChartDomain.fitted` everywhere, with a stated
   minimum span per metric, and hysteresis on live recomputation. Done for the
   two temperature surfaces; the GPU, Energy, Disk and Network tabs still carry
   fixed domains.
3. **Annotation** (rules 8 and 10): peak labels on every card strip, captions
   that name the reduction. Done for the Processes header only.
4. **Stored tiers** (rule 4's exception): keep a minimum and maximum alongside
   the mean in the minute and hour tiers, so ranges of six hours and longer get
   a band too.

Rules 7 and 9 are met everywhere the audit does not list an exception.
