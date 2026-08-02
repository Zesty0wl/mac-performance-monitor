import AppKit
import Combine
import CoreGraphics
import MacPerfMonitorCore

/// Hides or shows the camera notch on a built-in Mac display, behind the menu's
/// "Hide Notch" / "Show Notch" toggle.
///
/// Why the app offers this at all: status items only get the menu bar to the right
/// of the notch, 664pt of the 1512 a 14-inch publishes. Our combined read-out is
/// wide by nature, and once the system's own items are placed there is little room
/// left, at which point macOS silently drops the overflow behind the notch with no
/// indicator and no API to detect it (`NSStatusItem.isVisible` keeps reporting
/// true). Switching the display to its notch-free twin returns the notch's 185pt
/// to the bar and lets everything sit in one uninterrupted row.
///
/// The mechanism is a plain display-mode change (see `NotchDisplayModes`): the
/// same scaled size, minus the band the camera housing occupies. It costs 37pt of
/// height on a 14-inch, and it is system-wide rather than ours alone, which is why
/// it is an explicit toggle and never automatic.
///
/// The choice is remembered and re-asserted: applied at launch, so a reboot or a
/// macOS-side reset does not quietly undo it, and re-applied whenever the screen
/// configuration changes. That last part also means picking a different scaled
/// size in System Settings keeps the notch hidden, since we re-target the twin of
/// whatever size the user chose rather than pinning one resolution.
@MainActor
final class NotchDisplayController: ObservableObject {
    /// UserDefaults key. Absent reads as `false`, so the display is never touched
    /// until the user asks for it.
    static let defaultsKey = "hideNotch"

    /// Whether this Mac has a notch to hide. Drives whether the menu shows the
    /// item at all, so Macs without one never see a toggle that does nothing.
    @Published private(set) var isSupported = false
    /// Whether the menu bar is currently sitting below the camera housing.
    @Published private(set) var isNotchHidden = false

    private let defaults: UserDefaults
    private var cancellables = Set<AnyCancellable>()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Read the display, apply the remembered choice, then keep enforcing it.
    func start() {
        refreshState()
        if defaults.bool(forKey: Self.defaultsKey) {
            apply(hidingNotch: true)
        }
        // Fires on wake, on docking or undocking a display, and when the user
        // changes resolution in System Settings.
        NotificationCenter.default
            .publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.screenParametersChanged() }
            .store(in: &cancellables)
    }

    /// Toggle target for the menu. Remembers the choice first, so a failure to
    /// switch (or a display that disappears mid-flight) still leaves the app
    /// agreeing with what the user asked for and re-asserting it later.
    func setNotchHidden(_ hidden: Bool) {
        defaults.set(hidden, forKey: Self.defaultsKey)
        apply(hidingNotch: hidden)
    }

    // MARK: - Display work

    private func screenParametersChanged() {
        refreshState()
        // Only ever re-assert hiding. Coming back the other way is the user's
        // call, and forcing the notch back would fight anyone who changed the
        // resolution deliberately.
        guard defaults.bool(forKey: Self.defaultsKey), isSupported, !isNotchHidden else {
            return
        }
        apply(hidingNotch: true)
    }

    private func refreshState() {
        guard let display = Self.builtInDisplay(),
            let current = CGDisplayCopyDisplayMode(display)
        else {
            isSupported = false
            isNotchHidden = false
            return
        }
        let modes = Self.modes(of: display).map(Self.descriptor)
        isSupported = NotchDisplayModes.hasNotchPair(in: modes)
        isNotchHidden = NotchDisplayModes.isNotchHidden(
            current: Self.descriptor(current), in: modes)
    }

    private func apply(hidingNotch hidden: Bool) {
        guard let display = Self.builtInDisplay(),
            let current = CGDisplayCopyDisplayMode(display)
        else { return }

        let modes = Self.modes(of: display)
        let descriptors = modes.map(Self.descriptor)
        let currentDescriptor = Self.descriptor(current)
        let target =
            hidden
            ? NotchDisplayModes.notchFreeTwin(of: currentDescriptor, in: descriptors)
            : NotchDisplayModes.notchedTwin(of: currentDescriptor, in: descriptors)

        // Already there, or this display has no twin for the current size.
        guard let target, let mode = modes.first(where: { Self.descriptor($0) == target }) else {
            refreshState()
            return
        }

        var configuration: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&configuration) == .success,
            let configuration
        else {
            AppLog.ui.error("notch toggle: could not begin a display configuration")
            return
        }
        CGConfigureDisplayWithDisplayMode(configuration, display, mode, nil)
        // Permanently, so the choice survives our own quit the way a resolution
        // picked in System Settings would. `start()` re-asserts it regardless, for
        // the cases macOS resets it behind our back.
        let result = CGCompleteDisplayConfiguration(configuration, .permanently)
        if result != .success {
            AppLog.ui.error(
                "notch toggle: display configuration failed (\(result.rawValue, privacy: .public))")
        }
        refreshState()
    }

    // MARK: - CoreGraphics adapters

    /// The Mac's own panel. External displays never carry a notch, and switching
    /// one of those out from under the user would be plain wrong.
    private static func builtInDisplay() -> CGDirectDisplayID? {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return nil }
        return ids.first { CGDisplayIsBuiltin($0) != 0 }
    }

    /// Every mode the panel publishes, including the scaled HiDPI ones.
    ///
    /// The options dictionary is not optional in practice: called with `nil`,
    /// `CGDisplayCopyAllDisplayModes` omits the scaled modes entirely, and on a
    /// 14-inch that means the list comes back without the 1512-point family the
    /// display is actually running, so the current mode is not in its own mode
    /// list and nothing can ever pair with it.
    private static func modes(of display: CGDirectDisplayID) -> [CGDisplayMode] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        return (CGDisplayCopyAllDisplayModes(display, options) as? [CGDisplayMode]) ?? []
    }

    private static func descriptor(_ mode: CGDisplayMode) -> DisplayModeDescriptor {
        DisplayModeDescriptor(
            width: mode.width, height: mode.height,
            pixelWidth: mode.pixelWidth, pixelHeight: mode.pixelHeight,
            refreshRate: mode.refreshRate)
    }
}
