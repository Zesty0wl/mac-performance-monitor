# The MacPerfMonitor memory taxonomy

MacPerfMonitor exists to fix a specific confusion: people open Activity Monitor, see
that almost all their RAM is "used", and panic, when in reality a large slice
is reclaimable cache that macOS is using to make things faster. This document
defines the categories MacPerfMonitor shows, the exact formulas used to derive them
from the public kernel counters, and the tolerance against Activity Monitor.

All categories are derived from `vm_statistics64` (via `host_statistics64`),
`sysctl`, and the swap usage struct (`vm.swapusage`). The page size is read once
from `host_page_size` (16 KB on Apple Silicon, 4 KB on Intel).

## The raw counters

`vm_statistics64` reports page *counts*; MacPerfMonitor multiplies each by the page
size to get bytes. The counters MacPerfMonitor reads:

| Counter | Meaning |
| --- | --- |
| `wire_count` | Pages that cannot be paged out (kernel, drivers, some app allocations). |
| `active_count` | Pages currently mapped and recently used. |
| `inactive_count` | Pages mapped but not recently used (reclaimable under pressure). |
| `speculative_count` | Pages read ahead speculatively. |
| `compressor_page_count` | Pages currently held by the memory compressor. |
| `internal_page_count` | Anonymous (non file-backed) pages, app allocations. |
| `external_page_count` | File-backed pages, the cache. |
| `purgeable_count` | Pages the system may discard on demand. |
| `free_count` | Genuinely unused pages. |

## The five user-facing categories

MacPerfMonitor groups the raw counters into the same buckets Activity Monitor uses,
because matching the tool people already know reduces confusion rather than
adding a sixth mental model.

### Wired

> Memory that can't be moved or compressed. The system needs it where it is.

```
wired = wire_count * pageSize
```

### Compressed

> Memory the compressor has squeezed to fit more in RAM. A little is normal;
> a lot, and rising, is an early sign of pressure.

```
compressed = compressor_page_count * pageSize
```

### App Memory

> Memory apps are actively using that isn't a reclaimable file cache.

Approximated as anonymous memory minus the part that is purgeable:

```
appMemory = max(internal_page_count - purgeable_count, 0) * pageSize
```

This mirrors Activity Monitor's "App Memory", which is dominated by anonymous
(internal) allocations and excludes purgeable scratch memory the system can drop.

### Cached Files

> macOS is using otherwise-free RAM to keep recently used files handy. **This
> is not a problem.** It is released the moment anything needs the space.

```
cachedFiles = (external_page_count + purgeable_count) * pageSize
```

This is the category users wrongly panic about. MacPerfMonitor always labels it as
reclaimable and benign and never counts it as "pressure".

### Swap Used

> Data the system has moved out to disk because RAM filled up. Distinct from
> compression. Rising swap under sustained pressure is the real warning sign.

```
swapUsed = vm.swapusage.xsu_used
```

Swap lives on disk, **not** in RAM, so it is shown as its own trend and is **not**
part of the stacked bar that sums to total RAM.

## The stacked bar: summing to total RAM

The dashboard's taxonomy bar shows the split across physical RAM and must sum to
`total_ram` exactly so the visual is honest. MacPerfMonitor builds it from four
measured categories plus a derived remainder:

```
measured = wired + appMemory + compressed + cachedFiles
free     = max(total_ram - measured, 0)     // labelled "Free & available"
bar      = [wired, appMemory, compressed, cachedFiles, free]   // sums to total_ram
```

In the normal case (`measured <= total_ram`) the five slices sum to exactly
`total_ram`, with `free` absorbing the difference. In the rare case where the
public counters overlap enough that `measured > total_ram`, the four measured
slices are scaled proportionally to fill `total_ram` and `free` is zero, so the
bar still sums to exactly `total_ram`. This guarantee is covered by a unit test
(`TaxonomyBreakdownTests`).

## Memory usage: the menu bar's RAM read-out

The RAM read-out shows how much memory is in use as a share of installed RAM:

```
compressorStored   = total_uncompressed_pages_in_compressor * pageSize
memoryUsage        = appMemory + wired + compressorStored
memoryUsagePercent = memoryUsage / total_ram * 100
```

`compressorStored` is the original size of everything the compressor holds,
including the pages it has moved out to swap (`swapped_count` counts those, as
a subset). While everything fits in RAM, the figure reads close to Activity
Monitor's Memory Used (`appMemory + wired + compressed`), which counts
compressed memory at the size it takes up instead; the gap is what compression
saved.

Unlike Memory Used, it is not capped by installed RAM. Above 100 percent, apps
need more memory than the Mac has, and the excess is what macOS keeps
compressed or in swap. Cached files stay out because macOS frees them on
demand.

It measures load, not strain. Compression is cheap on Apple silicon, so a Mac
can sit above 100 percent and stay responsive. The panel colours the figure by
the kernel's pressure level, and the [pressure index](pressure-index.md) stays
the measure of strain on the Dashboard, in Explorer and in the alerts.
Settings > Menu Bar & Dock can put the index back in the menu bar.

`compressorStored` is read live and is not part of the recorded history, so
samples read back from it fall back to `compressed`. The arithmetic is
unit-tested in `MemoryUsageTests`.

## Tolerance against Activity Monitor

MacPerfMonitor and Activity Monitor read the same kernel counters, so the categories
track closely, but they are **approximations** for two unavoidable reasons:

1. Apple does not publish the exact private formula Activity Monitor uses; the
   grouping here is reconstructed from the public counters.
2. The counters are sampled at slightly different instants, so a busy system
   moves pages between samples.

Observed agreement on a steady system is within a few percent of total RAM per
category. MacPerfMonitor treats **±5% of total RAM per category** as the documented
tolerance. The honest "Free & available" remainder means the *total* always
reconciles even when an individual category drifts within that band.

## Why not show every raw counter?

Because the goal is comprehension, not completeness. The raw counters are
available in the process/history views for power users; the dashboard taxonomy
deliberately uses the five-bucket model people already have from Activity
Monitor, with plain-language labels and hover explanations.
