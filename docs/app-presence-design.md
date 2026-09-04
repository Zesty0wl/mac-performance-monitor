# App presence: window, menu bar item, and logger as independent components

Design note for issue #21. Status: agreed, not yet implemented.

## What this is about

Issue #21 asks for a way to remove the menu bar item while the app keeps
monitoring and logging in the background. #67 asked for the same thing and was
closed as a duplicate. Working through it turned a small toggle into a question
about the shape of the app, because the menu bar item is not just a read-out
today: it is the only thing that can open a window, and the only place the Quit
command lives.

There are three components a user can reason about:

- the **main window**, where you look at data;
- the **menu bar item**, the always-there read-out;
- the **logger**, the background recorder that fills the history database.

Each should be usable without the others. Two already are.

## Where the code stands today

**The app is menu-bar-first by construction.** `LSUIElement` is true
(`Resources/Info.plist:42`), so it launches as an accessory with no Dock icon
and no application menu. The main window scene sets
`.defaultLaunchBehavior(.suppressed)` (`Sources/MacPerfMonitor/App/MacPerfMonitorApp.swift:134`),
so a launch shows nothing at all. The Dock icon is opt-in and off by default,
applied live by switching the activation policy
(`Sources/MacPerfMonitor/App/DockIconController.swift:23,41-49`).

**The logger is already separable.** `MacPerfMonitorCore` imports no AppKit and
no SwiftUI anywhere, and `SamplerModel` imports only Combine, Foundation and
that library. `AppMode` already turns persistence on and off live
(`Sources/MacPerfMonitor/Settings/AppModeManager.swift`), releasing the store
and reverting the scan cadence, and a launch in menu-bar-only mode never creates
the database file.

**The window is already separable.** It is a `Window` scene wrapped in
`MainWindowGate` (`MacPerfMonitorApp.swift:755-774`), which unmounts the whole
interface when the window closes or is merely covered. Sampling does not care.
History controls degrade gracefully through `HistoryRangeGate`
(`Sources/MacPerfMonitor/Views/HistoryRangeGate.swift`), which dims the range
pickers and offers to switch logging back on.

**The menu bar item is not separable, and removing it breaks the app.** There is
exactly one status item, installed unconditionally by
`CombinedStatusItemController.installItem()`
(`Sources/MacPerfMonitor/App/CombinedStatusItemController.swift:97-111`). Three
guards stop the user reaching zero read-outs: the configuration refuses to
deselect the last metric
(`Sources/MacPerfMonitor/App/CombinedMenuBarConfiguration.swift:107`), Settings
disables that toggle (`Sources/MacPerfMonitor/Views/SettingsView.swift:235`),
and the loader re-seeds a default when the stored list decodes empty
(`CombinedMenuBarConfiguration.swift:133-136`). Four index reads assume a first
element and would trap on an empty selection
(`CombinedMenuBarConfiguration.swift:98,110-111`,
`CombinedStatusItemController.swift:130-132`,
`Sources/MacPerfMonitor/App/CombinedMenuBarImage.swift:96`).

Two consequences matter more than the guards:

1. **The only SwiftUI window opener lives inside the status item's button.** A
   one-pixel `NSHostingView<MenuBarWindowRouter>` is added as a subview there
   (`CombinedStatusItemController.swift:103-108`). Every path that opens a
   window, including the Dock click handler
   (`MacPerfMonitorApp.swift:678-688`), notification clicks, trace-file opens
   and the menu commands, queues through `WindowOpenBridge`
   (`MacPerfMonitorApp.swift:787-812`) until that view registers
   (`MacPerfMonitorApp.swift:817-848`). Remove the item and the queue never
   drains.
2. **Quit lives only in the item's overflow menu**
   (`Sources/MacPerfMonitor/Views/CombinedMenuBarContentView.swift:237-239`).
   An accessory app has no application menu, so there is no Command-Q. Hide the
   item today and Force Quit is the only way out.

**Five dead controllers.** `MemoryStatusItemController`,
`CPUStatusItemController`, `GPUStatusItemController`,
`NetworkStatusItemController` and `BatteryStatusItemController` each create
their own status item and none is ever instantiated. Their visibility keys
survive only as migration inputs for the combined item.

## Decisions

**1. The app becomes app-first.** The window is the primary surface. The menu
bar item and the logger become optional components, each with its own switch in
Settings. This is the inversion of today's identity, where the menu bar item is
the app and the window is an accessory.

**2. The Dock icon follows the window.** The app runs as a regular application
while any window is open, and drops back to accessory when the last one closes.
That gives the standard application menu, Command-Q, Edit and Window menus
exactly when a window is on screen and they are useful, and no Dock clutter
while the app is only logging. `Resources/Info.plist` keeps `LSUIElement` true
so that a login-item launch stays quiet and no Dock icon flashes on the way up.

A single preference remains, off by default: keep the Dock icon while running in
the background. It pins the regular policy for people who want the app in the
Dock permanently. The old "show icon in the Dock" toggle is replaced by it.

**3. The app quits when it has nothing to do.** When the last window closes, the
app keeps running only if the menu bar item is on, or history logging is on.
If neither is, it terminates like a normal document-less application. This
removes the state where the app is running, invisible, and doing nothing, and it
removes the need for the "at least one surface" invariant discussed earlier: a
user who turns everything off gets an app that closes, not an app that hides.

**4. Reopening is always launching the app again.** With no window and no menu
bar item, the way back in is to open the app from Spotlight, the Finder or the
Dock, which activates the running instance and surfaces the window. Opening the
window makes the app regular again, so the way in and the way out become the
same gesture. This path must be made reliable, which is phase 1.

**5. One process.** The logger does not become a separate daemon. The engine is
already UI-free and the command line tool can already sample and write, so it
looks tempting, but a second process means two writers against a database whose
retention, checkpointing and change-gating the app manages itself, and the app
would have to become an IPC client for every live read-out. An app with no
window and no menu bar item already is a headless logger.

**6. The mode picker splits in two.** `AppMode.full` and `AppMode.menuBarOnly`
conflate "logs history" with "menu bar only", which is the exact conflation this
work removes. It becomes two independent switches with a migration.

## The resulting model

| Menu bar item | Logging | Window closed, what happens |
| --- | --- | --- |
| on | on | keeps running and recording, read-out in the menu bar |
| on | off | keeps running, live read-out only, no history written |
| off | on | keeps running and recording, invisible until relaunched |
| off | off | quits |

While a window is open the app is a regular application in all four rows, with a
Dock icon and the standard menus.

## Phases

Each phase is one pull request into the `2.0.0` branch, CI green, squash
merged. Nothing lands on `main` until the whole shape is finished and
released. See "Branch and release" below.

### Phase 1: make window opening independent of the menu bar

No user-visible change. Everything else depends on this.

- Move `MenuBarWindowRouter` out of the status item button into a host that
  always exists, so `WindowOpenBridge` drains whether or not there is an item.
- Make `SingleInstanceGuard.activateExistingAndExitIfRunning()`
  (`MacPerfMonitorApp.swift:50-63`) surface the main window, not just activate
  the process, so relaunching from Spotlight brings the window back.
- Confirm `applicationShouldHandleReopen` still works through the new host.
- Delete the five dead status item controllers, keeping their defaults keys
  where `CombinedMenuBarConfiguration` reads them for migration.
- Tests: opening a window with the status item torn down; the bridge draining
  after a late registration.

### Phase 2: presence and lifetime

- Replace `DockIconController` with a controller that owns the activation
  policy and derives it from the number of visible app windows, plus the new
  background pin preference. Count every app window, not just the main one, so
  an open inspector or the Settings window keeps the app regular.
- Detect a login-item launch with `NSApplicationLaunchIsDefaultLaunchKey` and
  suppress the window in that case only. A user launch presents the window.
- Flip the main window scene to present at launch, following the conditional
  pattern the onboarding scene already uses
  (`MacPerfMonitorApp.swift:193`).
- Implement the quit rule for the last window closing.
- Verify what SwiftUI does on last-window-close once the app is regular, and
  implement `applicationShouldTerminateAfterLastWindowClosed` explicitly rather
  than relying on the default either way.

### Phase 3: split the components

- Replace `AppMode` with `menuBarItemEnabled` and `historyLoggingEnabled`, with
  a migration from the stored `appMode` key: `.full` becomes logging on and item
  on, `.menuBarOnly` becomes logging off and item on.
- Allow the status item to be installed and removed live, and allow zero
  read-outs. Fix the four index reads that assume a first element.
- Remove the "at least one read-out" guard and its Settings footer, replaced by
  the item's own on and off switch.
- Rework the "Menu Bar & Dock" Settings tab into the three switches, with copy
  that says what closing the window will do in the current combination.
- Keep the pause and resume logging action in the menu bar popover.

### Phase 4: correctness this exposes

- **Alerts must be an explicit sampling consumer.** Today the process scan runs
  only when `persistenceEnabled || processConsumers > 0 || popoverOpen`
  (`Sources/MacPerfMonitor/ViewModels/SamplerModel.swift:1025`) and the scan
  returns early otherwise (`:1111`), so with logging off and nothing open no
  alert is ever evaluated, including memory pressure, even though a kernel
  pressure event forces a tick. Add alerts to that condition. This is a bug
  today and becomes much more visible when the menu bar item can be off.
- Gate the per-tick main thread hop (`SamplerModel.swift:1058-1088`) so it does
  not run when nothing is on screen and no read-out needs redrawing.
- Rewrite the onboarding menu bar step, which currently teaches the user to look
  for a read-out near the clock and assumes it exists.

### Phase 5: finish

- CHANGELOG, glossary entries for the new switches, README wording.
- A short note in this document recording what was actually built.
- Screenshots for the new Settings tab.

## Branch and release

This ships as **2.0.0**, on a long-lived `2.0.0` branch, because it changes what
the app is rather than adding to it. An existing user's app gains a Dock icon
while its window is open, shows its window on a manual launch instead of
appearing to do nothing, and can now quit itself when everything is switched
off. That is a major version by any reading.

Four things follow from working on a branch:

- **CI runs on pull requests into `2.0.0`** as it does for `main`, and the
  workflow's push trigger includes the branch so the integration branch itself
  is checked after every merge.
- **Merge `main` into `2.0.0` regularly**, at least whenever `main` moves. The
  file that will conflict is `Localizations/Localizable.xcstrings`, exactly as
  Crowdin's pull requests do, and the resolution rules in CONTRIBUTING.md apply
  the same way.
- **New strings reach Crowdin only after the merge to `main`**, since the
  integration syncs the default branch. Translations for the new Settings copy
  therefore have to be written in-branch, which is what CI requires anyway, and
  Crowdin picks them up at release.
- **The version bump is the last commit before the release**, following the
  usual flow in `Scripts/deploy.sh`. The release notes need to lead with the
  three visible changes above, because they arrive through Sparkle on machines
  whose owners chose a menu bar app.

## Verification

- `swift test` and `swift format lint --strict`, plus
  `Scripts/check-localization.py` and `Scripts/check-string-coverage.py` for the
  new strings.
- Manual walk with `Scripts/run.sh --developer-id`, killing the old process
  first: launch shows the window and a Dock icon; close it and the icon goes
  with the menu bar item still there; reopen from the item; turn the item off
  and confirm the window still opens from Spotlight; turn logging off too and
  confirm closing the window quits the app.
- Login item: enable it, log out and back in, confirm no window and no Dock icon
  appear and that logging is running.
- Alerts: with the item off and no window, force a pressure event and confirm a
  notification still arrives.
- Idle cost: `top -l 31 -s 2` with no window and no item, compared against the
  budget in `docs/performance-budget.md`.
- Update: run a Sparkle update while the app has no window open, since the
  status item teardown at quit
  (`CombinedStatusItemController.swift:113-127`) and the terminate handshake
  (`MacPerfMonitorApp.swift:562-571`) both assume an item exists.

## Risks

- **Activation policy flipping under a live window** is known to cause focus
  oddities. Apply the change after the window close completes rather than
  during it, and never while a sheet or modal is up.
- **Existing users** are all running menu-bar-first with no Dock icon. They keep
  their menu bar item and their logging setting, but they will see a Dock icon
  while the window is open, and a manual launch will now show the window instead
  of appearing to do nothing. Both are improvements, but they are visible
  changes and belong in the release notes.
- **Quit at the wrong moment.** The quit rule must not fire while an update is
  installing or a Disk Map scan is running.
- **Accessory quirks already exist**: opening Settings from an accessory app can
  put the window behind everything, which is why the menu bar panel activates
  the app explicitly
  (`Sources/MacPerfMonitor/Views/MenuBarContentView.swift:136-145`). Being
  regular while a window is open should remove that class of problem rather than
  add to it.
