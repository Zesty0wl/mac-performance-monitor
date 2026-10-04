# Pre-release resource review: 2026-10-03

A CPU, memory and disk review of 2.2.2 (build 276) before the 2.2.x release,
with the constraint that no user-visible behaviour changes. Measured on the
installed app after 3 days of uptime on an M3 Pro, with heavy logging settings:
1 s high-resolution logging kept for 6 h, a 1 s refresh, per-app network on,
the privileged helper installed and a 5 GB database cap. The defaults (10 s
logging, 2 h raw, 1 GB cap) write roughly a tenth as often, so the absolute
figures below are a worst case. The ratios carry over.

## What the app costs today

| Resource | Measured | How |
| --- | --- | --- |
| CPU | 7 to 9% of one core, window open | `proc_pid_rusage` over 60 s; its own `process_hour` rows |
| Memory | 320 to 370 MB footprint, swinging to ~470 MB every ~3 min | `footprint`, `heap`, `process_minute.footprint_max` |
| Disk writes | 2.6 MB/s, ~9.5 GB per hour, ~930 GB over 3 days | `ri_diskio_byteswritten`; `process_hour.disk_written_max` |
| Database | 3.28 GB (the cap is 5 GB) | `dbstat` |

The disk write rate is the outlier. Almost all of it is SQLite.

## Where the writes go

`walsim.py` (scratch tooling, described under Method) replays one real minute
of the app's database work against a snapshot of the production database and
counts the bytes each step appends to the WAL and the distinct pages a
checkpoint then copies into the main file:

| Step, per minute | WAL | Checkpoint | Share |
| --- | --- | --- | --- |
| Raw sample inserts (1 Hz commits, ~157 rows each) | 54.5 MB | 18.4 MB | 70% |
| Trim the oldest raw minute | 7.6 MB | 7.6 MB | 15% |
| Roll raw into `process_minute` | 4.3 MB | 4.2 MB | 8% |
| Trim the oldest minute bucket | 2.6 MB | 2.6 MB | 5% |
| `touchLastSeen` | 0.9 MB | 0.9 MB | 2% |
| `incremental_vacuum(2000)` | 0.9 MB | 0.8 MB | under 1% |

Measured WAL growth on the live app was 0.95 MB/s, which matches the 54.5 MB
per minute of the replay. Each raw row costs about 2.6 pages per commit because
`process_samples` keeps two b-trees keyed on `(process_id, timestamp)` (the
primary-key autoindex and the covering consumer index), so every changed
process dirties a leaf in each, and WAL mode rewrites every dirty page on every
commit.

`alerts/incidents.json` (370 KB) is rewritten every 30 s while any incident
exists, about 45 MB an hour. Small next to SQLite.

## Changed in this pass

All four keep behaviour identical. The full test suite passes (841 Core tests).

1. **WAL checkpoint every 60 s instead of 15 s** (`SamplerModel`). A checkpoint
   copies each touched page once, and at 1 s logging the same leaves are dirtied
   every second, so the longer interval deduplicates more. Replay: checkpoint
   writes 24.6 to 13.3 MB per minute, about 10% of all writes, at the cost of a
   WAL that peaks near 55 MB at 1 s logging (about 14 MB before).
2. **Leak scan** (`SampleStore.leakBoard`, every 3 min plus on demand). It
   fetched ~80k minute rows and ~30k raw buckets with `Row.fetchAll`, each row
   carrying the process name and path. It also copied each process's series
   out of the dictionary and back for every append, which made each append
   copy the whole array. Now: a cursor, in-place appends, `ORDER BY t.bucket`
   (index order, no sort) on the minute tier, and grouping the raw samples
   before joining `processes`. Result on the snapshot (debug build): 520 to
   220 ms per scan, peak memory 48 to 27 MB. Old and new SQL produce identical
   per-process series at 7 points in time across 3 h of the snapshot.
3. **Alert incident views** (`AlertIncidentTracker`). `active`, `observations`
   and `reconcile` sorted all ~340 stored incidents (nearly all resolved) and
   then filtered them, several times per alert evaluation. They now filter
   first. Ids are unique, so the order is identical; checked against the live
   `incidents.json`. 7.3 to 0.1 ms per `active` + `observations` pair (debug).
   In the profile this was most of `evaluateAlerts`, about 2% CPU.
4. **System history cache eviction** (`SamplerModel`). The 2.5 s TTL caches for
   `systemHistory` and `recentSystemHistory` never served a stale entry, but
   they kept it until the same key was read again, which after the window
   closes is never. On this database each range's array is about 1.8 MB (the
   heap held ten such arrays, 17.6 MB, with the window open). A sweep now drops expired entries one TTL
   after a store.

## Recommended next, not done for this release

These need a schema migration or touch query plans across many call sites, so
they are not for a Sunday release.

1. **`process_samples` as `WITHOUT ROWID`** keyed on `(process_id, timestamp)`,
   dropping the then-redundant consumer index. Replay: raw-insert WAL down 35%,
   all writes down 30% (1754 to 1229 KB/s), raw tier 310 to 196 MB, and insert
   CPU halved. The rebuild took 11 s for 1.44M rows. Retention's
   `rowid IN (...)` deletes and the size cap must switch to the key for this
   table. The raw consumer queries would then scan the table, not a narrower
   index.
2. **Group commits** (one transaction every ~5 s of samples): raw-insert WAL
   54.5 to 30.2 MB per minute in the replay. This delays rows reaching the
   database, so the process inspector (which reads new DB rows each second)
   would need an in-memory overlay to keep its freshness.
3. **The process tiers' index set.** `process_minute` and `process_hour` are
   2.15 GB of the 3.28 GB file, and their indexes are larger than their tables.
   `idx_process_minute_bucket` and `idx_process_hour_bucket` (211 MB) duplicate
   the leading column of the v9 consumer indexes. A `WITHOUT ROWID` table keyed
   on `(bucket, process_id)` with a slim `(process_id, bucket)` index would
   cover both access patterns at an estimated 60% of today's size. Dropping only the
   two bucket indexes is cheap (0.4 s) but changes some plans (one rollup moved
   to the consumer index, 28 to 45 ms), so it needs the same plan audit of the
   Ask, Agent, Group, Explorer, ProcessHistory and UsageTimeline queries.
4. **`processes` table**: 3.2M rows and 654 MB with its indexes, 81% of them
   processes that lived under a minute (`mdworker_shared` 890k). About 300 MB
   of it is repeated `executable_path` text that a path lookup table would
   store once. The app's own `nettop` children account for 355k of the rows:
   per-app network spawns `nettop -L 1` every ~15 s (about 5,500 a day). One
   long-lived `nettop -L 0 -s N` would end the spawns and those rows.
5. **`rawConsumers`** joins `processes` once per raw row before grouping.
   Grouping first then joining measured 0.45 to 0.31 s per call on a 1 h window,
   but the top-N order among tied values can differ, so it needs a tiebreaker
   to stay stable.
6. **Incident snapshot**: write `incidents.json` only when the revision changes.
   The 30 s heartbeat rewrite should not be needed for the save to be correct.

## Method

- Live process: `proc_pid_rusage` deltas (CPU, wakeups, disk bytes), `footprint`,
  `heap -sortBySize`, `sample` (15 s, aggregated by inclusive busy samples per
  frame), and WAL size polled each second.
- Database snapshot: `sqlite3 'file:...?mode=ro' "VACUUM INTO ..."` (an online
  `.backup` never completes against a database written every second), then APFS
  clones (`cp -c`) per experiment.
- The replay script re-inserts the snapshot's last minute of raw rows shifted
  forward, runs the rollup, trims, `touchLastSeen`, vacuum and `PRAGMA optimize`
  as `Retention.run` does, truncating the WAL between steps and parsing WAL
  frame headers for distinct pages.
- Leak scan, alert and SQL-equivalence checks ran as temporary XCTest cases
  against the snapshot and the live `incidents.json`, not committed.

## Second pass: CPU, memory, page switching and launch (2026-10-04)

Measured on the live app with the main window open on a 1745 x 1300 window,
by driving the tab strip through Accessibility: each switch records how long
the main thread stays busy (time until the app answers an Accessibility query
again) and the process CPU in the next 2 s, then the app idles on Groups for
10 s after every tab has been visited. `sample` profiles located the costs.

| Measure | Before (277) | After |
| --- | --- | --- |
| Main-thread busy, idle on Groups after visiting every tab | 1,929 samples / 10 s | 294 (-85%) |
| Footprint, same state | 716 MB | 393 to 491 MB |
| Peak footprint while cycling tabs | 776 MB | 554 MB |
| Mean CPU per tab switch (first 2 s) | 742 ms | 575 ms |
| Median main-thread block per switch | 197 ms | 173 ms |
| Launch to first sample, 60 MB WAL left over | 2.8 s | 1.8 s |

1. **Hidden tabs stayed mounted** (`ContentView.TabGate`). On macOS 26 and
   later `TabView` stops applying updates to a tab once it is hidden, so the tab
   being left never received `isActive == false`: its page kept observing the
   model, feeding its charts and re-evaluating its body every sample until the
   window closed. Every visited tab added its cost (the Processes table, the
   Insights body and the Dashboard stores were all running while Groups showed).
   Reproduced in a minimal SwiftUI app: the gate's body is evaluated with
   `false` but never applied. `onDisappear` is still delivered and its state
   change is applied, so the gate now also hides its content there, keyed by a
   selection generation so a re-selected tab mounts on its first frame.
   Revisiting a tab now rebuilds its page, as the gate always intended, so a
   few revisit switches cost slightly more than showing a page that never left
   (Processes 207 to 272 ms, Hardware 158 to 246 ms) while the others got
   faster (Dashboard 252 to 191, Explorer 260 to 226).
2. **Launch checkpoint** (`MacPerfMonitorDatabase.makePool`). The pool is never
   closed at quit, so the previous session's WAL is still there at launch, and
   the migration and agent view writes ran before `wal_autocheckpoint = 0`, so
   their first commit checkpointed the whole WAL synchronously on the main
   thread inside `AppDelegate.init` (~0.7 s; worse since the 60 s checkpoint
   made the WAL larger). Auto-checkpoint is now off before the first write; the
   sampler's regular checkpoint flushes the inherited WAL off the main thread.
3. **Explorer lane catalogue** (`ExplorerMetrics.all`) was rebuilt (25 lanes
   plus a process lane per metric, each with localized titles and notes) on
   every read, once per group per body evaluation of the source pane. Cached
   per language.
4. **`HardwareFlowLayout`** measured every block at an unspecified size in both
   `sizeThatFits` and `placeSubviews`, and SwiftUI calls `sizeThatFits` several
   times per pass. The sizes now live in the layout cache, which SwiftUI rebuilds
   when a subview's content changes size (verified in a minimal app).
5. **Process table icons** (`ProcessIconProvider.rowIcon`). Workspace icons are
   lazily rendered IconServices images, so each new row's `NSImageView` asked
   IconServices for a placeholder first, about a tenth of opening the Processes
   tab. Rows now get 16 pt bitmaps rendered once per executable; other icon
   uses are unchanged.

Not changed, for a later release:

- The Disk Map keeps its file tree (~145 MB on this Mac) while the window is
  open, so returning to the Disk tab is instant. Releasing it on tab switch
  would also reset the map's zoom and selection.
- Most of a page switch is SwiftUI laying out the new page. Keeping recently
  visited pages mounted but paused (not observing the model) would make
  revisits instant without the background cost, but needs each page's feeds
  to support pausing.
- Launch time left is framework start-up (dyld, SwiftUI building the main
  menu), plus opening the database on the main thread.
