# Background history crash

## Evidence

Version 2.0.0, build 223 crashed at 04:01:53 BST on 7 September 2026.
The final saved system sample was from 04:01:51. The main UI thread was idle.

The faulting sampler thread was filtering a Swift dictionary in
`SampleStore.pruneProcessIDCache(keeping:)`. At the same time, the GRDB writer
was inside `SampleStore.insertChanged`. The report recorded an invalid memory
access, `EXC_BAD_ACCESS / SIGSEGV`.

Inserts read and update two caches inside GRDB writer closures:

- `processIDCache` maps process identities to stored row IDs.
- `lastWritten` holds the last sample used by the change gate.

Maintenance pruned or cleared those dictionaries on its caller's queue.
`touchLastSeen` also read the ID cache before entering the writer.
After a failed write, cache cleanup ran on the caller's queue too.
None of these accesses shared the writer's protection.

## Fix

The database writer now owns every cache read and mutation. Public store
methods acquire that access internally. Call them outside an existing pool
access, as with the insert methods.

Pruning and clearing use `pool.writeWithoutTransaction`. They need queue access,
not a SQL transaction. The `touchLastSeen` lookup now runs inside the same
`pool.write` closure as its SQL update.

The write wrapper enters the writer once, then calls `db.inTransaction`.
Its error handler runs there too. If a statement or commit fails, both caches
are cleared before the writer can start another operation. This preserves the
existing rollback behavior without racing the next insert.

The patch adds no lock or extra queue. Public method signatures, change-gating
rules, stored data, and chart rendering stay unchanged. It needs no migration
or history rewrite.

## Regression checks

The initial test held the database writer busy and called pruning from another
queue. Before the fix, pruning finished while the writer was still held.
After the fix, it waits for the writer. Clearing and the `last_seen` lookup
have matching tests, including lookup while the cache is empty.

Other tests cover live-entry retention, deleted row IDs, commit-time failure,
exact retries, concurrent writers and maintenance, and rollback during another
thread's writes. They check stored row counts and foreign keys. The concurrent
maintenance test also runs SQLite's integrity check. All tests use temporary
databases, never the installed app's history.

Run the focused checks:

```sh
swift test --filter 'SampleStoreConcurrencyTests|ChangeGatedWritesTests|PersistenceTests'
TSAN_OPTIONS=halt_on_error=1 swift test --scratch-path .build/thread-sanitizer --sanitize thread --filter 'SampleStoreConcurrencyTests|ChangeGatedWritesTests'
```

The eight new cache tests and eight change-gating tests pass under Thread
Sanitizer with no reported data races. This checks the faulty access pattern;
it is not a claim that every possible overnight failure has been ruled out.