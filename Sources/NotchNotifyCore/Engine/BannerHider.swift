import CoreGraphics
import Foundation
import os

private let handoffLog = Logger(subsystem: "io.github.jakobkollerup.notchnotify", category: "handoff")

@MainActor
protocol BannerHostAccess: AnyObject {
    associatedtype Window
    func key(of window: Window) -> CFHashCode
    func isRecognizedBanner(_ window: Window) -> Bool
    func isNotificationCenterPanel(_ window: Window) -> Bool
    func frame(of window: Window) -> CGRect?
    func move(_ window: Window, to origin: CGPoint) -> Bool
}

@MainActor
final class ScheduledAction {
    private let onCancel: () -> Void

    init(onCancel: @escaping () -> Void) { self.onCancel = onCancel }

    func cancel() { onCancel() }
}

@MainActor
protocol DelayedActionScheduling: AnyObject {
    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> ScheduledAction
}

@MainActor
final class MainQueueScheduler: DelayedActionScheduling {
    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> ScheduledAction {
        let item = DispatchWorkItem { MainActor.assumeIsolated { action() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return ScheduledAction { item.cancel() }
    }
}

/// Bounds are in global display coordinates (top-left origin, y down), the
/// same space Accessibility positions use.
@MainActor
final class DisplayLayout {
    private let displayBounds: () -> [CGRect]

    init(displayBounds: @escaping () -> [CGRect]) { self.displayBounds = displayBounds }

    convenience init() {
        self.init {
            var count: UInt32 = 0
            guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
            var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
            guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
            return ids.prefix(Int(count)).map(CGDisplayBounds)
        }
    }

    func isOutsideAllDisplays(_ rect: CGRect) -> Bool {
        !displayBounds().contains { $0.intersects(rect) }
    }

    func parkingOrigin(for frame: CGRect) -> CGPoint {
        let top = displayBounds().map(\.minY).min() ?? 0
        return CGPoint(x: frame.minX, y: min(-9999, top - frame.height - 1))
    }
}

enum HideOutcome: Equatable {
    case hidden
    case alreadyHidden
    case failed
    case notBanner
    case excluded
}

/// Timing markers for the native-banner handoff. Only window hashes and
/// durations are logged — never notification contents.
@MainActor
final class HandoffTrace {
    struct Record: Equatable {
        let key: CFHashCode
        let event: String
        let startedMs: Double
        let recognizedMs: Double
        let requestedMs: Double
        let verifiedMs: Double?
    }

    private let clock: () -> TimeInterval
    private var lastEvent: (name: String, at: TimeInterval)?
    private var arrivals: [CFHashCode: TimeInterval] = [:]
    private(set) var lastRecord: Record?

    init(clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.clock = clock
    }

    func now() -> TimeInterval { clock() }

    func eventReceived(_ name: String) {
        lastEvent = (name, clock())
    }

    func hideAttempt(key: CFHashCode, startedAt: TimeInterval, recognizedAt: TimeInterval,
                     requestedAt: TimeInterval, verifiedAt: TimeInterval?, fromCheck: Bool = false) {
        let event = fromCheck ? nil : lastEvent
        let origin = event?.at ?? startedAt
        let ms = { (t: TimeInterval) in (t - origin) * 1000 }
        let record = Record(key: key, event: event?.name ?? "check",
                            startedMs: ms(startedAt), recognizedMs: ms(recognizedAt), requestedMs: ms(requestedAt),
                            verifiedMs: verifiedAt.map(ms))
        lastRecord = record
        if verifiedAt != nil, arrivals[key] == nil { arrivals[key] = origin }
        let verified = record.verifiedMs.map { String(format: "%.1f", $0) } ?? "failed"
        handoffLog.info("hide key=\(key, privacy: .public) event=\(record.event, privacy: .public) started=\(String(format: "%.1f", record.startedMs), privacy: .public)ms recognized=\(String(format: "%.1f", record.recognizedMs), privacy: .public)ms requested=\(String(format: "%.1f", record.requestedMs), privacy: .public)ms verified=\(verified, privacy: .public)")
    }

    @discardableResult
    func notchPresented(key: CFHashCode) -> Double? {
        guard let start = arrivals.removeValue(forKey: key) else { return nil }
        let ms = (clock() - start) * 1000
        handoffLog.info("notch presented key=\(key, privacy: .public) +\(String(format: "%.1f", ms), privacy: .public)ms")
        return ms
    }

    func forget(key: CFHashCode) { arrivals.removeValue(forKey: key) }

    func reset() {
        arrivals.removeAll()
        lastEvent = nil
    }
}

/// Moves a positively identified native banner off every display before any
/// app-name, placement or content work, and confirms the result. Each real
/// move starts a short, bounded check schedule: macOS can reset a host's
/// position during its entrance, and an Accessibility write can fail.
@MainActor
final class BannerHider<Access: BannerHostAccess> {
    private let access: Access
    private let displays: DisplayLayout
    private let scheduler: DelayedActionScheduling
    private let trace: HandoffTrace
    private let checkDelays: [TimeInterval]
    private let shouldHide: () -> Bool

    private var checks: [CFHashCode: ScheduledAction] = [:]
    private(set) var verifiedHidden: Set<CFHashCode> = []

    init(access: Access, displays: DisplayLayout, scheduler: DelayedActionScheduling,
         trace: HandoffTrace, checkDelays: [TimeInterval] = [0.008, 0.016, 0.033, 0.066, 0.12, 0.25, 0.5],
         shouldHide: @escaping () -> Bool) {
        self.access = access
        self.displays = displays
        self.scheduler = scheduler
        self.trace = trace
        self.checkDelays = checkDelays
        self.shouldHide = shouldHide
    }

    func isVerifiedHidden(_ key: CFHashCode) -> Bool { verifiedHidden.contains(key) }

    func hasPendingCheck(_ key: CFHashCode) -> Bool { checks[key] != nil }

    /// Requires the window to be a recognised banner host and not the
    /// Notification Center panel.
    @discardableResult
    func hide(_ window: Access.Window) -> HideOutcome {
        attempt(window, requireBanner: true, step: nil)
    }

    /// For callers that already made the banner decision themselves.
    @discardableResult
    func park(_ window: Access.Window) -> HideOutcome {
        attempt(window, requireBanner: false, step: nil)
    }

    func forget(key: CFHashCode) {
        checks.removeValue(forKey: key)?.cancel()
        verifiedHidden.remove(key)
        trace.forget(key: key)
    }

    func cancelAll() {
        checks.values.forEach { $0.cancel() }
        checks.removeAll()
        verifiedHidden.removeAll()
        trace.reset()
    }

    private func attempt(_ window: Access.Window, requireBanner: Bool, step: Int?) -> HideOutcome {
        let key = access.key(of: window)
        let startedAt = trace.now()
        guard shouldHide() else {
            forget(key: key)
            return .excluded
        }
        if requireBanner {
            guard access.isRecognizedBanner(window) else {
                forget(key: key)
                return .notBanner
            }
            guard !access.isNotificationCenterPanel(window) else {
                forget(key: key)
                return .excluded
            }
        }
        let recognizedAt = trace.now()
        let outcome: HideOutcome
        var requestedAt = recognizedAt
        var verifiedAt: TimeInterval?
        let frame = access.frame(of: window)
        if let frame, displays.isOutsideAllDisplays(frame) {
            outcome = .alreadyHidden
        } else if let frame {
            requestedAt = trace.now()
            let wrote = access.move(window, to: displays.parkingOrigin(for: frame))
            if wrote, let after = access.frame(of: window), displays.isOutsideAllDisplays(after) {
                verifiedAt = trace.now()
                outcome = .hidden
            } else {
                outcome = .failed
            }
        } else {
            outcome = .failed
        }

        if outcome == .failed { verifiedHidden.remove(key) } else { verifiedHidden.insert(key) }
        if outcome != .alreadyHidden {
            trace.hideAttempt(key: key, startedAt: startedAt, recognizedAt: recognizedAt, requestedAt: requestedAt,
                              verifiedAt: verifiedAt, fromCheck: step != nil)
        }

        switch (outcome, step) {
        case (.alreadyHidden, nil):
            break
        case (_, nil):
            scheduleCheck(window, key: key, requireBanner: requireBanner, step: 0)
        case (_, let step?):
            scheduleCheck(window, key: key, requireBanner: requireBanner, step: step + 1)
        }
        if checks[key] == nil, outcome == .failed {
            handoffLog.info("hide key=\(key, privacy: .public) unverified after \(self.checkDelays.count, privacy: .public) checks")
        }
        return outcome
    }

    private func scheduleCheck(_ window: Access.Window, key: CFHashCode, requireBanner: Bool, step: Int) {
        checks.removeValue(forKey: key)?.cancel()
        guard step < checkDelays.count else { return }
        checks[key] = scheduler.schedule(after: checkDelays[step]) { [weak self] in
            guard let self else { return }
            self.checks.removeValue(forKey: key)
            _ = self.attempt(window, requireBanner: requireBanner, step: step)
        }
    }
}
