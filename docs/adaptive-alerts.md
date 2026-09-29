# Adaptive Alerts

Implemented on 10 September 2026, following the
[alerting audit](alerting-audit-2026-09-10.md).

Performance alerts track a spell of trouble, not a single high reading. Stable swap
usage alone does not trigger a warning. New notices show what grew, how fast,
and why it matters. They keep the time the issue began separate from the last
reading.

A healthy Mac can keep swap on disk after its work has ended. The goal is to
spot change and strain, not to make the swap total return to zero.

## What You See

The red badge counts active alerts. Open it to see the affected processes and
what changed. Modest growth appears under **Observations**, outside the red
count. An issue that is settling goes there too. So does a wait for fresh data.
Neither state sends a new banner.

Click an alert title to open Explorer at its evidence window. It selects the
relevant charts and processes. The inspector also keeps the captured alert
values. Those values remain useful when full history is off; missing chart
history stays missing. Click a process name to open its live details instead.

The bell button snoozes ordinary notices for one hour. The evidence stays in
view. A new critical risk can still alert you. Use the same button to resume
notices early. An unchanged incident does not send a reminder just because time
has passed.

## Swap Rules

The old **Swap above** number no longer decides when to alert. The app can still
read its saved value, but the new rule ignores it. Your on/off choices stay as
they were. Swap alerts are still off by default for a new user.

The detector keeps a short window of swap readings in memory. It checks growth
over five and fifteen minutes. The last two minutes must still show growth.
It rejects gaps and waits for enough fresh data.

The growth floor starts at the larger of 1 GiB and 3% of RAM. Normal variation
can raise it. The estimate uses four times the median absolute deviation of
recent changes below the floor. This limits the effect of an isolated spike.
The buffer holds at most 120 such changes.

An ordinary warning needs roughly one growth floor over five minutes, or two
over fifteen minutes. Positive fitted slope and recent growth must agree.
Shorter windows need at least 80% coverage; their size test uses the measured
duration. A qualifying trend must continue for another minute before a notice.

A fast-growth guard checks for at least the larger of 2 GiB and 10% of RAM
over about two minutes. It uses a shorter, 30-second confirmation. Such growth
can become critical before the kernel reports critical pressure.

A separate paging test catches strain even when swap size is flat. It needs
both swap-in and swap-out rates of at least 8 MiB/s, with elevated kernel
pressure, for two minutes. These are logical memory rates from kernel counters,
not exact physical SSD traffic after compression.

These figures are starting points, not proof of trouble on every Mac. Size,
rate, fresh data, and recovery work together. Raising one fixed byte limit was
not the solution.

## Process Growth

The alert monitor uses bounded live history, even with database recording off.
It retains up to an hour per process, in 30-second buckets, for at most 4,096
processes. Processes outside that cap have unknown coverage, not known recovery.

Slow-growth evidence needs at least 20 minutes, enough samples, no long gaps,
and recent growth. The shared detector keeps its 8 KiB/s slope and 32 MiB floor,
but also needs at least 5% growth relative to the starting footprint. A plateau
fails the recent-growth test. Rising low-water marks can qualify through cyclic
allocations and releases.

Small findings stay as observations. An ordinary growth warning needs at least
the larger of 512 MiB and 3% of RAM, plus a further minute of confirmation.
A separate fast guard catches at least the larger of 1 GiB and 8% of RAM in
about two minutes, with 30 seconds of confirmation. It does not wait through
the slow detector's 20-minute window.

These findings show **memory growth**, not proof of a leak. A process may still
need that memory or free it later. Insights and process badges no longer show
a percentage chance of a leak. They show the growth and time span. Fit scores
stay internal. A memory budget you set for a process remains a separate rule.

## Incidents And Notices

Each incident has a stable identity, current evidence, and a phase. The phases
are watching, active, recovering, resolved, and unknown. Normal means there is
no current incident. Process identities include the full start time as well as
the PID, so reuse does not merge distinct lifetimes.

A notice can fire when you first need to act, or when the risk gets much worse.
It compares against the last notice's values, not the prior tick.
Swap ordinarily needs two more growth floors, or half that increase with a
doubling of growth rate. A new paging-strain signal or critical severity upgrade
can also justify another notice. Escalation copy includes the previous reading.

The five-minute cooldown remains, but now delays a pending notice instead of
discarding it forever. Ordinary notification batches are at least one minute
apart. Critical upgrades can bypass that budget. Related memory alerts that
are eligible together share one notification, without claiming a common cause.

Swap has five minutes to settle; process growth has three minutes.
During that period the item appears in Observations. This prevents a short dip
from creating a new episode. High swap can settle, while an
independent critical-pressure alert stays active if needed.

Only critical notices request sound. A failed scheduling attempt can retry
after cooldown. Successful scheduling means macOS accepted the request, not
proof that the user saw a banner. System notification permissions still apply.

## Fresh Data And Settings

Critical kernel pressure remains prompt. CPU, GPU, and thermal rules need
distinct, fresh observations over their sustain windows. Their timers restart
after a long sampling gap. A missing read is unknown, not a zero or recovery.
Stale asynchronous evaluations cannot replace newer incident evidence.

Alert checks run independently of the display refresh setting. An enabled GPU
rule requests GPU sampling. Process alerts get a scan at least once a minute
when nothing else needs one. No extra kernel call is needed for swap counters;
the memory reader already collected them.

**Observe growth without notifications** is a quiet-evaluation option in
Settings. It keeps swap and process-growth findings in Observations. It leaves
the user's critical-pressure, CPU/GPU, thermal, and explicit-budget choices
unchanged. The option is off by default.

## Accessory Batteries

**Low accessory battery** is an opt-in under Settings > Alerts, off by default.
The starting level is 20%. You can choose 5% to 50% in steps of 5%.
These quiet battery notices are separate from the performance incidents in
the red alert badge. Clicking a battery notice opens Energy.

The reader checks at most once a minute while the app is running. With alerts
off, it runs only while Energy is visible. With alerts on, it also runs when
Energy is hidden. Both uses share one reader and the same time limit. Tab
changes, waking the Mac, and failed reads cannot trigger faster checks.

A warning needs two valid low reports, at least a minute apart, for the same
battery part. A failed read, missing device, or long pause starts that check
again. Unknown levels, known charging parts, and devices reported as
disconnected do not trigger a warning. Devices without a stable identifier
can still appear in the card, but cannot send notices.

Low parts of one device share one notice. The app saves that device's alert
state in local preferences so it stays quiet across app restarts. It allows
another notice only after the reported parts recover at least five percentage
points above the warning level. Missing parts, failed reads, and disconnects
do not count as recovery. Failed notification scheduling can retry after
another pair of low reports. System notification permissions still apply.

macOS may return cached levels without a measurement time. A repeated report
is not proof of a fresh device measurement. Notices say what macOS reports;
they do not claim a measured runtime or remaining battery life. The card's
checked time is when the app read the report, not when the device measured it.

## Local Evidence

The app keeps incident state even when full history is off. It stores two files
in the `alerts` directory inside its Application Support folder:

- `incidents.json` holds up to 512 incidents and 256 state or policy decisions.

- `deliveries.json` holds up to 128 scheduling outcomes.

Entries expire after seven days without a reading. Each file has a 2 MiB limit.
Only your account has access to the directory and files. Writes are atomic and
run off the main thread. The app saves each state change. It also saves about
every 30 seconds while evidence is active. A crash can lose the last unsaved
state.

The checkpoint keeps the last notification baseline across app restarts. Fresh
trend windows still need to fill before growth decisions resume. Records include
rule version, suppression reasons, evidence times, and process identity. They
stay local and disappear with the app's data during a full uninstall.

Migration `v18-swap-activity` adds nullable paging rates, deltas, page size,
elapsed time, and validity flags to raw system rows. Minute and hour rows keep
coverage-weighted rates, maxima, and observed seconds. Old data stays unknown;
there is no invented backfill. Explorer's stored-row inspector exposes the new
fields. Occupancy charts remain distinct from paging rates.

## Verification

Tests cover stable 3/30 GiB swap, continued growth after a notice, pending
cooldowns, escalation, snoozes, restart state, failed delivery, and quiet mode.
Process cases cover plateaus, modest growth, cyclic releases, gaps, stale
history, PID reuse, rapid runaway use, and tracking-cap churn.

The read-only replay on 10 September used 2,806 retained minute means from this
Mac. It produced 16 candidate swap notices, including a new notice and an
escalation during the audited burst on 9 September. It produced none during the
settled overnight period checked in the audit. The replay sent no notifications.

That replay covers net growth and stored pressure only. The old database has no
swap-in/out rates, so it cannot validate the new paging-strain rule. Minute means
also hide sub-minute changes. Synthetic rate tests cover the rule's mechanics;
longer live observation across workloads is still needed to tune its defaults.

A synthetic steady-workload test drove 700 processes through 81 updates. The
growth monitor took about 33 ms per 30-second update in a debug test run.
This measures that component, not the app's total runtime cost.

Run focused checks:

```sh
swift test --filter 'Alert.*Tests|AdaptiveAlertEngineTests|Swap.*Tests|ProcessGrowthMonitorTests|LeakDetectorTests|LeakBoardTests'
```

Check accessory battery rules, saved settings, and background polling:

```sh
swift test --filter 'AccessoryBattery.*Tests|AlertNotificationTests'
```

Replay retained history without writes or notifications:

```sh
MACPERF_ALERT_REPLAY_DATABASE="$HOME/Library/Application Support/MacPerformanceMonitor/macperfmonitor.sqlite" \
  swift test --filter AlertReplayTests/testRecordedSwapReplayReadOnlyWhenRequested
```

Render the native active, watching, unavailable, and snoozed states:

```sh
MACPERF_ALERT_ARTIFACTS="$PWD/build/alert-previews" swift test --filter AlertsMenuBarTests
```