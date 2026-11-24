# The MacPerfMonitor pressure index

Memory pressure is MacPerfMonitor's North Star metric: the single number that answers
"is my Mac actually struggling?". macOS exposes pressure as a discrete
three-state signal (`kern.memorystatus_vm_pressure_level`: normal / warning /
critical). That is correct but jumpy: a chart of three values steps between
flat lines and hides the *trend* that tells you trouble is building.

The pressure index is a continuous **0–100** value derived from that discrete
level, blended with the compression and swap signals so the timeline glides and
the slope is meaningful. The formula is reproduced in code comments at the call
site (`PressureIndex.compute`) so it is auditable, and, being open source, it
will be audited.

## The discrete level is authoritative

The kernel's level is the ground truth for *which band* we are in. Each level
owns a third of the scale:

| Level | Band |
| --- | --- |
| normal | 0 – 33 |
| warning | 34 – 66 |
| critical | 67 – 100 |

```
levelFloor(normal)   = 0
levelFloor(warning)  = 34
levelFloor(critical) = 67
bandSpan             = 33
```

The continuous signals only decide *where inside the band* the index sits. The
index can never, for example, read "calm" while the kernel says critical.

## The continuous signals position within the band

Three normalised 0–1 signals capture how loaded and how fast-moving memory is:

### Compression signal

Half of RAM sitting in the compressor is treated as a fully loaded band
contribution:

```
compressionSignal = min( (compressed / total_ram) / 0.5, 1 )
```

### Swap signal

Swap equal to total RAM is treated as fully loaded:

```
swapSignal = min( swap_used / total_ram, 1 )
```

### Trend signal

How fast `compressed + swap_used` is *growing*, supplied by the sampler from its
inter-tick state. Growth of 50 MB/s is treated as a full trend contribution:

```
load        = compressed + swap_used
growthRate  = max(load - previousLoad, 0) / secondsSinceLastTick
trendSignal = clamp( growthRate / 50_000_000, 0, 1 )
```

The trend term is what makes the index *lead* rather than lag: a sharp climb
nudges the index up within the current band before the kernel flips to the next
level.

## Combining

```
signal = clamp( 0.5 * compressionSignal
              + 0.3 * swapSignal
              + 0.2 * trendSignal, 0, 1 )

index  = levelFloor(level) + signal * bandSpan      // 0 ... 100
```

The weights reflect what each signal means for the user:

- **Compression (0.5)** is the earliest in-RAM symptom of pressure and the one
  most under the app's influence, so it dominates within-band position.
- **Swap (0.3)** is a more serious, disk-backed symptom but is partly captured
  by the kernel already promoting the level, so it is weighted second.
- **Trend (0.2)** is a leading indicator, not a state, so it nudges rather than
  dominates.

## Transition events

For exact, annotatable transitions, MacPerfMonitor also subscribes to
`DISPATCH_SOURCE_TYPE_MEMORYPRESSURE`. Those events mark the precise moment the
kernel changed level and are drawn as annotations on the hero timeline, so the
smooth index and the authoritative discrete transitions are both visible.

## Worked example

On a Mac with 18 GB RAM, kernel level = warning, 2 GB compressed, 1 GB swap, and
`compressed + swap` rising at 10 MB/s:

```
compressionSignal = min((2/18)/0.5, 1)  = min(0.222, 1) = 0.222
swapSignal        = min(1/18, 1)        = 0.056
trendSignal       = clamp(10e6/50e6,0,1)= 0.2
signal            = 0.5*0.222 + 0.3*0.056 + 0.2*0.2 = 0.168
index             = 34 + 0.168*33       ≈ 39.5
```

So the timeline reads ~40, clearly in the lower part of the "warning" band,
consistent with the kernel's level but with a visible slope as compression
climbs. The exact arithmetic is unit-tested in `PressureIndexTests`.

## Where the index is shown

The Dashboard, Explorer and the alerts use the index. The menu bar's RAM
read-out shows memory usage by default instead (see
[memory usage](memory-taxonomy.md#memory-usage-the-menu-bars-ram-read-out)):
on a Mac with plenty of RAM, the index stays at 0 until macOS compresses or
swaps heavily, however much RAM is in use. Memory read-out in Settings > Menu
Bar & Dock puts the index back in the menu bar.
