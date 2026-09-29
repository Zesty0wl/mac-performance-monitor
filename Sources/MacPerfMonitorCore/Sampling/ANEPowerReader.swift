import Foundation

final class ANEPowerReader: @unchecked Sendable {
    private let lock = NSLock()
    private let requests = DispatchQueue(
        label: "uk.co.bzwrd.macperfmonitor.power-client", qos: .utility)
    private var provider: (any PrivilegedReader)?
    private var active = false
    private var requestID: UUID?
    private var lastRequest: TimeInterval?
    private var cached: ANEPowerReading?
    private var timer: DispatchSourceTimer?

    deinit {
        timer?.cancel()
        if active, let provider { requests.async { provider.stopANEPower() } }
    }

    var requiresHelper: Bool { lock.withLock { provider == nil } }

    func setProvider(_ provider: (any PrivilegedReader)?) {
        lock.lock()
        if let current = self.provider, let provider,
            (current as AnyObject) === (provider as AnyObject)
        {
            lock.unlock()
            return
        }
        let old = active ? self.provider : nil
        self.provider = provider
        active = false
        requestID = nil
        lastRequest = nil
        cached = nil
        lock.unlock()
        release(old)
    }

    func read(
        at now: Date = Date(), uptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> ANEPowerReading? {
        refresh(at: now, uptime: uptime, activating: true)
    }

    private func refresh(at now: Date, uptime: TimeInterval, activating: Bool) -> ANEPowerReading? {
        lock.lock()
        guard let provider, uptime.isFinite, activating || active else {
            lock.unlock()
            return nil
        }
        active = true
        let elapsed = lastRequest.map { uptime - $0 } ?? .infinity
        let shouldRequest = elapsed < 0 || elapsed >= (requestID == nil ? 1 : 3)
        let identifier = shouldRequest ? UUID() : nil
        if let identifier {
            requestID = identifier
            lastRequest = uptime
        }
        let reading = cached.flatMap { $0.isFresh(at: now) ? $0 : nil }
        lock.unlock()
        if let identifier {
            requests.async { [weak self] in
                guard let self, self.lock.withLock({ self.active && self.requestID == identifier })
                else { return }
                if self.timer == nil {
                    let timer = DispatchSource.makeTimerSource(queue: self.requests)
                    timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
                    timer.setEventHandler { [weak self] in
                        _ = self?.refresh(
                            at: Date(), uptime: ProcessInfo.processInfo.systemUptime,
                            activating: false)
                    }
                    self.timer = timer
                    timer.resume()
                }
                provider.readANEPower { [weak self] reading in
                    guard let self else { return }
                    self.lock.withLock {
                        guard self.active, self.requestID == identifier else { return }
                        self.requestID = nil
                        self.cached = reading.flatMap { $0.isFresh(at: Date()) ? $0 : nil }
                    }
                }
            }
        }
        return reading
    }

    func stop() {
        lock.lock()
        let old = active ? provider : nil
        active = false
        requestID = nil
        lastRequest = nil
        cached = nil
        lock.unlock()
        release(old)
    }

    private func release(_ old: (any PrivilegedReader)?) {
        guard let old else { return }
        requests.async { [self] in
            if lock.withLock({ !active }) {
                timer?.cancel()
                timer = nil
            }
            old.stopANEPower()
        }
    }
}
