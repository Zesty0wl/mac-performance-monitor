# GPU tab: what Apple Silicon exposes, and a design

Status: implemented on 2026-08-23 (phases 1 and 2 below, plus the
sustained-GPU alert from phase 2): `GPUProcessReader` (Core/System),
`GPUWorkload` and the alert (Core/Analysis), the IOReport state channels in
`PowerReader`, the v13 schema, `GPUView` with `GPUTimelineStore`, and the GPU
columns on `ProcessOutlineTable`. Research verified on this Mac (Apple M3
Pro, macOS 26.6) on 2026-08-23 with `ioreg`, the SDK headers and a small
probe of the private IOReport library. Still open from phase 3: per-process
GPU history charts in the inspector, MHz labels after a per-chip validation,
and the optional helper-side coalition probe for per-process ANE. The app is Apple Silicon only, so everything
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
| `Energy Model` | `ANE` (mJ) | Neural Engine energy, 0 when idle: the ANE activity signal |
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
- Coalition resource usage (`coalition_info_resource_usage`: `gpu_time`,
  and in recent kernels `ane_mach_time` and `gpu_energy_nj`): the header is
  not in the SDK, so it would be a private syscall. It is the only known
  per-process Neural Engine accounting. Park it as a possible helper-only
  probe for a later phase, behind a feature flag.
- `powermetrics` (root): nothing it reports about the GPU is missing from the
  sudoless IOReport channels; keep it as a one-off validation tool.

### 6. The Neural Engine

The registry shows one ANE device (`H11ANEIn`) with a single client, `aned`:
every Core ML workload is proxied through the daemon, so per-process ANE
attribution is not available from the registry. What we can show: ANE energy
and state residency (device level), and heuristics for who is likely driving
it (Core ML apps, `mediaanalysisd`, `photoanalysisd`, Apple Intelligence
services) by correlating ANE activity with those processes' CPU.

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
