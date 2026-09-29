# Energy Cards

Each Energy card answers a different question. Click any of the six cards to
open its chart, read values on hover, and see what the figure means. The main
number is current; the chart covers the range shown on the card. Missing data
stays unknown, not zero.

## Cards And Ranges

- **Charge** shows charge now, its history, and use since unplugging.
- **Estimated runtime** shows time until empty or full, past estimates, and a
	separate forecast.
- **Mac power draw** shows whole-Mac draw and signed battery flow.
- **Battery temperature** shows pack temperature, its history, and power states.
- **Health** shows charge held versus design, daily history, and a 90-day change.
- **Cycles** shows total cycles, a step chart, and monthly increases.

The first four cards follow the page's time range. Their pop-outs can select
another range without changing the page. Charge and runtime can also show the
current battery session, but only when the app saw the switch from adapter to
battery power.

Health starts at 90 days; Cycles starts at one year. Both offer 30 days, 90 days,
six months, one year, and all saved history. These ranges are separate from
the page's picker. A change needs readings near both ends of the period. A
missing month does not mean zero cycles.

Desktop Macs show Mac power draw and the accessory panel. They do not show
invented charge or runtime values.

## Readings And Forecasts

Mac power draw comes from the system sensor. Battery flow is voltage times
current. A positive value charges the pack; a negative value drains it. An
adapter's rated wattage is not the Mac's actual draw.

Runtime uses the macOS estimate first. If none is available, the fallback
needs at least three minutes of steady discharge within the last five minutes.
It divides the mAh left by the mean draw in mA, then converts hours to minutes.
Each reading's weight is the time it covers. The window holds at most 128
readings.

The fallback resets on charge, adapter power, a new pack, or a gap over 30
seconds. Low or uneven draw gives no estimate. Values beyond seven days also
stay unknown. Full-charge runtime assumes the same rate of use. A change in
work can change both estimates.

The app saves estimates as they arrive. It never recalculates old estimates
using today's load. A dashed line shows the charge forecast, separate from
the recorded points. It does not go into the database as real charge data.
Health and cycles never give a predicted failure date.

## Stored Data

The reader still checks the battery every five seconds. The new cards add no
hardware polling loop. They use the existing queues for reads and writes.

Migration `v19-battery-lifetime` adds one row per pack per UTC day. It keeps
health, cycles, and full/design capacity in the existing database. A hash of
the pack serial keeps a new pack separate from the old one. The table does
not store the serial itself. If the pack has no usable ID, there is no daily
record. The app does not guess which pack owns older rows.

Daily rows have no 90-day cutoff. They still count toward the database size
cap, which trims finer data first. A full uninstall removes the database,
including these rows. Turning recording off stops all new history writes.
The cards can still show live readings while recording is off.

Migration `v20-energy-history` adds Energy fields to the raw, minute, and hour
tables. Each metric keeps its known mean, range, and count. A bucket that
contains two packs does not mix their battery values. A bucket that spans
charging and discharging does not mix their runtime estimates.

Valid old charge and temperature readings stay visible. Old runtime and Mac
power readings cannot be recovered if the app did not store them. Lost limits
and unknown pack IDs stay missing. Wear history grows from the day recording
starts; the app does not fill in a past year.

## Tests

Core tests cover daily writes, new packs, retention, older data, rollups, missing
readings, and runtime maths. Native tests open all six cards, check units and
ranges, and close the pop-outs with Done.

```sh
swift test --filter 'BatteryTests|EnergyChartHoverTests|MetricCardPresentationTests'
MACPERF_ENERGY_ARTIFACTS="$PWD/build/energy-previews" swift test --filter EnergyChartHoverTests
```

The estimates still need checks under real workloads. The tests use more than
a year of synthetic daily data, not a year-long live test. They use temporary
databases and do not change the installed app's data.