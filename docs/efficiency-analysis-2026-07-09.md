# Performance and efficiency audit: 2026-07-09

## Executive summary

This audit reviewed the current sampling, persistence, analysis, charting, menu bar,
trace import/export, helper, and system-reader paths. It used the 2026-07-03 audit
as a baseline and did not repeat work already completed there.

The current production database is now about 1.03 GB, with 6.48 million process
history rows across the three retention tiers. That scale exposed several costs
that were not material in the earlier audit. The largest new risks came from the
uncommitted trace feature. They included unbounded decompression, main-thread
import and export, duplicate full-size point arrays, unlimited rendered series,
and a query per exported process.

This pass implemented focused improvements while preserving recorded data,
sampling cadence, refresh settings, trace contents, and analysis features.

Main outcomes:

- Trace reads and writes now have shared size and point limits.
- Trace file I/O, decoding, preparation, projection, statistics, encoding, and
  writing run off the main thread.
- Imported traces keep all processes, but render at most eight selected overlays.
- Multi-process history reads use bounded set queries instead of one or two SQL
  statements per process.
- Time and size retention use bounded transactions.
- Raw network leaderboards and process-age pruning have suitable indexes.
- Failed write transactions can no longer leave stale in-memory IDs or write gates.
- The fast system tick now uses one interface-list walk and cached machine constants.
- Disabling logging now releases history caches.

All 280 package tests pass. The release product builds successfully.

## Scope and constraints

The audit preserved these rules:

1. Full mode records system and process history at the configured cadence.
2. Menu bar popovers retain their existing refresh behavior.
3. The main window follows the global refresh setting.
4. Trace files retain every exported process and exact integer counters.
5. Existing database files migrate in place.
6. No installed application or production database was modified during testing.

The review covered:

- `MacPerfMonitorCore/Sampling` and `MacPerfMonitorCore/System`.
- `MacPerfMonitorCore/Persistence` and database migrations.
- `SamplerModel`, menu models, lifecycle gates, and caches.
- SwiftUI views and Charts data preparation.
- Trace import, export, codec, viewer, and Finder routing.
- Helper and memory-inspection process execution.
- Existing performance findings and test coverage.

## Measured baseline

The live database was opened read-only on 2026-07-09.

| Fact | Value |
| --- | ---: |
| Main database size | 1,031,700,480 bytes |
| Process dimension rows | 371,400 |
| Raw process rows | 757,949 |
| Minute process rows | 5,059,846 |
| Hour process rows | 666,933 |
| Total process history rows | 6,484,728 |

A disposable copy of this database was used to test the new indexes. Creating the
replacement raw covering index, the process-age index, and fresh statistics took
7.50 seconds wall clock on this machine. This is a one-time migration cost.

The query planner then reported:

- Raw network aggregation: `USING COVERING INDEX idx_process_samples_consumer`.
- Process pruning candidates: `USING COVERING INDEX idx_processes_last_seen`.
- Raw, minute, and hour existence checks: each tier's process-first primary key.

## Implemented improvements

### 1. Bounded trace files

`ProcessTraceCodec` now enforces one policy for encoding and decoding:

- 64 MB maximum compressed container.
- 256 MB maximum decoded JSON payload.
- 1,000,000 total points.
- 4,096 process series.
- Exact supported container and schema versions.
- Zeroed reserved header bytes.
- Unique process identities.
- Finite, ordered timestamps inside the declared window.
- Finite and non-negative CPU and network values with generous safety ceilings.
- Finite derived disk rates.
- Bounded string and path lengths.

Decompression now streams through a 64 KB buffer and stops before output exceeds
the decoded-size limit. URL loading checks file size before reading and reads no
more than the supported container size plus one byte.

Encoding applies the same checks. A successfully encoded trace is therefore
within the reader's supported limits.

### 2. Responsive trace import and viewing

Trace import now uses a dedicated user-initiated queue for file I/O,
decompression, JSON decoding, validation, and first-render preparation.

The loader prepares these values before returning to the main thread:

- actual point-domain bounds
- network-data presence
- peak footprint per process
- the initial active process set
- bounded chart series for every grid metric

The viewer no longer converts the complete document into a second set of
`ProcessHistoryPoint` arrays. It keeps `ProcessTracePoint` as the canonical data.
Visible ranges use binary search and `ArraySlice`, avoiding a copy of the full
series.

Grid projection computes all five metrics in one traversal per process and
reduces each metric directly into fixed time buckets. It no longer creates five
full-size projected arrays before downsampling.

Later interactions use a generation-tokened worker. Zooming, panning, focusing,
changing active processes, and calculating statistics all scan trace points off
the main thread. New requests cancel stale scans every 1,024 points, and only the
latest bounded result is published.

The trace can contain every exported process, but no more than eight are plotted
at once. The lazy process list lets the user choose which eight to compare. This
keeps the chart mark count bounded without discarding data or removing access to
any process.

Trace state now lives above the inactive-tab gate, so switching tabs does not
silently close an imported trace. Replacing a trace creates a new keyed viewer,
so old view state cannot appear over a new document.

### 3. Responsive and bounded trace export

The save location is chosen before expensive export work begins.

History loading now runs on a dedicated export reader queue, separate from the
serial cache queue used by visible chart and tab reads. Database failures are
reported instead of being presented as an empty history window.

The database cursor enforces the one-million-point trace limit while rows are
read. It stops on row 1,000,001, before returning an oversized dictionary or
building trace point arrays. The cursor also checks cancellation.

Document assembly, validation, JSON encoding, compression, and file writing run
on a dedicated worker. Output is written to a sibling temporary file. The final
replacement or move occurs only while the operation still owns its cancellation
lock, so cancellation cannot overwrite the selected destination.

### 4. Batched multi-process history reads

The former multi-process APIs ran one raw query per identity or two aggregate
queries per identity. A broad export could therefore issue hundreds or more than
a thousand statements.

The new path:

1. Resolves identities in chunks of 400, below SQLite's bind-variable limit.
2. Reads points in chunks of 500 process IDs.
3. Orders by process ID and timestamp.
4. Streams rows from a cursor into per-identity arrays.

Raw, minute, hour, bounded-slice, and evidence reads share this path. Existing
single-process reads remain selective and unchanged.

### 5. Database indexes and pruning

Migration v10 replaces the raw consumer index with a covering index that includes
`net_total`. Network leaderboards no longer require a table lookup for each raw
row.

It also adds `idx_processes_last_seen`. Dimension pruning now selects old process
rows through that index and uses correlated `NOT EXISTS` probes against each
history tier's process-first primary key. It no longer materializes distinct
process IDs by scanning every tier.

### 6. Bounded retention writer time

Time-based retention formerly deleted every expired row from six tables in one
writer transaction. A large policy reduction could hold SQLite's sole writer
while millions of rows were removed.

The pool path now deletes in 10,000-row transactions, rotates across tiers, and
stops after 500,000 rows in one maintenance pass. Later passes continue until the
policy converges. Size-cap enforcement uses the same 500,000-row ceiling.

Rollup, cutoff, tier priority, and recorded fidelity are unchanged.

### 7. Transaction cache recovery

`SampleStore` caches process row IDs and the last change-gated row. Those caches
were updated before the surrounding SQL transaction committed. If a later row
failed, SQLite rolled back but the Swift caches did not.

All write entry points now clear both caches after a failed transaction. A test
forces the second process insert to abort, removes the trigger, and retries the
same snapshot. Both processes then write successfully.

### 8. Cache lifecycle and stale work

Disabling persistence now releases all history-backed caches on their owning
queue, including system history, consumer boards, leak evidence, pressure events,
and group reports.

Group report insertion removes prior cached rules for the same group and window,
so repeated edits cannot retain an unbounded series of reports.

Background leak scans carry a persistence generation. A scan started for an old
or disabled store cannot repopulate caches or published leak highlights.

### 9. Fast system readers

`NetworkReader` now collects link counters and IPv4 addresses in one
`getifaddrs` traversal instead of acquiring and walking the interface list twice
per system tick.

`SystemMemoryReader` caches kernel page size and total physical RAM. Both are
immutable for the process lifetime and no longer require a Mach or sysctl call on
every sample.

### 10. Memory inspection process control

When a memory tool reaches its output cap, the runner now asks the child to stop
immediately and continues draining the pipe to EOF. This avoids pipe backpressure
turning an output limit into a full 30-second timeout.

The pipe reader starts only after a successful process launch. A launch failure
can no longer leave a reader waiting on EOF while retaining the process and pipe
file descriptors.

### 11. Smaller UI costs

- Analytics zoom domains and derived chart data commit at most once per 60 Hz
  frame, not once per trackpad event.
- Focused Analytics mode derives only the visible metric, not the hidden grid.
- History and trace slices use binary search.
- Downsample buffers reserve a bounded output capacity.
- The pressure timeline computes its color once per input, not once per chart mark.
- Byte formatting clamps extreme values safely.
- Disk throughput differences read and write counters separately, avoiding
  `UInt64` addition overflow.

## Verification

Automated checks:

| Check | Result |
| --- | --- |
| Full package suite | 280 tests passed. |
| Trace codec suite | 20 tests passed. |
| Process history suite | 11 tests passed. |
| Persistence suite | 12 tests passed. |
| Change-gated write suite | 8 tests passed. |
| Network suite | 14 tests passed. |
| Memory inspection suite | 18 tests passed. |
| Debug product build | Passed. |
| Release product build | Passed. |
| VS Code diagnostics | No errors. |
| `git diff --check` | Passed. |
| `plutil -lint Resources/Info.plist` | Passed. |

New regression coverage includes:

- Streaming decompression output limits.
- Oversized file rejection before full read.
- Unsupported versions and reserved bytes.
- Duplicate identities and unordered points.
- Non-finite and out-of-window values.
- Unsafe derived disk rates.
- Exact integer counter round trips.
- Cursor-level export point limits and cancellation.
- Write-cache recovery after transaction rollback.
- v10 index columns.

The release build still reports the pre-existing Swift 6 warning about reading
`ProcessGroupStore.shared` from a nonisolated app initializer. This audit did not
change that code path.

## Remaining priorities

These items are confirmed or strongly supported by source review, but need a
larger design change or signed-build measurement.

### P1: Measure the signed release against the budget

The canonical target remains under 60 MB physical footprint and under 2 percent
average CPU with the menu bar active and no main window open.

Run an A/B profile of the signed app for these states:

1. Menubar only, per-app network tracking off
2. Menubar only, per-app network tracking on
3. Main window on Dashboard at the default refresh interval
4. Analytics with eight processes in the grid
5. Analytics focused while continuously zooming and panning
6. Import, interact with, and close a near-limit trace
7. Export a large multi-process trace

Record `top`, `vmmap`, Time Profiler, Allocations, file descriptors, child-process
launches, and main-thread hang intervals. Source-level improvements are verified,
but this pass does not claim an unmeasured CPU or RSS percentage.

### P1: Reduce per-app network process cost

Per-app network tracking is enabled by default and uses repeated one-shot
`nettop` processes. The prior signed-build profile identified this as a leading
steady-state cost. A persistent CSV pipe, with the current adaptive one-shot path
as a fallback, could reduce process launches and setup work. It must prove rate
parity and prompt shutdown before replacing the stable path.

### P1: Reduce live Analytics mark count

The live grid remains bounded at roughly 12,000 Swift Charts marks in the worst
case: eight processes, five metrics, and 300 points. Equatable gates and frame
coalescing avoid unnecessary rebuilds, but a Canvas renderer would reduce the
cost of the rebuilds that are genuinely required.

### P2: Correct sparse rollup boundary carry-in

The raw-to-minute query applies its watermark before the `LEAD` window. A value
written before a bucket boundary may be the value held at that boundary, but it
is unavailable to the filtered window. This can bias a sparse bucket until its
first in-bucket row. Fixing it requires a predecessor row per process and focused
fixtures for process birth, death, delayed heartbeat, and multiple buckets.

### P2: Preserve data across standard bucket-width changes

Changing the standard bucket width advances the watermark to avoid key
collisions. The skipped raw interval can later expire without being represented
in the aggregate tier. A transition should finalize the old-width interval or
defer the new width to a safe boundary. This is a correctness change and needs a
separate migration-quality test matrix.

### P2: Move remaining on-demand parsing off the main thread

Memory inspection executes tools off-main, but large output parsing, diffing,
report construction, and report writing still return to main-thread model and
view code. Move parsing and report assembly to a worker, then publish one final
value.

### P2: Make near-limit codec work interruptible

Export reads and trace projection check cancellation during their row and point
loops. Foundation JSON encoding and decoding, plus one-shot compression, cannot
stop in the middle of a call. A cancelled near-limit operation therefore releases
its result but may keep its worker busy until that codec call returns. A streaming
container format or incremental encoder would provide prompt cancellation, but it
would need compatibility tests and careful peak-RSS measurement.

### P2: Avoid exact Settings row counts on the interactive reader

The Storage settings estimate runs seven exact `COUNT(*)` queries. On the live
database this took about 2.18 seconds during the audit and occupied the serial
interactive reader. Use maintained counters or fresh `sqlite_stat1` estimates,
or move this estimate to a separate low-priority reader.

### P2: Reuse helper FD buffers

The direct sampler uses one retained FD buffer and one normal-case syscall per
PID. The privileged helper still sizes and allocates a new buffer, then fills it,
for every protected PID. A helper-batch scratch buffer would remove one syscall
and repeated allocation per protected process.

### P3: Reduce fleet-sized sampling allocations

The process sampler still creates several dictionaries per scan, and UI trails
shift small arrays with `removeFirst`. Double-buffered dictionaries and fixed
ring buffers would reduce allocation and copying. Measure first: these costs are
frequent but smaller than process enumeration and optional `nettop` work.

### P3: Split menu list observation by kind

The menu lists are isolated from the main sampler, but all list kinds still share
one `ObservableObject`. A CPU-list publish can invalidate a mounted view that only
reads the network list. Per-kind observable state would narrow this fan-out.

### P3: Cache static network-page metadata

The detailed Network page runs its polls off-main, but each poll rebuilds
SystemConfiguration and interface metadata that changes rarely. Retaining one
dynamic store and invalidating static metadata on configuration notifications
would reduce background CF allocation.

## Recommended acceptance criteria

Do not accept further optimization solely from source inspection. Use these
checks:

- The menubar-only signed release meets the 60 MB and 2 percent budget.
- No sampling tick waits on a UI query, export, or maintenance transaction.
- Main-thread work stays below one display frame during trace interaction.
- A near-limit trace has bounded peak RSS and remains cancellable.
- Large exports do not delay Dashboard or process-history reads.
- Retention policy reductions keep sample insert latency bounded.
- Query-plan tests continue to report the intended covering indexes.
- Every optimization preserves recorded rows, aggregate meaning, and chart values.
