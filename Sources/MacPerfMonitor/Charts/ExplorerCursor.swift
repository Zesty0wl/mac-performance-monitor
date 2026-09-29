import AppKit
import Combine
import SwiftUI

final class ExplorerCursor: ObservableObject {
    @Published private(set) var date: Date?
    @Published private(set) var pinned = false
    private var observers: [UUID: (Date?) -> Void] = [:]

    func move(to date: Date?) {
        guard !pinned else { return }
        publish(date)
    }

    func pin(_ date: Date) {
        pinned = true
        publish(date)
    }

    func clear() {
        pinned = false
        publish(nil)
    }

    func observe(_ action: @escaping (Date?) -> Void) -> UUID {
        let token = UUID()
        observers[token] = action
        action(date)
        return token
    }

    func remove(_ token: UUID) { observers.removeValue(forKey: token) }

    private func publish(_ date: Date?) {
        self.date = date
        for observer in observers.values { observer(date) }
    }
}

struct ExplorerTrendChart: NSViewRepresentable {
    let feed: TrendFeed
    let cursor: ExplorerCursor
    var allowsInspection = true
    var onZoom: ((Double, Double) -> Void)?
    var onPin: (Date) -> Void = { _ in }

    final class Coordinator {
        var cursor: ExplorerCursor?
        var token: UUID?

        func detach() {
            if let token { cursor?.remove(token) }
            token = nil
            cursor = nil
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> TrendSurfaceView {
        let view = TrendSurfaceView()
        view.scrubbable = true
        view.showsHoverPopover = false
        view.attach(feed)
        connect(view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ view: TrendSurfaceView, context: Context) {
        if view.feed !== feed { view.attach(feed) }
        connect(view, coordinator: context.coordinator)
    }

    private func connect(_ view: TrendSurfaceView, coordinator: Coordinator) {
        view.onTimeZoom = onZoom
        view.onTimeHover = { date in
            if allowsInspection { cursor.move(to: date) }
        }
        view.onTimePin = { date in
            guard allowsInspection else { return }
            cursor.pin(date)
            onPin(date)
        }
        if coordinator.cursor !== cursor {
            coordinator.detach()
            coordinator.cursor = cursor
            coordinator.token = cursor.observe { [weak view] date in view?.setInspectionDate(date) }
        }
    }

    static func dismantleNSView(_ view: TrendSurfaceView, coordinator: Coordinator) {
        coordinator.detach()
        view.onTimeHover = nil
        view.onTimePin = nil
        view.onTimeZoom = nil
        view.detach()
    }
}
