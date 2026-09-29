# Dashboard chart standard

The Dashboard uses this standard as of 6 September 2026. Explorer adopted the
same renderer on 9 September 2026, with the process and peak-only data limits
described in [explorer-design.md](explorer-design.md). It remains the target for
other tabs. It supersedes the earlier line-and-band policy in
[chart-rules.md](chart-rules.md) for Dashboard and Explorer charts.

The reader is an IT administrator investigating a performance problem. A chart
must distinguish sustained demand, short bursts, and missing evidence. It must
not make a peak look like continuous usage.

## Two visual layers

The chart has a translucent, unsmoothed range behind a clear average line.
There are no range bars or separate minimum and maximum outline traces. Keep
the measurements' short bursts visible instead of reducing the background to
the same coarse intervals as the average.

The background reads the full source rows and their known extrema. Only rows
that land within one display column are combined, with their true extrema
retained. These small time bins have a fixed origin while the chart is live.
They are never wider than the average interval. No moving average or curve
smoothing applies to the background.

Fill between the available bounds at 14% opacity. Draw the recorded values
at 0.9 points and 28% opacity, so raw samples remain visible when the range
has no thickness. Do not fill down to zero unless zero is a measured bound.
Draw all series' backgrounds first, then all averages at full opacity and
their usual line width. This keeps every average above overlapping ranges.

The foreground uses fixed time intervals. Each has a sample-weighted average,
an observed minimum, and an observed maximum for hover and summary statistics.
The line joins averages with straight segments. Its interval does not change
when the chart gets wider. The legend identifies that interval beside
"Average" and shows a translucent swatch for "Recorded range".

A mean near the minimum can be correct. For example, nine readings of 10% and
one of 90% have an average of 18% and a range of 10% to 90%. The high reading
does not mean the machine spent most of that interval at 90%. Neither min/max
nor the average can reveal the exact time spent at a level.

The average uses these default intervals:

| Selected window | Interval | Full intervals |
| --- | --- | --- |
| 5 minutes | 5 seconds | 60 |
| 30 minutes | 15 seconds | 120 |
| 1 hour | 30 seconds | 120 |
| 6 hours | 5 minutes | 72 |
| 24 hours | 15 minutes | 96 |
| 7 days | 2 hours | 84 |

`ChartStatistics.interval` selects a rounded duration with at most 120 full
intervals. It rounds up again to a multiple of the coarsest loaded source
duration. Custom recording settings can therefore change the table above.
The caption shows the actual interval.

Average intervals use a fixed time origin. A resize leaves those statistics
unchanged but can reveal finer background detail. A new sample changes the
open interval; complete interior intervals do not change shape while the chart
scrolls. Partial edge intervals and gaps can add fragments.

"Unsmoothed" means the data we still have, not lost raw samples. A retained
hour row stays an hour row. Its mean and known extrema survive, but their
exact timing within that hour cannot be recovered. Enlarging the chart cannot
invent finer source data.

## Define the average precisely

Raw rows have a weight of one. Stored rows carry their original sample count.
To combine rows, sum each mean multiplied by its count, then divide by the sum
of counts. Apply the same rule to selected-range summaries. Do not take an
unweighted average of stored averages.

These are averages of recorded samples, not time-weighted means. Periods with
faster recording contribute more samples. Missing periods contribute no
samples and are not zeros. Source durations describe coverage; they are not
weights. Repeated cached sensor values count as recorded rows, not as separate
reads of the physical sensor.

Minima and maxima must survive each storage stage independently. New minute and
hour rows retain bounds for pressure, CPU, network, disk, memory categories,
swap, and die temperatures. Thermal rows also retain counts of valid readings
for each sensor series. A GPU average must not use the CPU or whole-system count.

Temperature has two different reductions. Each physical read selects the
hottest valid sensor in the CPU or GPU group. The chart then averages those
recorded hottest readings over time, with their observed range beside the line.
It does not average across different sensors or replace GPU data with CPU data.

## Show gaps and limits

- Keep explicit missing readings in the input. They split the line, even
  within one display interval. Do not filter them out before reduction.
- A time gap also splits the line. Compare timestamps against the preceding
  source row's coverage, not the displayed point spacing.
- A hover must not reach across a missing reading or into an empty interval.
  It reports each series separately; CPU can be present while GPU is absent.
- A single valid fragment is a dot, not an invented line.
- A plotted point stays within its measured coverage. An open interval must
  not produce a point in the future.
- A stored row is indivisible. Select it by its start timestamp and keep its
  full count and bounds. Do not split an hour row into pretend minute samples.

Storage limits the detail we can show. An hour row with valid sensor readings
can hide shorter gaps inside that hour. Counts show how
many readings contributed; they cannot restore the missing timestamps.

### Older records

Migration `v17-chart-statistics` adds nullable metadata. It does not backfill
unknown bounds from averages or interpolate absent temperatures.

When a minimum is unknown, shade from that source row's recorded average to its
known maximum. Apply the reverse rule when only the minimum is known. If both
bounds are unknown, only the recorded value remains. The average is a visual
edge for this partial range, never an inferred minimum or maximum. The caption
states this limit. A missing reading still breaks both the shading and lines.
A lone known bound is a small, faint dot, not a bar.

Hover and detail views continue to say "Not recorded" for an unknown bound.
An unknown contributing bound makes that bound unknown for a combined summary
too. Rendering must never write its fallback values into the statistics.

Older thermal aggregates retain a mean and a peak but lack valid-reading
counts. They use an explicit approximate weight of one. The interface marks
these averages as approximate and does not display a fabricated sample count.

To calculate free memory, subtract the measured categories from total RAM,
then clamp at zero. Raw rows support true bounds for this derived value. Separate
category averages cannot recover its historical extrema. Stored-range free
memory therefore has a derived value and a limitation note, not made-up bounds.

## Keep axes stable

- Total CPU stays at 0% to 100%. Pressure stays at index 0 to 100; it is not
  the percentage of RAM in use. Pressure thresholds stay at 34 and 67.
- Network and disk rates use bytes per second, a zero baseline, and a scale
  that includes the observed peaks. Reset the scale on a range load. During
  live updates, expand only when a reading exceeds it.
- Memory and swap use bytes with a zero baseline. Their scales reset for a
  new range and expand for a new peak. Card strips identify the axis ceiling.
- Temperature shares one scale across CPU and GPU, with a minimum 30 C span
  and 5 C padding. Retain the scale while readings remain inside it.
- Reduce time-axis label density for narrow charts. Never change statistical
  intervals to fit more labels or range detail.
- Keep series colors stable. Put the current macOS state in a separate value;
  do not recolor an entire historical line when the current state changes.

## Hover and inspect

Every Dashboard time chart, including the six headline strips, has a hover
readout. It shows the interval's dates and times, every series' average and
known bounds, sample count, source resolution, and any missing reading.
It also marks partial intervals at the window edges. A native popover keeps the text
outside narrow chart bounds.

Every card and panel has a detail view. The six headline cards open on click.
Other panels have a title action and an expand icon. Details capture data at
the open action and then remain still. The sampler continues to run. Charts
retain the exact same intervals and data in a larger, axed view, with range
statistics and explanations of meaning, measurement, and investigation.

Bind a SwiftUI sheet to one optional, identifiable snapshot with `sheet(item:)`.
Do not use a separate presentation flag and optional data inside the sheet
closure. That pattern opened an empty 100 x 80 sheet on the first card click.
The snapshot must carry both the metric data and its time window.

The current value is not the selected-range mean. Processor, network, and disk
readouts state that they are live and smoothed. Snapshot facts are distinct
from selected-range statistics. Closing and reopening captures fresh data.

Core bars and memory composition are current-state charts, not historical
averages. Their hover readouts identify the item and its value. Their details
contain an enlarged chart and a table or breakdown. Ranking details
show up to 20 recorded processes, their sample counts, identifiers, comparison
bars, and the ranking's measurement limits.

## Code and rollout

`ChartStatistics` in Core sets fixed intervals and computes weighted statistics,
gaps, and hover selection.

`SystemHistoryPoint` and `SystemHistoryWindow` carry counts, durations, and
nullable extrema. The database migration and retention queries preserve them.

`LiveColumn` passes those columns to the chart without resampling.

`TrendRenderer.statisticsBuckets` prepares separate display-resolution range
data and fixed-interval averages from those same source columns.

`TrendSurfaceView` and `TrendRenderer.drawStatistics` draw the native chart and
its translucent range. They support partial repainting during live updates.

`TrendStatistics.swift` supplies hover views, captions, summaries, and frozen
enlarged charts.

`TemperatureChart.statisticsModel` builds optional columns for each thermal
series without removing missing readings.

`DashboardTimelineStore` and `DashboardView` own feeds and snapshot actions.

`DashboardDetailSheet` supplies panel explanations and current-state details.

`TrendModel.statisticsInterval` opts a surface into this policy. A nil interval
keeps the existing renderer, which other tabs still use. The Dashboard, all
its detail charts, and Explorer opt in. Explorer uses a shared cursor and side
inspector instead of a hover popover. Shared history metadata and the sensor fix apply
wherever the same data readers are used.

Energy now supports hover on its charge, die-temperature, and fan timelines,
and on its charge, power, and battery-temperature card charts. These still use
the existing renderer, not the Dashboard's statistical model. Their readouts
show the recorded sample's date, time, and value with units. The shared thermal
chart names both CPU and GPU at the selected timestamp. A missing value stays
unavailable rather than borrowing a reading from another time. The GPU tab's
thermal chart uses the same hover behavior.

For each later tab:

1. Identify each metric's units, source, counts, bounds, and missing-value form.
2. Pass full source rows and their metadata through `LiveColumn`.
3. Set one fixed interval for the selected range and name every series.
4. Use the shared native chart's two layers, hover, caption, and snapshot views.
5. Separate current values from range statistics and explain data limits.
6. Add tests and inspect narrow and wide renderings before marking it migrated.

Keep sampler ticks off SwiftUI layout. Feed native surfaces directly. Only
repaint changing edge intervals during live scrolling; resize and range changes
may repaint the full chart. Build detail summaries when a snapshot opens.

## Verification

Core tests cover unequal weights, unknown metadata, raw and stored rows,
partial intervals, gaps, and the retention migration. Native tests cover
sensor-specific counts, frozen snapshots, card activation, axis peaks, and
painted pixels. The GPU-gap test checks that the middle of a missing span has
no series pixels. Range tests check low-opacity shading under an opaque average,
spikes at their recorded times, and unknown bounds that remain unknown in the
statistics. They also check that shading never extends to a made-up zero floor.

`MetricCardPresentationTests` mounts the actual card in a native window and
clicks its chart. It checks the attached sheet's size and content, then closes
and reopens it. Rendering a detail view in isolation cannot catch an empty
sheet caused by the click's presentation state.

`EnergyChartHoverTests` checks hover enablement and units on each Energy
timeline. It tests both thermal readings at one timestamp, including a missing
GPU value. It also mounts the real card sparklines and sends mouse events to
check that their readouts appear, paint, and disappear on exit.

Run the focused checks:

```sh
swift test --filter 'ChartStatisticsTests|SystemHistoryStatisticsTests|SystemHistoryWindowTests|SMCReaderTests|ThermalTests|DashboardChartTests|MetricCardPresentationTests'
swift test --filter EnergyChartHoverTests
MACPERF_CHART_ARTIFACTS=/tmp/macperf-dashboard-charts swift test --filter DashboardChartTests
```

The last command writes native PNG fixtures for all six ranges, narrow
charts, hover content, and an enlarged detail sheet. The long-range fixtures
include bursty workloads, light and dark appearances, and older records with
no minimum. Inspect those images as well as the test results. Before merging,
run the full test suite, Swift
format lint, and both localization checks from CI.