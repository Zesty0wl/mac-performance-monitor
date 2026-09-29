import AppKit
import MacPerfMonitorCore
import SwiftUI
import XCTest

@testable import MacPerfMonitor

@MainActor
final class MainWindowNavigationTests: XCTestCase {
    func testStartupDefaultsToMinimisedOnlyWithMenuBar() throws {
        let suite = "MainWindowNavigationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let loginItem = LoginItemManager(defaults: defaults)

        XCTAssertTrue(loginItem.startMinimised)
        XCTAssertFalse(loginItem.shouldPresentMainWindow(menuBarEnabled: true))
        XCTAssertTrue(loginItem.shouldPresentMainWindow(menuBarEnabled: false))
    }

    func testStartMinimisedPreferencePersistsAndCanBeDisabled() throws {
        let suite = "MainWindowNavigationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let loginItem = LoginItemManager(defaults: defaults)
        loginItem.startMinimised = false

        let relaunched = LoginItemManager(defaults: defaults)
        XCTAssertFalse(relaunched.startMinimised)
        XCTAssertTrue(relaunched.shouldPresentMainWindow(menuBarEnabled: true))
        XCTAssertTrue(relaunched.shouldPresentMainWindow(menuBarEnabled: false))

        relaunched.startMinimised = true
        XCTAssertFalse(
            LoginItemManager(defaults: defaults).shouldPresentMainWindow(menuBarEnabled: true))
    }

    func testGitHubStarNeedsAWeekAndBothSurfaces() throws {
        let suite = "MainWindowNavigationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let prompt = GitHubStarPrompt(defaults: defaults)
        let firstUse = Date(timeIntervalSince1970: 1_800_000_000)
        let oneWeekLater = firstUse.addingTimeInterval(7 * 24 * 60 * 60)

        XCTAssertFalse(prompt.shouldOfferPrompt(at: oneWeekLater))
        prompt.recordLaunch(at: firstUse)
        XCTAssertFalse(prompt.shouldOfferPrompt(at: oneWeekLater))
        prompt.recordUse(.menuBar, at: firstUse)
        XCTAssertFalse(prompt.shouldOfferPrompt(at: oneWeekLater))
        prompt.recordUse(.mainWindow, at: firstUse.addingTimeInterval(60))
        XCTAssertFalse(prompt.shouldOfferPrompt(at: firstUse.addingTimeInterval(-1)))
        XCTAssertFalse(prompt.shouldOfferPrompt(at: oneWeekLater.addingTimeInterval(-1)))
        XCTAssertTrue(prompt.shouldOfferPrompt(at: oneWeekLater))
        XCTAssertTrue(prompt.shouldOfferPrompt(at: oneWeekLater.addingTimeInterval(1)))
    }

    func testGitHubStarMainWindowAloneDoesNotQualify() throws {
        let suite = "MainWindowNavigationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let prompt = GitHubStarPrompt(defaults: defaults)
        let firstUse = Date(timeIntervalSince1970: 1_800_000_000)
        prompt.recordUse(.mainWindow, at: firstUse)

        XCTAssertFalse(prompt.shouldOfferPrompt(at: firstUse.addingTimeInterval(30 * 24 * 60 * 60)))
    }

    func testGitHubStarUsagePersistsWithoutResettingFirstUse() throws {
        let suite = "MainWindowNavigationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let firstUse = Date(timeIntervalSince1970: 1_800_000_000)
        let oneWeekLater = firstUse.addingTimeInterval(7 * 24 * 60 * 60)
        let prompt = GitHubStarPrompt(defaults: defaults)
        prompt.recordLaunch(at: firstUse)
        prompt.recordUse(.menuBar, at: firstUse)

        let relaunched = GitHubStarPrompt(defaults: defaults)
        relaunched.recordLaunch(at: oneWeekLater)
        relaunched.recordUse(.mainWindow, at: oneWeekLater)
        XCTAssertTrue(relaunched.shouldOfferPrompt(at: oneWeekLater))
    }

    func testGitHubStarDoesNotPromptAgainAfterPresentation() throws {
        let suite = "MainWindowNavigationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let firstUse = Date(timeIntervalSince1970: 1_800_000_000)
        let later = firstUse.addingTimeInterval(30 * 24 * 60 * 60)
        let prompt = GitHubStarPrompt(defaults: defaults)
        prompt.recordUse(.mainWindow, at: firstUse)
        prompt.recordUse(.menuBar, at: firstUse)
        XCTAssertTrue(prompt.shouldOfferPrompt(at: later))
        prompt.markPromptShown()
        XCTAssertFalse(prompt.shouldOfferPrompt(at: later))

        let relaunched = GitHubStarPrompt(defaults: defaults)
        relaunched.recordLaunch(at: later)
        relaunched.recordUse(.menuBar, at: later)
        relaunched.recordUse(.mainWindow, at: later)
        XCTAssertFalse(relaunched.shouldOfferPrompt(at: later))
    }

    func testGitHubStarWaitsForForegroundAndOtherPrompts() async throws {
        _ = NSApplication.shared
        let suite = "MainWindowNavigationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let prompt = GitHubStarPrompt(defaults: defaults)
        let firstUse = Date(timeIntervalSince1970: 1_800_000_000)
        let later = firstUse.addingTimeInterval(7 * 24 * 60 * 60)
        prompt.recordUse(.menuBar, at: firstUse)
        prompt.recordUse(.mainWindow, at: firstUse)
        let window = StarPromptTestWindow(
            contentRect: CGRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        defer { window.close() }
        await settle(window)
        XCTAssertTrue(window.isVisible)

        XCTAssertFalse(
            prompt.presentIfEligible(
                in: window, isAppActive: false, otherPromptPending: false, at: later))
        window.reportsKeyWindow = false
        XCTAssertFalse(
            prompt.presentIfEligible(
                in: window, isAppActive: true, otherPromptPending: false, at: later))
        window.reportsKeyWindow = true
        XCTAssertFalse(
            prompt.presentIfEligible(
                in: window, isAppActive: true, otherPromptPending: true, at: later))
        let otherSheet = NSWindow(
            contentRect: window.contentLayoutRect, styleMask: [.titled],
            backing: .buffered, defer: false)
        otherSheet.isReleasedWhenClosed = false
        window.beginSheet(otherSheet, completionHandler: nil)
        XCTAssertFalse(
            prompt.presentIfEligible(
                in: window, isAppActive: true, otherPromptPending: false, at: later))
        window.endSheet(otherSheet)
        otherSheet.close()
        window.orderOut(nil)
        XCTAssertFalse(
            prompt.presentIfEligible(
                in: window, isAppActive: true, otherPromptPending: false, at: later))
        XCTAssertTrue(prompt.shouldOfferPrompt(at: later))
    }

    func testGitHubStarSheetResponsesAreOnceOnly() async throws {
        _ = NSApplication.shared
        for response: NSApplication.ModalResponse in [
            .alertFirstButtonReturn, .alertSecondButtonReturn,
        ] {
            let suite = "MainWindowNavigationTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let prompt = GitHubStarPrompt(defaults: defaults)
            let firstUse = Date(timeIntervalSince1970: 1_800_000_000)
            let later = firstUse.addingTimeInterval(7 * 24 * 60 * 60)
            prompt.recordUse(.menuBar, at: firstUse)
            prompt.recordUse(.mainWindow, at: firstUse)
            let window = StarPromptTestWindow(
                contentRect: CGRect(x: 0, y: 0, width: 480, height: 320),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.orderFront(nil)
            defer {
                if let sheet = window.attachedSheet { window.endSheet(sheet) }
                window.close()
            }
            await settle(window)
            var openedURLs: [URL] = []
            XCTAssertTrue(
                prompt.presentIfEligible(
                    in: window, isAppActive: true, otherPromptPending: false, at: later,
                    openRepository: { openedURLs.append($0) }))
            let sheet = try XCTUnwrap(window.attachedSheet)
            XCTAssertFalse(GitHubStarPrompt(defaults: defaults).shouldOfferPrompt(at: later))
            window.endSheet(sheet, returnCode: response)
            await settle(window)

            XCTAssertEqual(
                openedURLs,
                response == .alertFirstButtonReturn ? [GitHubStarPrompt.repositoryURL] : [])
            XCTAssertFalse(
                prompt.presentIfEligible(
                    in: window, isAppActive: true, otherPromptPending: false, at: later))
        }
    }

    func testNavigationSupportsNativeTabViews() throws {
        _ = NSApplication.shared
        let tabs = NSTabView(frame: CGRect(x: 0, y: 0, width: 980, height: 720))
        for index in 0..<10 {
            let item = NSTabViewItem(identifier: index)
            item.label = "Tab \(index)"
            item.view = NSView()
            tabs.addTabViewItem(item)
        }
        let window = NSWindow(
            contentRect: tabs.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = tabs
        window.toolbar = NSToolbar(identifier: "navigation-test")
        defer { window.close() }
        tabs.selectTabViewItem(at: 3)
        let result = try navigation(in: window)
        XCTAssertEqual(result.labels, (0..<10).map { "Tab \($0)" })
        XCTAssertEqual(result.selected, 3)
    }

    func testFirstOpenNavigationMatchesReturningToDashboard() async throws {
        try await verifyNavigation(width: 980, appearance: .darkAqua)
        try await verifyNavigation(width: 1800, appearance: .aqua)
    }

    private func verifyNavigation(width: CGFloat, appearance: NSAppearance.Name) async throws {
        _ = NSApplication.shared
        let state = AppState()
        let sampler = SamplerModel(persistenceEnabled: false)
        let root = MainWindowGate()
            .environmentObject(state)
            .environmentObject(sampler)
            .environment(\.samplerModel, sampler)
            .environmentObject(sampler.menuLists)
            .environmentObject(HelperManager())
            .environmentObject(FullDiskAccessManager())
            .environmentObject(LoginItemManager())
            .environmentObject(MonitorSelection())
            .environmentObject(ProcessGroupStore.shared)
            .environmentObject(AppComponentsManager())
        let controller = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: controller)
        window.title = "Main navigation test"
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.toolbarStyle = .unifiedCompact
        window.setContentSize(NSSize(width: width, height: 720))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        await settle(window)

        let initialToolbar = try XCTUnwrap(window.toolbar)
        XCTAssertEqual(initialToolbar.items.count, 2)
        let toolbarIDs = initialToolbar.items.map(\.itemIdentifier)
        state.mainWindowOpen = true
        await settle(window)
        let first = try navigation(in: window)
        try capture(window, name: "first-open-\(Int(width))")

        state.requestedMainTab = .processes
        await settle(window)
        state.requestedMainTab = .dashboard
        await settle(window)
        let returned = try navigation(in: window)
        try capture(window, name: "after-tab-\(Int(width))")

        XCTAssertEqual(first.labels, returned.labels)
        XCTAssertEqual(first.selected, 0)
        XCTAssertEqual(returned.selected, 0)
        XCTAssertEqual(first.frame, returned.frame)
        XCTAssertEqual(first.toolbarHeight, returned.toolbarHeight)
        XCTAssertEqual(first.itemCount, returned.itemCount)

        state.mainWindowOpen = false
        await settle(window)
        XCTAssertTrue(window.toolbar === initialToolbar)
        XCTAssertEqual(window.toolbar?.items.count, 2)
        XCTAssertEqual(window.toolbar?.items.map(\.itemIdentifier), toolbarIDs)
        XCTAssertNil(navigationControl(in: try XCTUnwrap(window.contentView?.superview)))

        state.mainWindowOpen = true
        await settle(window)
        let reopened = try navigation(in: window)
        XCTAssertEqual(first.frame, reopened.frame)
        XCTAssertEqual(first.labels, reopened.labels)
        XCTAssertTrue(window.toolbar === initialToolbar)

        state.mainWindowVisible = false
        await settle(window)
        XCTAssertTrue(window.toolbar === initialToolbar)
        XCTAssertNil(navigationControl(in: try XCTUnwrap(window.contentView?.superview)))

        state.mainWindowVisible = true
        await settle(window)
        let visible = try navigation(in: window)
        XCTAssertEqual(first.frame, visible.frame)
        XCTAssertEqual(first.labels, visible.labels)
        XCTAssertEqual(window.toolbar?.items.map(\.itemIdentifier), toolbarIDs)
    }

    private final class StarPromptTestWindow: NSWindow {
        var reportsKeyWindow = true
        override var isKeyWindow: Bool { reportsKeyWindow }
    }

    private struct Navigation {
        let labels: [String]
        let selected: Int
        let frame: CGRect
        let toolbarHeight: CGFloat
        let itemCount: Int
    }

    private func navigation(in window: NSWindow) throws -> Navigation {
        let root = try XCTUnwrap(window.contentView?.superview)
        let control = try XCTUnwrap(navigationControl(in: root))
        let toolbar = try XCTUnwrap(window.toolbar)
        let labels: [String]
        let selected: Int
        if let segments = control as? NSSegmentedControl {
            labels = (0..<segments.segmentCount).map { segments.label(forSegment: $0) ?? "" }
            selected = segments.selectedSegment
        } else {
            let tabs = try XCTUnwrap(control as? NSTabView)
            labels = tabs.tabViewItems.map(\.label)
            selected = tabs.selectedTabViewItem.map { tabs.indexOfTabViewItem($0) } ?? -1
        }
        let result = Navigation(
            labels: labels, selected: selected,
            frame: control.convert(control.bounds, to: root),
            toolbarHeight: window.frame.height - window.contentLayoutRect.height,
            itemCount: toolbar.items.count)
        XCTAssertEqual(labels.count, 10)
        XCTAssertTrue(labels.allSatisfy { !$0.isEmpty })
        return result
    }

    private func navigationControl(in view: NSView) -> NSView? {
        if let control = view as? NSSegmentedControl, control.segmentCount == 10 { return control }
        if let control = view as? NSTabView, control.numberOfTabViewItems == 10 { return control }
        return view.subviews.lazy.compactMap { self.navigationControl(in: $0) }.first
    }

    private func settle(_ window: NSWindow) async {
        let settled = expectation(description: "Window renders its navigation")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { settled.fulfill() }
        await fulfillment(of: [settled], timeout: 3)
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }

    private func capture(_ window: NSWindow, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["MACPERF_NAVIGATION_ARTIFACTS"] else {
            return
        }
        let root = try XCTUnwrap(window.contentView?.superview)
        let region = CGRect(x: 0, y: root.bounds.height - 80, width: root.bounds.width, height: 80)
        let bitmap = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: region))
        root.cacheDisplay(in: region, to: bitmap)
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: directory.appendingPathComponent(name + ".png"))
    }
}
