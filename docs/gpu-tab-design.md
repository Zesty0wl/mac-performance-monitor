# GPU tab: what Apple Silicon exposes, and a design

## Menu Charts and Awake Time (18 September 2026)

The GPU menu now has separate ANE time and power charts for the last 60 seconds.
Both use the existing recent samples and menu refresh. They need no extra timer
or database read. The axes show ms/s and watts, not a shared percent scale.
Missing readings break the lines. Partial ANE time is a lower bound. Without
the approved helper, ANE Time still works where supported, while ANE Power
shows **Helper required**. The dropdown scrolls so its contents fit small screens.

The former **Active** card is now **GPU awake**. It shows time with GPU power
and its clock on, including time spent waiting for work. A high value does not
mean the GPU is busy. The GPU utilization card reports busy time separately.
Awake time is 100 minus the OFF state's share in IOReport. A missing or invalid
OFF state now stays unknown instead of appearing as 100% awake.

The card previously had no history feed, so its detail chart stayed blank.
Schema v24 now records awake time and keeps valid-reading counts, means, and
bounds in minute and hour history. The card and detail chart use these records,
with a fixed 0-100% scale. Old logs have no awake-time data and stay gaps.
New history builds as the updated app records samples.

## Memory and Bandwidth (20 September 2026)

GPU Memory now has a recorded chart in both its card and detail sheet. Before
this fix, the live value worked but the card had no history feed. The detail
sheet therefore stayed on "Building history" with no way to fill it.

Schema v23 stores GPU memory bytes on each GPU sample. Minute and hour rows
keep the mean, minimum, maximum, and count of valid readings. Chart means use
those counts. Old rows stay unknown, not zero. History grows as the updated app
records samples; it cannot recover GPU memory values from older logs.

The **GPU memory bandwidth** panel shows Total, Reads, and Writes on one history
chart, using GB/s and the same time range as GPU utilization. Compact values
below the plot show the latest sample. Clock-state bars remain in the right-hand
rail. The data comes from the GPU's `AGX RD`, `AGX WR`, and `AGX RD+WR` channels
under IOReport `PMP / DCS BW`. The reader adds only these three channels to the
existing GPU sampling path. It does not start another process or request helper
access. It shares the GPU sampling gates and cadence.

These counters are histograms with event counts, not exact byte totals. On the
tested M3 Pro, macOS labels the bins from 1GB/s through 32GB/s. The estimate
weights each label's rate by its share of the reported events. It does not divide
by the sample duration again: the labels already represent rates. Each channel
uses its own counts. The combined estimate is not the sum of the other estimates.

This is a mean of band labels, not exact throughput, a time-weighted mean, or a
percent of GPU capacity. The readout uses an approximate sign and at most one
decimal place. If every event is in the lowest band, it says **Below resolution**;
that band can include no traffic. The chart is marked **Preview** and carries
one quiet caption explaining that actual bandwidth may be higher. This warning
does not repeat under Total, Reads, or Writes. Faster traffic can fall in the top band.
Neither edge band gives a precise bound from which to infer an exact mean.

Schema v25 stores the three estimated rates with each system sample. Minute and
hour records keep a separate mean, minimum, maximum, and valid-reading count for
each channel. Chart averages weight those recorded samples, not elapsed time.
Old records have no bandwidth values. The chart fills as the new build records
samples; closing the tab or restarting does not discard recorded history.

The shared chart renderer draws fixed-interval averages over the recorded range,
with all three series on one scale. Hover shows the selected interval's values,
bounds, and counts. The scale resets when the time range changes and only grows
during live updates. Colors stay fixed. Total uses the combined counter, not a
sum that could hide missing reads or writes.

The info popover and chart caption explain the limits. Missing channels,
unresolved lowest-band readings, invalid data, and stale readings remain gaps,
not zero. Upper-band traffic can be understated. Existing GPU sampling and
history queries supply the data; no separate timer or helper is needed.
Tests cover recording, restart, weighted rollups, chart range changes, live
updates, hover, and narrow and wide layouts. A native test confirmed all three
channels reach system samples on this Mac. Other hardware may not expose them.

## Ranges and Clock Help (18 September 2026)

The GPU tab starts at 30 minutes, like the other dashboard range selectors.
Each page keeps its own choice when you switch tabs, close a window,
or restart the app. Explorer also keeps the time span you chose by zooming.
Opening an alert does not replace that saved span.

The headline cards keep ANE Time and ANE Power next to each other in both the
wide row and compact grid. Their units and data sources remain separate.

Clock states now have a short explanation and an info popover:

- OFF means the GPU was powered down for that share of the latest sample.
- P states are speed levels, from lower to higher clock speeds.
- Each percent shows time in a state, not GPU load or a mean for the chosen
  history range. P3 at 25% means one quarter of the latest sample was spent in P3.
- Low states alone do not mean the GPU has hit a heat or power limit. Check
  Thermal limit and Power cap for limits. State names are not GHz values.
  This source does not give the exact clock speed for each state.

## ANE Power (18 September 2026)

**ANE power** now appears beside ANE Time, with its own card and history chart.
The menu-bar panel, Explorer, and Ask's energy-history tool also show watts.
Power remains separate from accounted time. It is not converted to a percentage,
and a zero-power reading does not prove that no inference ran.

Enable **Show every process** under **Settings > Advanced > Full Coverage**
and approve the helper in macOS if prompted. The helper must match this app
build. The main app never runs as root or handles your administrator password.
ANE Time still works without the helper. Missing power shows as unavailable,
not zero; older history is not relabeled as helper-backed power.

The signed helper runs Apple's tool with fixed arguments:

```sh
/usr/bin/powermetrics --samplers cpu_power,gpu_power,thermal -f plist -i 1000 -n 60 -b 0
```

This is the power source used by asitop. The app does not install or run asitop.
It divides `processor.ane_energy` (millijoules) by the actual `elapsed_ns`
interval to get watts. If energy is absent, it accepts the native `ane_power`
field in milliwatts. It rejects invalid values, incomplete frames, and stale
readings. It does not assume an 8 W maximum or an exact one-second interval.

There is one root sampler shared by helper connections, not one per chart.
Sampling runs while GPU monitoring, GPU alerts, or history recording needs it.
The app renews a short lease once a second, even with a slower UI refresh rate.
Disabling coverage, pausing sampling, or removing all demand releases the lease.
Disconnects release it too; a lost client expires after about five seconds.
Each child takes at most 60 samples, then a new one can serve ongoing demand.
A watchdog stops silent or overlong children. Failures back off before retrying.

The child has a fixed path and arguments, no shell, and a restricted environment.
The helper accepts no executable, file path, sample interval, or command from
the caller. It parses bounded plist frames in memory and returns only ANE watts,
the source timestamp, and the sample interval. It saves no raw powermetrics
output. Replies expire after five seconds. The app's sampling queue never waits
for the helper or child process.

Schema v22 records the source timestamp and interval with new power readings.
Minute and hour history retain valid-reading counts and true minimum/maximum
values. Chart averages use those counts; cached copies count as recorded rows,
not separate hardware measurements. Samples without a helper source remain
gaps in the new power charts. Historical source power is an OS estimate, not
a calibrated measurement of electrical draw.

Tests cover the parser, the real XPC bridge, stale replies, lease expiry,
shared-child shutdown, bad output, and failed child starts or exits. A replay
of this Mac's asitop capture yielded nonzero ANE watts through the same parser.
Live root collection in the updated signed helper still needs an installed-app
check; non-root fixtures do not prove helper approval or launchd registration.

## ANE Activity Preview (18 September 2026)

This build replaces the power-derived ANE percentage with **ANE time**, in
milliseconds per second (`ms/s`). For example, 750 ms/s means macOS accounted
for 750 milliseconds of ANE work per elapsed second. It is not a percentage
of compute capacity, and it is not capped at 1,000 ms/s.

The GPU tab, its metric detail sheet, the menu-bar panel, and Explorer show
this measure. Ask can read it through its GPU-history tool. New samples no
longer use ANE power to infer activity. Old power columns remain in the
database, but this build does not use them to declare the ANE idle.

The reader polls unique resource coalitions at most once a second. A coalition
is a kernel resource group, not necessarily one app. It subtracts each group's
cumulative ANE ticks, converts the delta with the Mach timebase, and divides
by the elapsed interval. Shared Apple inference services prevent reliable
attribution to the app that made a request. No helper, root access, model
download, or Instruments installation is needed to read the counter.

This is a guarded private interface. The current preview enables it on macOS
27 only and checks the returned record layout. Other OS versions, missing
symbols, unknown layouts, failed reads, and counter resets produce unavailable
readings. Pauses and long gaps start a new baseline. This is not a claim of
support for every Apple silicon chip: live tests used an M3 Pro on macOS 27.

New groups start with a baseline. A group that disappears or cannot be read
makes the result partial. Such values are lower bounds, shown as **At least**
with **Partial coverage**. A partial zero is not evidence of inactivity.
The empty resource group that returns `EINVAL` has no tasks and is ignored.

Schema v21 adds nullable ANE time and coverage columns. Old rows stay unknown.
Minute and hour records retain valid-reading counts, minimum, maximum, and
coverage. Means use valid sample counts, not elapsed time or all system rows.
Repeated cached readings count as recorded samples. Charts keep missing data
as gaps and use fixed time intervals for their average line.

The isolated reader agreed with Instruments' prediction intervals within about
1.5 percent for a single request and two concurrent requests. CPU-only and
GPU-only controls added no ANE time. It also worked with hardened-runtime
signing and no profiler attached. A warm full read of about 850 coalitions took
1.37 ms at the median; this is a reader benchmark, not an app energy budget.
The production sampler has a separate opt-in live test in GPUAttributionTests.

Later testing found nonzero ANE power in asitop 0.0.24's native plist capture.
Our IOReport probe also began receiving ANE energy while asitop's privileged
powermetrics sampler was running. The earlier zero readings therefore do not
establish that this Mac cannot report ANE power. The exact activation or refresh
condition is still unknown. asitop divides reported energy by its configured
interval and an assumed 8 W maximum to estimate a percentage. That remains a
power-based estimate, distinct from the accounted ANE time shown in this build.
The new reader was verified without a running profiler or root sampler.

The older implementation notes below describe the GPU surfaces that remain
unchanged. Their ANE power assumptions are superseded by this section.

## Earlier GPU Implementation

Status: implemented on 2026-08-23 (phases 1 and 2 below, plus the
sustained-GPU alert from phase 2): `GPUProcessReader` (Core/System),
`GPUWorkload` and the alert (Core/Analysis), the IOReport state channels in
`PowerReader`, the v13 schema, `GPUView` with `GPUTimelineStore`, and the GPU
columns on `ProcessOutlineTable`. Research verified on this Mac (Apple M3
Pro, macOS 26.6) on 2026-08-23 with `ioreg`, the SDK headers and a small
probe of the private IOReport library. Still open from phase 3: per-process
GPU history charts in the inspector and MHz labels after a per-chip validation.
The ANE accounting preview above now covers the earlier coalition probe proposal.
The app is Apple Silicon only, so everything
below assumes the AGX (Apple GPU) driver stack. The GPU menu bar dropdown lists the top GPU
processes too, and an open GPU panel (the tab or the dropdown) reads the
device at the dial rate rather than once a second.

## Why this tab

AI runtimes (Ollama, llama.cpp, MLX, LM Studio, PyTorch with MPS, Core ML
models, Apple Intelligence) share the GPU and the Neural Engine with ordinary
apps, and nothing on the Mac shows who is using them beyond Activity
Monitor's "% GPU" column. The tab should answer, at the dial rate: how busy is
the GPU, at what clock and power, who is using it, how much of that is AI
work, and is the Neural Engine busy.

## What the OS exposes (verified)

### 1. Device level, IORegistry, no privilege (already used by `GPUReader`)

`AGXAcceleratorG15X` (class name varies by chip) carries
`PerformanceStatistics`:

| Key | Seen | Meaning |
| --- | --- | --- |
| `Device Utilization %` | 83 | whole-GPU busy percentage over the driver's window |
| `Renderer Utilization %`, `Tiler Utilization %` | 83, 83 | the two halves of the pipeline |
| `In use system memory` | 2.75 GB | unified memory currently mapped for GPU use |
| `Alloc system memory` | 9.13 GB | memory allocated to GPU clients (includes cached/unused) |
| `TiledSceneBytes`, `SplitSceneCount`, `Allocated PB Size` | | tiler detail |
| `recoveryCount`, `lastRecoveryTime` | 0 | GPU hang recoveries, worth surfacing as an alert |

Also on the accelerator: `gpu-core-count` (14), `GPUConfigurationVariable`
(generation, core mask), `MetalPluginName`. The chip name comes from the
`machdep.cpu.brand_string` sysctl. One property fetch, microseconds.

### 2. Per process, IORegistry, no privilege (the key finding)

Every process that has touched Metal has one or more `AGXDeviceUserClient`
entries under the accelerator (83 on this Mac right now). Each has:

- `IOUserClientCreator` = `"pid 413, WindowServer"` (the name is truncated to
  16 characters; the pid is the key and our scan has the full name).
- `AppUsage` = an array, one element per Metal context the process opened:
  `{"API"="Metal", "accumulatedGPUTime"=20828301005375, "lastSubmittedTime"=170032797844625}`.

Units, measured: `accumulatedGPUTime` is nanoseconds of GPU time
(WindowServer gained 1.707 s of it over a 2.08 s wall interval, 819 ms/s,
while the device counter read 83%); `lastSubmittedTime` is nanoseconds since
boot on the mach continuous clock (it matched `mach_absolute_time` converted
with the 125/3 timebase). So for each process:

- GPU time per second = delta of the summed `accumulatedGPUTime` across its
  clients / wall delta; GPU % = that / 1.0 s. This is the figure Activity
  Monitor shows, and it needs no helper.
- "Last active" = newest `lastSubmittedTime`, which separates a process that
  holds a Metal context (almost every app) from one that is actually
  submitting work.
- Several clients per pid are normal (WindowServer has a dozen); sum them.
- Entries persist for the life of the context, so a process that rendered
  once an hour ago still appears with a flat counter; the tab should rank by
  rate, not by total.

Cost and a trap: `IOServiceGetMatchingServices` never returns user clients
(they are attached to the accelerator without being registered as services;
`ioreg -c` walks the registry, the matching API does not), so the reader
finds the `IOAccelerator` services and walks their children with
`IORegistryEntryGetChildIterator`. Each IOKit property read is tens of
microseconds: a full pass over ~90 clients is 2 to 3 ms warm, and the reader
caches registry-entry-id to pid so the dial-rate pass reads `AppUsage` only
for the rows on screen (about 1 ms for 30). The full pass rides the 1 s
scan; the filtered pass rides the visible-row refresh, exactly like the
process table.

Not available per process: GPU memory (no key on the client; Activity Monitor
does not show it either; the process's `phys_footprint` already includes its
IOKit/GPU allocations, which is the honest proxy), and a breakdown by
render/compute.

### 3. Device level, IOReport, no privilege

`/usr/lib/libIOReport.dylib` (private, the library `powermetrics` uses) loads
and samples without root. The probe (scratchpad `ioreport/probe.swift`)
enumerated 9,215 channels; the useful groups for this tab:

| Group / subgroup | Channel | What a 1 s delta gave |
| --- | --- | --- |
| `GPU Stats` / `GPU Performance States` | `GPUPH` (state format) | OFF 10%, P1 38%, P2 45%, P3 5%: active residency and the clock distribution |
| `GPU Stats` / `GPU Software Performance States` | `GPU_SW` | the same from the driver's side |
| `GPU Stats` / `GPU Boost Controller Performance States` | `BSTGPUPH` | boost state residency |
| `GPU Stats` / `CLTM-induced GPU Performance States` | `GPU_CLTM` | `NO_CLTM` 100%: thermal throttling indicator |
| `GPU Stats` / `GPU Power Controller States` | `PWRCTRL` | `IDLE_OFF` 10%, `DEADLINE` 58%, `SE` 30%: why the GPU is clocked as it is |
| `GPU Stats` / `PPM Target as % of Max GPU Power` | `GPU_PPM` | power cap in effect |
| `GPU Stats` / `GPU Discrete Power Zone Residency` | `PZRSDNCY` | power-zone residency |
| `Energy Model` | `GPU` (mJ), `GPU Energy` (nJ), `GPU SRAM` | 3,556 mJ over the second = 3.6 W GPU power |
| `Energy Model` | `ANE` (mJ) | Legacy reported energy; observed staying zero during real ANE execution on macOS 27 |
| `Energy Model` | `CPU Energy`, `DRAM`, `DISP` | context for an energy view |
| `ANE` / `IOP State` | `status` | ANE controller state residency |
| `GPU Stats` / `Temperature` | `Tg*` | all zero without root; treat as unavailable |
| `GPU UT AggD Stats`, `GPU UT Engagement` | per-perf-state engagement counts | utilisation-per-state histograms, a second source for the clock picture |

The GPU DVFS table is in the IORegistry (`pmgr`, `voltage-states9`): 14
(frequency, voltage) pairs, 0 and 338 to 1312 MHz on this chip. The IOReport
state names (`P1`..`P3` here) do not map one to one onto those 14 entries, so
a MHz figure needs a per-chip validation against `powermetrics` before it is
shown as a number; residency percentages are reliable as they are.

Cost: a subscription to `GPU Stats` + `Energy Model` + `AMC` + `PMP` + `ANE`
sampled in 8 ms (691 channels). Subscribing only to the dozen channels the
tab needs should bring that under a millisecond; sample it once a second
while only the icon or the history wants it, and every tick while a GPU panel
is open (the driver's utilization figure moves between sub-second reads), and
interpolate nothing. This is private API: load it with `dlopen`, look
every symbol up, and degrade to the IORegistry counters if anything is
missing, so a macOS change never takes the tab down.

### 4. Own process only

`task_info(TASK_POWER_INFO_V2)` returns `gpu_energy.task_gpu_utilisation`
(in the public SDK `mach/task_info.h`) and `MTLDevice` reports
`currentAllocatedSize` and `recommendedMaxWorkingSetSize`, but both only for
the calling task. Useful for the app's own GPU footprint (the strip charts
are CPU-drawn; this should read near zero) and for nothing else.

### 5. Needs root or private headers, and why we do not need them

- `task_for_pid` + `TASK_POWER_INFO_V2` for other processes: needs the
  `com.apple.security.cs.debugger` entitlement on the helper and still fails
  for platform binaries (WindowServer, Safari) under SIP. Superseded by
  `AppUsage`.
- Coalition resource usage (`coalition_info_resource_usage`, `ane_mach_time`):
  used by the ANE activity preview above. It is a private interface, but the
  tested read-only path does not require a helper. A coalition is not a promise
  of per-app attribution.
- `powermetrics` (root): nothing it reports about the GPU is missing from the
  sudoless IOReport channels; keep it as a one-off validation tool.

### 6. The Neural Engine

The earlier registry probe showed one ANE device (`H11ANEIn`) with a daemon
client. Current Apple model requests accrue time in shared inference-service
coalitions. Neither observation reliably identifies the requesting app.
Controller state is separate from execution: in the September test it stayed
Running after predictions ended. The current preview uses accounted ANE time,
not controller state or correlations with process CPU.

## Attribution model

1. **Per process**: GPU ms/s and GPU % from `AppUsage` deltas, keyed by our
   `ProcessIdentity` (pid + start time, so a reused pid cannot inherit a
   counter). First sight of a process seeds the counter; the rate starts on
   the next sample. A counter that goes backwards (context torn down and
   recreated) resets the seed.
2. **Per app**: browsers and Electron apps do their GPU work in helper
   processes ("Google Chrome Helper (GPU)", "Cursor Helper (GPU)", Safari's
   `com.apple.WebKit.GPU`), video goes through `VTDecoderXPCService`, calls
   through `avconferenced`. Roll helpers up to the app by the existing
   parent-pid chain and bundle path (the Processes tab's hierarchy already
   builds this), and show both the app total and the helper breakdown.
3. **Categories** (the memory taxonomy pattern, `Taxonomy.swift`):
   - *AI and ML*: Ollama (`ollama`, `ollama runner`), llama.cpp
     (`llama-server`, `llama-cli`), LM Studio and its `lms` helper, MLX
     (`python`/`mlx_lm` with MLX loaded), PyTorch MPS, Draw Things,
     DiffusionBee, ComfyUI, Core ML hosts (`ANECompilerService`, `aned`),
     Apple Intelligence (`IntelligencePlatformComputeService`,
     `GenerativeExperiencesRuntime`), `mediaanalysisd`, `photoanalysisd`.
   - *Display and UI*: WindowServer, `Dock`, `SystemUIServer`, app GPU
     helpers.
   - *Media*: `VTDecoderXPCService`, `avconferenced`, `coreaudiod`, `replayd`,
     Screen Sharing.
   - *Everything else*.
   A generic `python`/`node` process is the hard case. Two cheap signals:
   the command line (`sysctl KERN_PROCARGS2`, readable for the user's own
   processes: `mlx_lm.server`, `torch`, `--model`), and the loaded images
   (`proc_pidinfo(PROC_PIDREGIONPATHINFO)` walks a same-uid process's mapped
   files without root: `libtorch`, `libmlx`, `libggml-metal`,
   `Metal.framework` with a large GPU rate). Both are worth a spike.
4. **Device context**: the per-process sum can exceed the device figure
   (contexts overlap on the GPU); show the device utilisation as the
   headline and per-process shares normalised to it, with the raw ms/s in
   the table.

## The tab

Same structure as the Disk and Dashboard tabs, built on the live surfaces
(strip charts, feeds, the dial-rate table):

1. **Header cards** (AppKit feeds, dial rate): GPU utilisation (value +
   sparkline), power (W, from the energy model), clock (active residency,
   P-state bar; MHz once validated), memory in use / allocated, Neural Engine
   (power, active %), with a thermal/cap badge when `GPU_CLTM` or `GPU_PPM`
   says the GPU is being held back.
2. **Utilisation timeline** (strip chart): device utilisation with the
   AI-category share as a filled band beneath it, so "the GPU was pegged and
   it was Ollama" reads at a glance; range picker as elsewhere.
3. **Who is using the GPU** (the process table pattern: visible rows at the
   dial rate, full re-rank every 5 s): app, category, GPU %, GPU ms/s, last
   active, CPU %, memory, helper breakdown on disclosure. Ranked by GPU rate,
   idle contexts folded into "n apps holding a Metal context, idle".
4. **By category** (the memory-composition bar): AI and ML / Display and UI
   / Media / Other, from the per-process rates.
5. **AI workloads card**: the detected runtimes with model names where the
   command line gives them, their GPU share, memory footprint, and ANE
   activity when the runtime is Core ML.
6. **Insights and alerts**: sustained GPU load from a background or AI
   process, a new AI runtime appearing, thermal throttling, GPU recovery
   count rising, ANE active for more than a minute.

## Data model and storage

- `GPUSample` (exists: utilisation, render/tiler, memory, name, cores) gains
  `powerWatts`, `activeResidency`, `performanceStates: [(name, residency)]`,
  `throttled`, `powerCapPercent`, `anePowerWatts`, `aneActive`,
  `recoveryCount`.
- `ProcessSample` gains `gpuTimeNanos` (cumulative, from `AppUsage`) and
  `gpuPercent` (derived), plus `gpuLastActive`.
- History: a `gpu_samples` table at the system-sample cadence for the device
  figures, and `gpu_time` on the process rows (change-gated like the rest).
  Retention as the existing tables.
- `Sampler.tickSystem` reads the accelerator statistics and the IOReport
  delta (every tick while a GPU panel is open, otherwise once a second); the per-process
  `AppUsage` scan rides the 1 s process scan and the dial-rate visible-row
  refresh.
- The menu bar GPU item keeps reading the cheap device counter; its dropdown
  lists the top GPU processes from the popover-cadence scan, with the AI
  runtime named next to each row that is one.

## Risks and fallbacks

- `AppUsage` and the IOReport channels are undocumented. Guard every key and
  symbol; fall back to device utilisation only (the current behaviour), and
  keep a diagnostics dump (the probe, productised as `--probe-gpu`) so a
  report from another chip or macOS version can be read from the output.
- Names in `IOUserClientCreator` are truncated; always key on pid and take
  names from the scan.
- A process with a Metal context but no recent submission is not "using the
  GPU"; rank by rate and show last-active, or every app on the Mac will
  appear in the table.
- MHz labels: residency is solid, the frequency mapping needs one validation
  pass per chip generation (compare with `sudo powermetrics --samplers
  gpu_power` once); until then show residency and state names.
- Neural Engine per process is not attributable; say so in the UI rather than
  guess, and offer the heuristics as "likely".

## Phasing

1. Device panel + per-process table + categories (all sudoless, all
   verified): the bulk of the value.
2. AI runtime detection (names, command lines, loaded images), the AI
   workloads card, ANE device activity, alerts.
3. Per-process GPU history charts in the inspector, MHz after validation,
   the optional helper-side coalition probe for per-process ANE if it proves
   out.

## Open questions

- Should the GPU table be its own tab or a mode of the Processes tab? (The
  research says the data is per process either way; a dedicated tab gives
  room for the device and AI panels.)
- Which AI runtimes matter most to you day to day? The detection table
  starts from Ollama, llama.cpp, MLX, LM Studio and Core ML.
- Is a helper-side private coalition probe acceptable for per-process ANE,
  or should the tab stay on public-ish data only?
