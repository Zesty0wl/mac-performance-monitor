# Alerting Audit And Redesign

10 September 2026. Audit and proposal, not a change to the alert rules.

This audit describes the rules before the redesign. The resulting
[adaptive alert implementation](adaptive-alerts.md) now records what changed
and how to verify it.

## Recommendation

Alerts should tell you what changed, why it matters, and when to act. A large
number alone is not enough. The current system mixes a reading, an active
condition, and a reason to interrupt you. It can flag a healthy Mac, then stay
silent as a real problem grows.

Use trend-based incidents instead. An incident is one spell of related trouble.
Track when it starts, how serious it is, and whether it is getting better.
Keep weak signals quiet. Send a notice for a confirmed risk, then again only
when it gets much worse. Keep critical-pressure protection prompt.

This does not need an AI model. We need to track change over time and test the
rules against real work.

## What The Current Rules Do

- **Swap:** fires on one reading above the configured byte limit. It re-arms
  only below 80% of that limit. It checks neither growth nor pressure.

- **Process ceiling:** the same threshold pattern, per PID and start time.
  It clears after the footprint shrinks enough or that process leaves the sample.
  There is no minimum duration or escalation for further growth.

- **Leak:** fires when an identity first enters the leak board. It re-arms when
  the identity leaves. The alert discards the finding's growth rate, fit, span,
  and size, and keeps only the identity.

- **Critical pressure:** fires at the kernel's critical level, without a dwell
  time. It stays active through warning and re-arms only at normal pressure.

- **CPU and GPU:** fire after eight seconds above a fixed percent threshold.
  They re-arm below 80% of that threshold. Busy work alone meets the rule.

- **Thermal:** fires after 30 seconds in a serious or critical thermal state.
  It clears at fair or nominal. The busiest CPU process is context, not proof
  that it caused the heat.

Every rule has a five-minute cooldown per alert ID. This limits repeat
deliveries after re-arming; it does not schedule reminders or check escalation.
Every delivered alert requests sound. There is no shared notification budget,
severity gate, per-process snooze, or merge of related memory warnings.

The recent menu work exposes active alerts, but retains their original message
and detection time. It improves access, not the quality of the rules. Values in
an old message do not update as the incident changes.

Sources: [AlertEngine.swift](../Sources/MacPerfMonitorCore/Analysis/AlertEngine.swift#L211)
and [AlertCenter.swift](../Sources/MacPerfMonitor/Alerts/AlertCenter.swift#L69).

## Why The Swap Example Happens

The saved setting is 3 GiB, or 3,221,225,472 bytes. The UI calls these units GB.
Once swap exceeds it, `swapArmed` becomes false. Swap must fall below 2.4 GiB
before another crossing can fire. Growth to 4, 10, or 30 GiB adds no new event.
Waiting five minutes or a day does not change that.

The message also quotes the threshold, not the reading at detection. The engine
can say "Swap has passed 3.0 GB" when swap is already 20 GiB. Its title,
"Swap is growing", claims a trend that the rule never measures.

A second blind spot follows from the order of operations. If a new spell starts
inside the cooldown, the engine latches it and drops its notification. When the
cooldown ends, that ongoing spell has no new edge, so it remains silent.

Restarting the app has the opposite effect. Alert state is in memory, so the
first high reading can fire again despite no new deterioration. Reducing the
cooldown or raising the byte limit would not solve these problems.

Source: [AlertEngine.swift](../Sources/MacPerfMonitorCore/Analysis/AlertEngine.swift#L328).

## Evidence From This Mac

I read the existing database and alert preferences without writing to either.
Queries ran around 11:04 to 11:09 BST on 10 September. They read a live database,
not a frozen copy. The figures below describe that query run, not the present.

The Mac has 18 GiB of RAM. Swap, critical pressure, leak, process-ceiling, and
high-CPU alerts are enabled. The ceiling is 8 GiB and the CPU threshold is 85%.
The saved legacy config omits GPU and thermal flags; their defaults are off.

The minute history contains a continuous ten-minute rise on 9 September:

- At **09:16 BST**, mean swap for the minute was **21.16 GiB**.

- At **09:26 BST**, it was **25.96 GiB**, a rise of **4.80 GiB**.

- All ten steps had 60-second spacing. This comparison does not cross a
  recording gap. The highest recorded pressure index in the window was 63.89,
  within this app's warning band.

The lowest recorded swap minimum in the queried 48 hours was about 15.21 GiB.
That reinforces why the old message's 3 GB is not evidence of swap at detection.
There were also critical-pressure peaks elsewhere in the recorded period.
These signals suggest memory strain; they do not prove visible slowness.

During the more settled night, swap stayed within about 26.4 to 27.8 GiB.
I checked 720 complete five-minute windows ending from 20:00 on 9 September
through 07:59 on 10 September, in BST. Of those, 54 rose by at least 512 MiB.
None rose by 1 GiB; the largest rise was about 0.98 GiB. These are overlapping
windows, not 54 distinct incidents. A naive growth threshold would still be noisy.

The available unified log shows leak delivery attempts at 06:25, 06:55, 07:25,
and 07:55 on 10 September. The log records kind and title, not the process ID
or growth evidence. It cannot tell us whether these were the same process.
Delivery attempts also do not prove macOS displayed a banner.

There is no stored alert-incident ledger to reconstruct the original swap
notification. The code and probes explain the missed escalation, but the
available evidence cannot establish the exact original firing time or value.

## Why Leak Detection Overreaches

The detector fits a straight line to footprint over time. Defaults require:

- At least **20 minutes**, with **12 samples**.

- A slope of at least **8 KiB/second** and **32 MiB total growth**.

- An **R-squared of at least 0.85**, measuring fit to that line.

The board first tries up to two hours of minute aggregates, with the sample
floor relaxed to eight. If that fails, it tries 30 minutes of raw history,
averaged into 30-second buckets. Either result is enough. A long-window failure
does not veto a short-window finding, despite comments describing the latter
as a path for young processes.

This is evidence of growth, not a leak diagnosis. Caches, document loads,
compilation, and deliberate allocations can all grow smoothly. Footprint alone
does not reveal whether an allocation is unreachable or will later be freed.
The fixed 32 MiB floor also ignores the process's size and the machine's RAM.

There is no separate check that the last few minutes are still growing, that
samples are fresh, or that the process is still present. A long trend can
remain a good line fit after a plateau. A gap can count toward the required
duration. Historical rows can keep an exited process on the board.

The internal confidence score combines fit and slope. It is not a calibrated
probability that the process leaks. Smoothing and the choice of window can
change that score without providing new evidence about a leak.

Sources: [LeakDetector.swift](../Sources/MacPerfMonitorCore/Analysis/LeakDetector.swift#L58)
and [LeakBoard.swift](../Sources/MacPerfMonitorCore/Persistence/LeakBoard.swift#L76).

## Reproductions

Four temporary XCTest probes ran against the actual Swift code.
Together with the existing alert and leak tests, **30 tests passed**. The probes
confirmed the limitations below; passing them does not mean the rules are good.
I removed the temporary files after the audit.

- **High swap on first observation:** 4 GiB at normal pressure fired a swap
  alert. A fresh 30 GiB sample one day later fired none. The active message and
  detection date still described the first event.

- **Cooldown swallows a new spell:** swap crossed the limit at time zero,
  recovered at 60 seconds, and crossed again at 120 seconds. The engine dropped
  the second notice. At 600 seconds, with swap now 10 GiB, it still sent none.

- **Small smooth growth:** the detector flagged a 4 GiB process growing by
  2 MiB/minute for 20 minutes. It scored about 81%, for only 40 MiB of growth.

- **Growth already stopped:** the detector flagged 30 minutes of growth followed
  by 15 flat minutes. Growth had been 16 MiB/minute. R-squared was 0.924 and the
  confidence score was about 95%.

- **Missing observations:** twelve points spanning 65 minutes, with a 55-minute
  gap, produced a leak finding with confidence 100%.

- **Cyclic releases:** a synthetic rising baseline with repeated allocations
  and releases failed the line-fit test. That pattern can hide real growth.

- **Old process history:** a database fixture whose last process sample was
  75 minutes old still returned a leak candidate.

- **CPU sampling gap:** two fresh 95% CPU samples an hour apart, with no readings
  between them, satisfied the eight-second sustained rule.

These fixtures expose algorithmic limits. They do not establish that a specific
app on this Mac has a leak or caused a particular notification.

## Other Gaps To Address

**Freshness and failures.** CPU/GPU/thermal timers use elapsed wall time without
a maximum sample-gap check. The app's wake handler only checks for updates.
Failed swap reads also become zero, and failed pressure reads become normal.
Those fallbacks can look like recovery. Missing data needs an unknown state.

**Logging dependencies.** Background leak scans run after retention, about every
third retention pass. Turning history recording off closes the store and clears
the leak input set. The leak toggle can remain on without fresh trend evidence.
Enabled GPU alerts likewise are absent from the GPU-sampling enable expression.
With recording and GPU surfaces off, the GPU rule can receive no sample.

**Transient query failures.** Leak-board read errors become empty arrays. That
can clear the active identity set and re-arm notices. A later successful scan
can then look like a new leak, without any real recovery in between.

**Test gaps.** The flat/noisy leak test spans 760 seconds, less than the required
1,200 seconds. It exits before testing noise rejection. Current tests cover
simple growth and threshold re-arming, not plateaus, stale history, escalation,
restart continuity, or a notification budget across many processes.

**Inconsistent meaning.** The Dashboard already treats normal pressure with
swap in use as healthy. The swap alert ignores pressure and says growth.
Settings describes bytes written, but the rule reads current occupancy.
These surfaces need one shared definition of risk.

Sources: [SamplerModel.swift](../Sources/MacPerfMonitor/ViewModels/SamplerModel.swift#L1066),
[scheduleLeakScan](../Sources/MacPerfMonitor/ViewModels/SamplerModel.swift#L1819),
[SystemMemoryReader.swift](../Sources/MacPerfMonitorCore/System/SystemMemoryReader.swift#L89),
and [AnalysisTests.swift](../Tests/MacPerfMonitorCoreTests/AnalysisTests.swift#L21).

## Build On Signals We Already Read

Keep swap occupancy, its net growth, and actual paging activity distinct.
Flat occupancy can coexist with heavy paging; growth can occur before critical
pressure. Neither the total nor its slope alone describes the whole risk.

The low-level reader gives us `swapIns` and `swapOuts`. Building `SystemSample`
drops them, so the alert engine and database never see them. Carry their deltas,
actual elapsed time, page size, and validity through instead. Reuse that kernel
read. Generic page-in/page-out counters are not a
substitute for swap-specific counters. Page-based rates describe logical memory
traffic, not exact physical SSD bytes after compression.

Use kernel pressure, compression/decompression, available disk space, and
process footprint growth as supporting evidence. Disk activity and a large
process are context, not proof that a particular app caused swapping. The app
does not currently measure the user's perceived responsiveness.

Yesterday's exact swap-in/out rates cannot be recovered from retained history.
The historical replay can test net growth and stored pressure, but a new paging
rule needs fresh recordings before its precision can be measured.

Sources: [SystemMemoryReader.swift](../Sources/MacPerfMonitorCore/System/SystemMemoryReader.swift#L53)
and [Sampler.swift](../Sources/MacPerfMonitorCore/Sampling/Sampler.swift#L793).
Apple also distinguishes swap occupancy from memory pressure, which includes
swap rate: [Activity Monitor memory guide](https://support.apple.com/guide/activity-monitor/view-memory-usage-actmntr1004/mac).

## Proposed Alert Policy

### Track Episodes, Not Crossings

Use **Normal, Watching, Action Needed, Recovering, Resolved, and Unknown** states.
Keep severity and notification eligibility separate from the active incident.
An incident should hold its baseline, current values, peak, growth rate, evidence
window, last observation, and last communicated severity and values.

Update the menu quietly as measurements change. Send a notice on first confirmed
risk or major worsening since the last notice. Compare with the values in that
notice, not the previous tick. A cooldown delays a still-valid pending
notice; it must not discard it for the rest of the incident. No new evidence
means no automatic repeat banner.

Recover from a growth episode when the growth and risk settle for a sustained
period, even if swap stays above its old baseline. Keep a separate pressure
incident active if the kernel still reports a dangerous state. Persist enough
incident and delivery state to avoid duplicate warnings after an app restart.

Group related pressure, swap, and process-growth evidence into one memory
incident where warranted. Do not claim a shared cause merely because alerts
overlap. Use a global rate limit for ordinary banners, with an urgent exception
for genuine escalation. Keep Watching items separate from the red alert count.

### Swap: Sustained Growth Or Active Strain

Use both short and medium windows, for example five and fifteen minutes.
Check for fresh samples, meaningful net growth, and growth that is still ongoing.
Use an absolute size floor and a scale based on RAM. Estimate normal variation
with a method that resists isolated spikes, such as median absolute deviation.
Update that baseline only from settled periods. Otherwise the detector could
learn a worsening problem as normal.

A 1 GiB rise in five minutes is a useful replay candidate on this Mac, not a
validated default for every Mac. The measured overnight noise rejects a simple
512 MiB trigger as sufficient evidence by itself. Thresholds need calibration
across RAM sizes, recording cadences, and workloads.

Elevated pressure or sustained swap activity raises urgency. Exceptionally fast
growth can justify an early warning even before pressure turns critical. A
separate paging-strain rule should catch heavy churn when occupancy is flat.

Allow another notice when severity rises, growth accelerates materially, or
substantial additional growth has occurred since the last notice. Do not make
that conditional on swap first shrinking below yesterday's fixed limit.

### Processes: Growth Evidence Before Leak Claims

Call the first observation **sustained memory growth**, not a diagnosed leak.
Keep modest growth as an insight. Require a fresh, still-running identity and
valid, sufficiently dense data before any active process warning.

Require the recent trend to agree with the long trend. Detect a plateau and
lower the warning as it settles. Assess the total increase against both RAM
and the process baseline. Allow cyclic releases by examining whether the lower
memory level keeps rising, rather than demanding a nearly perfect straight line.

Use repeated confirmation and stricter recovery hysteresis to stop findings
flapping in and out of the board. Confidence should describe evidence quality,
not a percentage chance of a leak. Actual leak diagnosis needs deeper memory
inspection than footprint history provides.

Keep a separate fast-runaway guard. A process consuming several GiB rapidly
should not have to pass a 20-minute leak test before the user hears about it.
Its message should state the measured growth and resource risk, without claiming
that unreachable allocations caused it.

### Other Rules

Keep prompt critical-pressure protection, but verify fresh input and distinguish
current severity from the original event. CPU/GPU activity alone should remain
an opt-in workload alert, not a default claim that the Mac is unhealthy. Require
continuous observations across their sustain windows. Thermal warnings should
use the OS state and fresh continuity, with cautious attribution.

Retain explicit process-memory budgets as an advanced option. Crossing a limit
the user deliberately set is a different contract from detecting a leak.

### Make Each Notice Explain Its Evidence

Show the start and current values, elapsed time, reason for urgency, and whether
the issue is new or worse. Link to Explorer at the evidence window, with relevant
processes selected. Keep the original detection time and the last observed time.

Proposed copy, using a hypothetical sequence:

> Swap rose from 3.0 to 4.0 GiB in five minutes. Growth is continuing.

An escalation should say what changed since the earlier notice. A stable,
high-swap state with normal pressure and low paging should not produce this
message or remain red solely because of its size.

## Delivery Plan And Acceptance

1. Add a replay harness and a local incident ledger. Record evidence, rule
   version, state changes, suppression reasons, and delivery outcomes. Keep
   this bounded and local, separate from raw history logging.

2. Introduce fresh-data handling and the incident lifecycle. Preserve existing
   critical-pressure behavior during the change. Carry true swap counters to
   the decision layer. Let enabled rules request their required sampling.

3. Replace the swap crossing rule with growth and paging evidence. Add baseline,
   recovery, and escalation handling before tuning presentation.

4. Separate process growth from possible leaks. Add recent-window agreement,
   plateau handling, live-identity checks, and a fast-runaway guard. Maintain
   bounded in-memory trend evidence when disk recording is off.

5. Replay normal work, builds, model loads, sleep/wake, and deliberate stress.
   Run proposed rules in shadow mode before changing notification defaults.
   Measure incidents and banners per day, duplicates, missed worsening, and
   time to detection. Choose thresholds from those results, not one laptop.

Replay must stop at each simulated time. The existing `leakBoard(now:)` queries
have lower bounds but no upper bounds, so passing a past `now` over today's
database can use future rows. Use time-bounded inputs, not that shortcut.

Test stable 3 GiB and 30 GiB swap with no strain, and rapid 3-to-4 GiB growth.
Test further growth after an old alert and flat occupancy with active paging.
Also cover recovered-but-high baselines, pending cooldown notices,
process exits/PID reuse, warm-up/plateaus, cyclic memory release, missing samples,
query failures, restart, and logging disabled. Test both normal and urgent
notifications across multiple simultaneous processes.

## Scope And Verification

Production code, alert thresholds, user settings, and the installed app remain
unchanged. No notifications were sent by the probes. They exercised Core only,
using a temporary test database where needed. Existing history was read-only.
The audit ran 18 alert-engine tests, four leak-detector tests, four leak-board
tests, and four temporary characterization tests, all passing.

Local history confirms the five-minute cooldown was added to limit flapping
notifications in commit `6ebad88` on 8 August 2026. It was not an escalation
design. This audit proposes replacing that limitation, not removing protection
against repeated banners.