# Disk Map design notes

The Disk Map is the Disk tab's second page: a scan of a volume or folder,
kept as a compact in-memory tree, drawn as a zoomable treemap and sliced into
Largest / Oldest / Kinds / Reclaim views, with Reveal in Finder, Quick Look and
Move to Trash on every item. This document records the facts and decisions
the implementation rests on so they are not rediscovered the hard way.

## What the numbers mean

- Every size is **allocated bytes** (`ATTR_FILE_ALLOCSIZE`, `st_blocks * 512`),
  never logical length. Sparse and transparently compressed files count what
  they occupy. This is the only figure that reconciles against the volume's
  used space and it is what `du` reports.
- **Hard links** are counted once, on first encounter, by file ID when the link
  count is above one. Later encounters are zero-byte nodes flagged
  `hardLinkDuplicate`.
- **Clones and snapshot-held files** keep their full allocated size as the
  map's weight and are flagged from `EF_MAY_SHARE_BLOCKS`.
  `ATTR_CMNEXT_PRIVATESIZE` ("bytes that would be freed immediately if the
  file were deleted") is the exact figure, and the engine can fetch it for
  every entry and aggregate `allocated - private` up the tree as `shared`, but
  measured over the 2 M entries of a home folder that turned a 15 s scan into
  a 23 s one. It is therefore off by default (`--private-size` in the CLI)
  and the app asks for it lazily, one `getattrlist`, for the item the user has
  selected so "would free now" is still exact where it is read.
- **Dataless files** (evicted iCloud Drive and file-provider items,
  `SF_DATALESS`) contribute zero local bytes. Every scan thread sets
  `IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES` to off, so no scan can ever
  trigger a download; a dataless directory is never opened.
- **Symlinks** are never followed and count only their own (usually zero)
  allocation. Sockets, fifos and devices are zero-byte leaves.
- **Packages** (`.app`, `.framework`, `.photoslibrary`, project bundles) are
  scanned fully but flagged so the map treats them as leaves until drilled
  into, and the Kinds view attributes their contents to the package.

## Where a scan stops

The startup disk is an APFS volume group. The sealed System volume mounts at
`/`, the writable Data volume at `/System/Volumes/Data`, and the firmlink
table in `/usr/share/firmlinks` grafts `/Users`, `/Applications`, `/Library`
and others from Data onto the root. The scanner walks the Data volume so the
total is one volume's `ATTR_VOL_SPACEUSED`, and `FirmlinkMap` canonicalises
paths for display and for Finder.

**A device-id check cannot find the boundary.** On this Mac `stat -f %d`
returns 16777229 for `/`, `/System`, `/System/Volumes/Data` and `/Users`
alike; only Preboot, VM and the simulator cryptex volumes differ. The signal is
`ATTR_DIR_MOUNTSTATUS`: a directory carrying `DIR_MNTSTATUS_MNTPOINT` or
`DIR_MNTSTATUS_TRIGGER` (autofs) is recorded as a `separateVolume` node with
zero bytes and never opened. The `readdir` fallback lister compares `st_dev`
with the parent, which is correct on the non-APFS volumes it exists for.

`/` and `/System` are refused as folder scopes and redirected to the startup
disk; scanning `/` would traverse both volumes of the group with no boundary
and no volume figure to reconcile against.

## How a scan runs

- Enumeration is `getattrlistbulk(2)` with a 128 KiB buffer and one open
  directory descriptor per worker at a time: name, object type, modification
  time, BSD flags, file ID, mount status, link count, allocated size, extended
  flags and private size in one record per entry, no per-entry `lstat`. The
  record is walked by its returned-attributes bitmap (`ATTR_CMN_ERROR` sits
  right after it when set), with unaligned loads for 8-byte values. `ENOTSUP`
  on the root switches the whole scan to a `readdir` + `fstatat` lister.
- Paths past `PATH_MAX` (deep `node_modules` trees) are opened through an
  `openat` chain that holds one descriptor at a time.
- Workers are `Foundation.Thread`s, not tasks, because the IO policies are per
  thread and a cooperative-pool thread is shared with the sampler. Each worker
  sets dataless materialisation off, access-time updates off and disk IO to
  utility class, then pulls directories from a LIFO stack (depth first keeps
  the frontier small) and posts listings into a bounded inbox. One coordinator
  thread owns the tree, merges listings, dedupes hard links, folds small files
  and pushes subdirectories. Cancellation finalises what was read into a
  partial snapshot.
- The tree is a struct-of-arrays arena with `Int32` indices and one UTF-8 name
  buffer, about 80 bytes per node. Files below an adaptive threshold (0 on a
  small volume, 16 KiB on a typical one, 64 KiB above 3.5 M inodes) fold into
  one synthetic child per kind when a directory has more than 24 of them, so
  totals stay exact while a 3 M-inode volume stays well under 1 M nodes.
- Every 500 ms the coordinator emits progress plus a pruned preview
  (directories to depth 3 above 0.1% of bytes so far) for progressive drawing;
  the full tree is published once at the end.

## The treemap

- Layout is the squarified treemap of Bruls, Huizing and van Wijk
  (`TreemapLayout.squarify`), run per directory by `TreemapScene.build`:
  children largest first, tiny ones folded into one "N more" cell, a
  directory subdivided only when its cell is at least 40 by 28 points, with
  a 16 point title strip when there is room, to a default depth of six
  levels. Because subdivision needs room, the cell count is bounded by the
  map's area rather than by depth (about 1 600 cells for a top-level view
  and 2 000 to 5 000 zoomed in), and the layout takes under a millisecond.
- Rendering is an AppKit `LiveSurfaceView` subclass painting into a
  `CALayer` with Core Graphics: per-mode `CGColor` palettes resolved once,
  label texts decided once per scene, labels drawn from a truncating
  `CTLine` cache. Hover and selection are two border-only layers moved over
  the map, so pointer movement never repaints anything. Measured with
  `--benchmark-charts --scenario diskMapPage --mode host` on a 1400 by 900
  map: a zoom (full relayout and repaint) costs about 39 ms of main-thread
  time end to end, of which paint is 11 to 15 ms; an idle map costs 0.1 ms
  per tick. `MPM_DISKMAP_TIMING=1` prints the scene and paint split.
- Colour modes: Kind (a categorical ramp per `FileKind`, folders in a
  cool grey), Age (five bands from under a month to over two years), Depth
  (one hue stepping darker per level). Light and dark variants differ.
- Interaction: single click selects (the rail follows), double-click or
  Return opens a folder, Escape or the breadcrumb goes back, arrows walk
  siblings, Space is Quick Look, right-click offers Open in Map, Reveal in
  Finder, Quick Look and Copy Path. Top-level cells are exposed as
  accessibility elements with their frames.
- Do not attach per-cell `NSView` tooltips: the tooltip owner is not
  retained, and a temporary `NSString` owner crashed in
  `NSToolTipManager displayToolTip:` when its timer fired. The hover card
  carries the same information.

## Errors, by cause

`EPERM` is privacy protection (TCC): Full Disk Access clears it, and only these
directories feed the "grant Full Disk Access" banner. The exception is a
**data vault** (`UF_DATAVAULT` on the directory, for example parts of
`~/Library/Biome` and `/private/var/db`): it returns `EPERM` to everyone
without an Apple entitlement, so it is counted separately and never blamed on
a missing grant. A full-disk scan on this Mac with FDA still met 57 of them.
`EACCES` is Unix permissions (`/.Spotlight-V100`, other users' folders) and no
grant changes it. `ENOENT` mid-scan is a vanished directory. `EDEADLK` is a
dataless directory. Per-entry errors from the bulk call keep the name and
become zero-byte `unreadable` leaves.

## Permissions

Full Disk Access is the only gate that matters. The privileged helper is not
used: root does not bypass TCC, and Move to Trash must run as the user for Put
Back to work. FDA takes effect only after the app relaunches, so the pre-scan
card offers Relaunch once the grant is detected as pending. Per-folder prompts
(Desktop, Documents, Downloads) are preflighted on one thread before workers
start so they appear one at a time and no worker blocks inside a system alert.

## Reconciliation

For the scanned volume: `used = scanned + unaccounted`, with unaccounted being
metadata, local snapshots and drift. Purgeable space is an overlay, not a
slice, because it overlaps files the scan counted as well as snapshot space it
did not. Shared blocks come from private sizes. If scanned exceeds used the
overshoot is shown as such. The volume is read after the scan so drift lands
in unaccounted; a move of more than 1% is called out. For the startup disk the
sibling volumes of the container (System, Preboot, VM, Update) are listed as
non-removable macOS buckets so the total matches Finder's "Macintosh HD".

## Verification

`swift test --filter DiskMap` covers the tree, the classifier, firmlinks, the
listers against a real temp tree (fields cross-checked with `lstat`, hard
links, sparse and cloned files, 5 000-entry directories, long and non-ASCII
names, paths past `PATH_MAX`, unreadable directories) and the scanner against
scripted listings and a real tree compared with an `lstat` walk.

`macperfmonitor-cli scan <path>` runs the engine headless with `--workers`,
`--threshold`, `--no-fold`, `--private-size`, `--no-throttle`, `--top` and
`--json`, printing throughput, peak RSS, descriptor count and the largest
directories and files. Compare its total with `du -skx`; the two agree on hard
links, sparse files and clones by construction.

Measured on an M3 Pro (11 cores, 18 GiB) in August 2026, release build, warm
cache:

| Run | Entries | Time | Rate | Nodes | Arena | Peak RSS |
|---|---|---|---|---|---|---|
| `~/Library/Developer`, no fold | 145 k | 1.9 s | 77 k/s | 145 k | 11 MB | 30 MB |
| Home, default (16 KiB fold) | 1.98 M | 15.1 s | 131 k/s | 1.24 M | 88 MB | 146 MB |
| Home, no fold | 1.98 M | 22.1 s | 90 k/s | 1.98 M | 144 MB | 224 MB |
| Home, with private size | 1.98 M | 23.3 s | 85 k/s | 1.24 M | 88 MB | 159 MB |

The `~/Library/Developer` total (28,388,921,344 bytes) matched `du -skx` to
the byte, in 2.0 s against du's 7.0 s. Descriptors stayed at 4 throughout.
Workers on that tree: 1 = 11.3 s, 2 = 4.4 s, 4 = 2.4 s, 6 = 1.9 s, 8 = 1.7 s.
