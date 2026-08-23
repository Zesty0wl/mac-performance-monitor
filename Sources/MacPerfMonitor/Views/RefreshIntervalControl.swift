import MacPerfMonitorCore
import SwiftUI

/// A compact toolbar control (present on every tab) that sets the GLOBAL refresh
/// interval: how often the live charts, read-outs and the process rows on screen
/// update. Slower intervals lower CPU use sharply (the default is a deliberately
/// light 10 s). The full per-process scan, the table order, rankings and alerts
/// keep a 5 s floor (`LiveRefreshCadence.fullProcessInterval`); the rows on
/// screen are re-read at the dial rate in between.
///
/// Backed by the shared `tableIntervalKey`, so it stays in lockstep with the same
/// setting in Settings, and the app applies any change through its
/// `UserDefaults.didChangeNotification` wiring. It reads only `@AppStorage`, not
/// the sampler, so placing it in the window toolbar does not re-render the tab
/// host on every sample.
struct RefreshIntervalControl: View {
    @AppStorage(SamplerModel.tableIntervalKey) private var interval =
        SamplerModel.defaultTableInterval

    var body: some View {
        Menu {
            Picker("Refresh interval", selection: $interval) {
                ForEach(SamplerModel.tableIntervalChoices, id: \.self) { seconds in
                    Text(SamplerModel.tableIntervalLabel(seconds)).tag(seconds)
                }
            }
            .pickerStyle(.inline)
        } label: {
            // Explicit icon + value so the toolbar shows the current interval
            // rather than collapsing a Label down to the glyph alone.
            HStack(spacing: 4) {
                Image(systemName: "timer")
                Text(SamplerModel.tableIntervalLabel(interval))
                    .font(.callout.monospacedDigit())
            }
        }
        .fixedSize()
        .help(
            "250ms and 500ms speed up the live charts and the process rows on screen. "
                + "The full process scan, the table order, rankings and alerts refresh every 5 s."
        )
    }
}
