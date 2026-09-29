# Investigate This Mac

Explorer replaces the Analytics start screen. It shows live and past data from
this Mac. Use its charts to find a change. Then compare processes and sensors
around it.

Use this guide to investigate a slowdown, a spike, or a process that has exited.
Explorer shows what the app recorded. It does not fill in missing data or prove
that one chart caused a change in another.

## Investigate a moment

An alert can now open Explorer at its evidence window, with related processes
and charts selected. Captured alert values appear in the inspector even when
full history was off. See [Adaptive alerts](adaptive-alerts.md).

1. Open **Explorer**. The overview shows machine activity before you select a
   process. The live window follows new records.
2. Choose a span, or use **Go to time** to enter a date, time, and second.
   Earlier and Later move the window. Zoom keeps the cursor as its anchor.
   Hold Command and scroll up over a chart to zoom in, or down to zoom out.
   This keeps the time under the pointer in place across all charts. Scrolling
   without Command moves the page.
3. Hover over a chart to move the shared cursor. Click to pin the time and
   stop the window moving. Sampling and recording continue in the background.
4. In **Values**, read the observation time, value, known bounds, and source
   interval. Expand **Recorded machine row** for every field in that stored row.
5. In the inspector's **Processes** tab, see the latest eligible observations
   at or before the pinned time, ranked by CPU. Add a process to compare it.
6. Use **Metrics** to add related charts. Use the sidebar's **Processes** tab
   to search names and PIDs, including processes that have exited.
7. Expand one chart for a closer view, or switch between a grid and a list.
   **Resume live** clears the pin and returns to the present.

Previous and Next move to loaded observation times. At the edge, they request
another window. The sidebar and inspector scroll independently from the charts.
On compact windows, the inspector sits below the charts instead of beside them.

## Choose the evidence

Each chart shares the same visible time window and cursor. The default view
places total CPU beside process CPU, with memory, network, disk, and thermal
context nearby. Compare up to eight process identities with stable colors.
A PID plus its start time identifies a process, so PID reuse does not join
unrelated lifetimes.

The metric list has 23 machine charts and 19 process charts:

- **Processor:** total CPU and load averages over 1, 5, and 15 minutes.

- **Memory:** pressure index, app/wired/compressed/cached memory, and swap.

- **Network:** machine download/upload and traffic by process.

- **Disk:** physical throughput, IOPS, service time, busiest-device use, boot
   volume space, and I/O by process.

- **Graphics:** GPU use, GPU and Neural Engine power, and GPU use by process.

- **Sensors:** CPU/GPU die, CPU clusters, enclosure, storage/radio groups,
   fastest fan, and macOS thermal state.

- **Battery:** charge, power, health, and temperature.

- **Processes:** CPU, memory, threads, descriptor counts, disk/network/GPU,
   energy, and total CPU times.

The process detail list also shows its path, start time, and available counters.
Disk charts show rates; process details show the stored cumulative byte counters.
The machine row includes raw fields that have no dedicated chart, such as paging
counters and recording flags. Missing fields remain missing.

## Read history at its recorded resolution

Explorer uses the existing database and retention settings. It adds no new
sampling loop, schema migration, or historical hardware capture.

- **Raw machine rows** keep individual readings. The row inspector shows all
   their columns.

- **Machine aggregates** keep interval values and the bounds/counts that
   retention stored. A source interval is the span of time a stored row covers.

- **Raw process rows** keep changes and periodic heartbeats, not every tick.

- **Process aggregates** keep CPU, footprint, descriptor peaks, disk counters,
   network, GPU, and energy impact.

- **Raw-only process fields** include resident/virtual memory, lifetime peak,
   threads, descriptor types, total energy, and CPU times.

- **Hardware inventory** is a current on-demand capture, with its capture time.

Old data may have only minute or hour intervals. Broad windows use coarser
history to bound the read size, then include available finer rows at the live
edge without counting the same interval twice. Zoom cannot recover discarded
raw data. A window narrower than its source interval expands to show that
interval. Stored intervals retain their original width after settings change.

The inspector never substitutes a future raw sample. It shows the last fresh
observation before the cursor, or a stored interval that covers the cursor.
Its timestamp can differ from the selected time. An interval value describes
the whole source interval, not an exact reading at every second within it.
The process list shows at most 200 eligible observations; search can find other
recorded process identities in the visible window.

The **Hardware** inspector is explicitly current, not historical. It searches
the same on-demand inventory as the Hardware tab. Individual devices and sensor
inventories have no stored timeline. The thermal charts use the sensor groups
that the app already records.

## Interpret the charts

Explorer uses the approved [chart standard](dashboard-chart-standard.md): a
translucent, unsmoothed recorded range behind a clear average line. It keeps
gaps, unknown extrema, fixed time intervals, and stable live scales.

Machine means use known source sample counts. Raw process means use the stored
readings. The app skips unchanged process rows between heartbeats. Their means
do not describe continuous activity. Aggregate process summaries are approximate.
Their storage weights describe time, not raw sample counts. Explorer does not
show those weights as a count of samples.

Some retained sensor groups contain only peaks. An average of peaks cannot
recover a time average; the inspector states that limit. Retained free-space
values are interval minima, and descriptor counts are interval maxima.
Thermal states use steps with no average or invented intermediate state.

Missing GPU or thermal values stay unavailable. Older per-process network/GPU
zeros can mean that attribution was off. Those zeros have an uncertain meaning.
Battery charts leave absent battery data blank. Disk counter resets
and long gaps have no derived rate.

## Export an investigation

**Export visible data** writes CSV for the enabled charts in the current window,
or only the focused chart. Each row has a series name, unit, timestamp, numeric
value, known bounds, and source duration. A stored interval that overlaps the
left edge keeps its original timestamp. Missing values use empty cells. This
export contains plotted source rows, not the complete machine-row schema.

**Export process trace** keeps the existing `.mpmtrace` format and viewer.
Selected exited processes keep their recorded metadata. The default resolution
uses Explorer's loaded tier. The trace format remains process-only and has
fewer fields than Explorer. You can still import traces or open them from Finder.
The tools menu also links to the earlier monitor view.

## Keep interaction responsive

Database reads use the existing reader queue. Time and identity filters bound
each read; comparison loads have a combined 60,000-process-point limit. Search
waits 250 ms while you type and returns at most 300 candidates. A separate serial
queue builds chart columns. New requests discard old results, so a late query
cannot replace a newer investigation.

Live follow appends newly stored rows and trims expired ones. It does not
periodically replace the full history. When recording is off, Explorer appends
live snapshots and labels them unrecorded. Pinning stops those updates in the
workspace, not the sampler.

The shared cursor updates native overlays directly. It does not reload history
or rebuild chart columns on mouse movement. Whole-window statistics sit outside
the cursor-only view. Hardware capture runs on demand, not on each live tick.

## Verify changes

Focused tests cover bounded reads, source intervals, missing fields, PID reuse,
pinning, cursor stepping, append-only history, CSV, and exited-process traces:

```sh
swift test --filter 'DataExplorerTests|ExplorerHistoryTests|ExplorerCursorTests'
```

Generate native wide/compact previews from synthetic fixture data:

```sh
MACPERF_EXPLORER_ARTIFACTS="$PWD/build/explorer-previews" \
  swift test --filter DataExplorerTests/testNativeExplorerScreenshots
```

An optional integration check opens an existing database read-only, with no
migrations or writes:

```sh
MACPERF_EXPLORER_DATABASE="$HOME/Library/Application Support/MacPerformanceMonitor/macperfmonitor.sqlite" \
  swift test --filter ExplorerHistoryTests/testExistingHistoryReadOnlyWhenRequested
```