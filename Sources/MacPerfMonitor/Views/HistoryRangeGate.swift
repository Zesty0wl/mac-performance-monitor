import MacPerfMonitorCore
import SwiftUI

/// Gates a history time-range control behind the app's function mode.
///
/// In full mode the wrapped control behaves normally. In menu-bar-only mode there
/// is no on-disk history to range over, so the control is shown dimmed and inert;
/// clicking it offers to turn history logging back on — which switches the app to
/// full mode and starts recording from that moment (history then builds up from
/// there). Apply with `.historyRangeGate()` as the outermost modifier on a
/// `HistoryWindow` range picker.
private struct HistoryRangeGate: ViewModifier {
    @EnvironmentObject private var components: AppComponentsManager
    @State private var showEnablePrompt = false

    @ViewBuilder
    func body(content: Content) -> some View {
        if components.historyLogging {
            content
        } else {
            // Dim the picker for the greyed-out look and turn off its hit testing
            // so it can't intercept the click; the tap lives on the *enclosing*
            // ZStack instead, so a click anywhere over the control offers to enable
            // logging rather than doing nothing. `.disabled` keeps the disabled
            // styling; `.allowsHitTesting(false)` guarantees the tap falls through.
            ZStack {
                content
                    .disabled(true)
                    .opacity(0.45)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .onTapGesture { showEnablePrompt = true }
            .help("History is off in menu-bar-only mode. Click to turn on logging.")
            .confirmationDialog(
                "Turn on history logging?",
                isPresented: $showEnablePrompt,
                titleVisibility: .visible
            ) {
                Button("Enable Logging") { components.historyLogging = true }
                Button("Not Now", role: .cancel) {}
            } message: {
                Text(
                    t(
                        "%@ is in menu-bar-only mode and isn't recording history. Turn on logging to chart these ranges — it starts recording now, and history builds up from here.",
                        AppInfo.displayName)
                )
            }
        }
    }
}

extension View {
    /// Disable a history time-range control in menu-bar-only mode, offering to
    /// re-enable logging when clicked. See `HistoryRangeGate`.
    func historyRangeGate() -> some View {
        modifier(HistoryRangeGate())
    }
}
