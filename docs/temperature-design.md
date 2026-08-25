# Temperature monitoring: sources and surfacing design

Research notes from probing an M3 Pro (Mac15,6, macOS 26.6.2) with a standalone
tool that enumerated every readable temperature source. This doc records what is
available, what it costs to read, a bug the probe uncovered in the shipping die
temperature code, and a recommendation for where temperatures belong in the app
and menu bar.

## Sources inventory (all verified sudoless on macOS 26)

### 1. SMC keys (already shipping in `SMCReader`)

The AppleSMC user client exposes 2295 keys on this machine; 293 are readable
T* (temperature) or F* (fan) keys. Cost measured at ~119 us per key read with
key info cached, so a 40-key sweep is ~5 ms. Decoded map for the M3 Pro, by
prefix:

| Prefix | Meaning | Idle values seen |
|---|---|---|
| `Tp**` | P-core die sensors, per cluster (36 keys) | 38 to 53 C |
| `Te**` | E-core die sensors (13 keys) | 35 to 49 C |
| `Tg**` | GPU cluster die sensors (20 keys) | 34 to 41 C |
| `TB0T/TB1T/TB2T` | Battery (matches gas gauge readings) | 23.8 to 24.2 C |
| `TH0a/TH0b/TH0x` | SSD | ~27.7 C |
| `TaL*/TaR*` | Airflow left/right | 25 to 31 C |
| `Ts0P/Ts1P` | Skin/palm rest proximity | 22 to 23 C |
| `TW0P` | Wireless proximity | ~32 C |
| `TV**` | Voltage-rail/regulator sensors, NOT die | 0.01 to 59.1 C |
| `Ta0*` pairs | Calibration offsets (0.00 / -3.10), not real sensors | n/a |
| `Tz1*` | Unused zones, all 0 | n/a |
| `Tf**` | Mixed; includes offsets and two ~70 C outliers, treat as unknown | -4.5 to 75.5 C |

Fans: `FNum` reports 2 fans; `F0`/`F1` each expose actual RPM (`Ac`), target
(`Tg`), min (`Mn` = 2317), max (`Mx` = 6800), plus mode and state bytes. Both
fans were at 0 RPM at idle (fans-off is normal for M3 Pro under light load).
The shipping reader only reads fan 0.

Value types are `flt` (little-endian float) plus some `ioft` (64-bit fixed
point, divide by 65536); `ioft` shows up on `TG0*` and `TR*` keys and the
shipping decoder does not handle it yet.

### 2. HID temperature services (new, SPI)

`IOHIDEventSystemClient` matched on PrimaryUsagePage 0xff00 / PrimaryUsage 5
returns 46 services with human-readable names: `PMU tdie1..10` (SoC die),
`PMU tdev1..8` (board), `NAND CH0 temp` (SSD), `gas gauge battery` (x6), and
`PMU tcal` (calibration reference at ~52 C, not a display value). Most appear
twice (two PMU instances); dedupe by name.

Cost measured at ~974 us per read (a mach round trip to hidd per event), about
8x the SMC path. These are SPI symbols (`IOHIDEventSystemClientCreate` and
friends): fine for our Developer ID distribution (iStat Menus, Stats, and Hot
all ship it), not App Store safe, no root or entitlement needed.

Verdict: use SMC for the recurring sample loop (cheaper, one code path we
already ship). HID's value is naming and cross-checking; worth keeping in the
probe tool, not worth a second runtime dependency for the same numbers.

### 3. Thermal pressure (public API, free)

`ProcessInfo.processInfo.thermalState` (nominal/fair/serious/critical) plus the
`thermalStateDidChangeNotification`. Push-based, zero polling cost, public API.
This is the "is macOS actually throttling" signal that raw temperatures cannot
give, and we currently do not read it anywhere.

### 4. Already shipping elsewhere

Battery temperature (`BatterySample.temperatureCelsius`), NVMe SMART composite
temperature (Disk tab), and the GPU tab's die temperature and fan RPM from
`SMCReader`.

### 5. Not viable

`powermetrics` needs root. IOReport (which we already use for GPU P-states and
power) exposes no usable temperature channels. There is no public per-sensor
API.

### Root helper: not needed, deliberately

The probe read every sensor unprivileged (293 of 293 SMC T/F keys, all HID
services); Apple leaves SMC reads open. The only root-gated tool,
`powermetrics --samplers thermal`, reports just the pressure level on Apple
silicon, a strictly worse version of the free `ProcessInfo.thermalState`. The
one root-only capability nearby is SMC writes (fan control); that is a
different product, and adding an SMC-write selector to the helper would turn a
narrow read-mostly surface into a hardware-safety attack surface. Out of
scope, on purpose. Temperature joins the GPU tab in the "full coverage, no
helper needed" story.

## Bug found: the shipping die temperature is not the die

`SMCReader.discoverKeys()` accepts prefixes `Tp`/`Te`/`TV` and caps discovery
at 12 keys. SMC enumerates keys in sorted order, and uppercase sorts before
lowercase, so every `TV*` key is seen before any `Te*` or `Tp*` key. On the
M3 Pro, 12 `TV*` voltage-rail sensors pass the plausibility filter (10 to
110 C), so the cap fills entirely with them: the reported "die temperature" is
an average of voltage-rail sensors (including two ~59 C regulator readings and
an 18 C outlier), roughly 33 C at idle while the real die sensors read 38 to
53 C. It tracks load only incidentally. On earlier chips with fewer `TV*` keys
the average may have included real die sensors, which is why it looked sane.
Fix regardless of the rest of this doc: drop `TV` from the accepted prefixes,
raise the cap, and prefer max over average (users read "CPU temp" as "hottest
core", and max is what iStat and Stats report).

## Metric definitions (proposed)

- **CPU die**: max of `Tp*` and `Te*` after sanity filters (drop <=10 C,
  >=110 C). Keep the average as a secondary stat.
- **GPU die**: max of `Tg*` (`flt` keys only; the `TG0*` `ioft` keys are
  battery-adjacent readings, note the case). Replaces "GPU shares the die
  average" with the GPU's own sensors.
- **SSD**: max of `TH0*`, alongside the existing SMART composite.
- **Battery**: max of `TB0T/TB1T/TB2T` (agrees with the gas gauge, and we
  already surface battery temperature).
- **Fans**: per-fan actual/target/min/max for `FNum` fans, not just fan 0.
- **Thermal pressure**: the `ProcessInfo` state, observed push-based.

Discovery stays pattern-based (prefix plus sanity filter), never a hardcoded
per-chip key table: key names shift between M1/M2/M3/M4 generations but the
prefixes have held. Filters must reject the 0.00/-3.10 offset pairs and dead
zones. Validate on the M2 Pro before release.

## Cost budget

Sampling set of roughly 75 keys (36 Tp + 13 Te + 20 Tg + 3 TB + 3 TH plus both
fans) is ~9 ms per sweep at 119 us/key; at the existing 2 s throttle that is
~0.4% of one core, and a 5 s cadence drops it under 0.2%. Temperatures move
slowly; 5 s is plenty. Discovery is one enumeration, already the shipping
pattern. Thermal state is push. Net: no measurable budget impact.

## Where to surface it

In order of recommendation:

1. **Fix the GPU tab numbers first** (the `TV*` bug plus real `Tg*` GPU
   sensors and both fans). The tab already has the layout; the numbers become
   honest.
2. **Menu bar: a new Temperature metric** in the combined item
   (`MenuBarMetric.temperature`). Headline: CPU die max, colored by thermal
   pressure state (green nominal, orange serious, red critical), so color
   means "macOS is throttling", not an arbitrary degree threshold. Detail
   panel: CPU/GPU/SSD/battery rows with sparklines, per-fan RPM, and the
   current thermal pressure state. Temperature in the menu bar is the single
   most-requested reason people install iStat or Stats; this is the headline
   feature of the work.
3. **Energy tab: a Thermals section.** Heat belongs with power. Die
   temperature history chart (CPU and GPU series), fan RPM history, and a
   thermal pressure event log. The Dashboard stays memory-first; do not add a
   temperature tile there.
4. **History**: persist a compact row at the logging cadence: CPU die max/avg,
   GPU max, SSD, battery, fan RPMs, thermal state. Enables "when did it start
   running hot" questions, which no competitor answers well. Two rules:
   downsampling must preserve max as well as avg (a plain average erases the
   spikes, which are the point), and granularity stays per-domain, not
   per-sensor (the within-domain spread is a couple of degrees; the per-sensor
   long tail is the Hardware tab's live view, not history).
5. **Insights/alerts**: log thermal pressure transitions like pressure events;
   quiet-by-default alert on sustained serious/critical (mirrors the sustained
   swap alert). A throttling event with the top CPU process attached is the
   actionable version of "my fans are loud".
6. **Hardware tab**: a Sensors group in the inventory tree listing every named
   sensor with its reading at Refresh time (on-demand fits that tab's model).
   This is where the long tail (airflow, skin, wireless) lives, keeping the
   headline surfaces to the six meaningful numbers.

## Phasing

1. **PR 1, correctness:** fix the `TV*` discovery bug in `SMCReader` (drop the
   `TV` prefix, raise the 12-key cap, report max alongside avg), read both
   fans, decode `ioft`. Makes the shipping GPU tab numbers honest.
2. **PR 2, the thermal pipeline:** a domain-based thermal reader (CPU/GPU/SSD/
   battery/fans/pressure state), `v14-thermal` migration with max-preserving
   downsample, and the Energy tab Thermals section (history charts plus the
   thermal pressure event log).
3. **PR 3, menu bar:** the Temperature metric in the combined item, colored by
   thermal pressure state, with the detail panel.
4. **Phase two:** system series in Analytics (Analytics today is per-process
   only, so this means teaching it a system-series concept, real scope), the
   sustained-throttling alert with top CPU process attached, and the
   fan-vs-temp drift observation ("fans work harder for the same temperature
   than N months ago", the dust signal).

## Open questions

- `Tf*` and `TCMb/TCMz` run hot (67 to 76 C at idle) and are undocumented;
  exclude until identified.
- M4/M5 prefix drift: the probe tool (scratchpad, `temp-probe/probe.swift`)
  should be run on new hardware as it arrives; consider promoting it to a
  `--probe-sensors` flag on macperfmonitor-cli so users can contribute dumps.
- Menu bar width: a temperature readout adds to an already configurable item;
  the existing metric picker handles opt-in, no new mechanism needed.
