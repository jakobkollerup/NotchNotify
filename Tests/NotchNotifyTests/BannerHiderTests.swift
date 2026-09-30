import CoreGraphics
import Foundation
import Testing
@testable import NotchNotifyCore

@MainActor
private final class FakeHosts: BannerHostAccess {
    var frames: [Int: CGRect] = [:]
    var banners: Set<Int> = []
    var notificationCenterPanels: Set<Int> = []
    var failingWrites: Set<Int> = []
    var ignoredWrites: Set<Int> = []
    private(set) var moves: [Int] = []

    func key(of window: Int) -> CFHashCode { CFHashCode(window) }
    func isRecognizedBanner(_ window: Int) -> Bool { banners.contains(window) }
    func isNotificationCenterPanel(_ window: Int) -> Bool { notificationCenterPanels.contains(window) }
    func frame(of window: Int) -> CGRect? { frames[window] }

    func move(_ window: Int, to origin: CGPoint) -> Bool {
        moves.append(window)
        if failingWrites.contains(window) { return false }
        if !ignoredWrites.contains(window) { frames[window]?.origin = origin }
        return true
    }
}

@MainActor
private final class ManualScheduler: DelayedActionScheduling {
    private var pending: [(id: Int, delay: TimeInterval, action: @MainActor () -> Void)] = []
    private var nextID = 0

    var pendingDelays: [TimeInterval] { pending.map(\.delay) }

    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> ScheduledAction {
        nextID += 1
        let id = nextID
        pending.append((id, delay, action))
        return ScheduledAction { [weak self] in self?.pending.removeAll { $0.id == id } }
    }

    func runNext() {
        guard !pending.isEmpty else { return }
        pending.removeFirst().action()
    }

    func runAll(limit: Int = 100) {
        var runs = 0
        while !pending.isEmpty && runs < limit {
            runNext()
            runs += 1
        }
    }
}

@MainActor
private final class ManualClock {
    var now: TimeInterval = 100
}

@Suite("Immediate native banner hiding") @MainActor
struct BannerHiderTests {
    private let primary = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let above = CGRect(x: 0, y: -1440, width: 2560, height: 1440)
    private let bannerFrame = CGRect(x: 1126, y: 14, width: 372, height: 100)

    private func makeHider(hosts: FakeHosts, scheduler: ManualScheduler, displays: [CGRect]? = nil,
                           trace: HandoffTrace? = nil,
                           delays: [TimeInterval] = [0.008, 0.016, 0.033],
                           shouldHide: @escaping () -> Bool = { true }) -> BannerHider<FakeHosts> {
        let bounds = displays ?? [primary]
        return BannerHider(access: hosts, displays: DisplayLayout { bounds }, scheduler: scheduler,
                           trace: trace ?? HandoffTrace(), checkDelays: delays, shouldHide: shouldHide)
    }

    private func isOffscreen(_ rect: CGRect?, _ displays: [CGRect]) -> Bool {
        guard let rect else { return false }
        return !displays.contains { $0.intersects(rect) }
    }

    @Test func recognisedBannerIsMovedOffEveryDisplayAndVerified() {
        let hosts = FakeHosts()
        hosts.frames[1] = bannerFrame
        hosts.banners = [1]
        let hider = makeHider(hosts: hosts, scheduler: ManualScheduler())

        #expect(hider.hide(1) == .hidden)
        #expect(isOffscreen(hosts.frames[1], [primary]))
        #expect(hider.isVerifiedHidden(1))
    }

    @Test func unrecognisedWindowIsNeverMoved() {
        let hosts = FakeHosts()
        hosts.frames[2] = CGRect(x: 8, y: 47, width: 180, height: 180)
        let hider = makeHider(hosts: hosts, scheduler: ManualScheduler())

        #expect(hider.hide(2) == .notBanner, "A desktop widget has no banner subrole")
        #expect(hosts.moves.isEmpty)
    }

    @Test func notificationCenterPanelIsNeverHidden() {
        let hosts = FakeHosts()
        hosts.frames[3] = primary
        hosts.banners = [3]
        hosts.notificationCenterPanels = [3]
        let hider = makeHider(hosts: hosts, scheduler: ManualScheduler())

        #expect(hider.hide(3) == .excluded)
        #expect(hosts.moves.isEmpty)
    }

    @Test func bannerThatBecomesReadyLaterIsHiddenOnTheNextEvent() {
        let hosts = FakeHosts()
        hosts.frames[1] = bannerFrame
        let hider = makeHider(hosts: hosts, scheduler: ManualScheduler())

        #expect(hider.hide(1) == .notBanner)
        hosts.banners = [1]
        #expect(hider.hide(1) == .hidden, "Readiness on a later layout event must not wait for a settling pass")
    }

    @Test func failedWriteIsRetriedUntilVerified() {
        let hosts = FakeHosts()
        let scheduler = ManualScheduler()
        hosts.frames[1] = bannerFrame
        hosts.banners = [1]
        hosts.failingWrites = [1]
        let hider = makeHider(hosts: hosts, scheduler: scheduler)

        #expect(hider.hide(1) == .failed)
        #expect(!hider.isVerifiedHidden(1))
        #expect(scheduler.pendingDelays == [0.008])

        hosts.failingWrites = []
        scheduler.runNext()
        #expect(hider.isVerifiedHidden(1))
        #expect(isOffscreen(hosts.frames[1], [primary]))
    }

    @Test func successfulWriteThatDidNotMoveTheWindowIsNotRecordedAsHidden() {
        let hosts = FakeHosts()
        hosts.frames[1] = bannerFrame
        hosts.banners = [1]
        hosts.ignoredWrites = [1]
        let hider = makeHider(hosts: hosts, scheduler: ManualScheduler())

        #expect(hider.hide(1) == .failed)
        #expect(!hider.isVerifiedHidden(1))
    }

    @Test func nativeRepositionDuringEntranceIsHiddenAgain() {
        let hosts = FakeHosts()
        let scheduler = ManualScheduler()
        hosts.frames[1] = bannerFrame
        hosts.banners = [1]
        let hider = makeHider(hosts: hosts, scheduler: scheduler)

        #expect(hider.hide(1) == .hidden)
        hosts.frames[1] = bannerFrame
        scheduler.runNext()
        #expect(isOffscreen(hosts.frames[1], [primary]), "The arrival check must undo a native position reset")
        #expect(hosts.moves.count == 2)
    }

    @Test func checksAreBoundedWhenWritesKeepFailing() {
        let hosts = FakeHosts()
        let scheduler = ManualScheduler()
        hosts.frames[1] = bannerFrame
        hosts.banners = [1]
        hosts.failingWrites = [1]
        let hider = makeHider(hosts: hosts, scheduler: scheduler)

        hider.hide(1)
        scheduler.runAll()
        #expect(hosts.moves.count == 4, "One attempt plus one per configured check")
        #expect(!hider.hasPendingCheck(1))
        #expect(!hider.isVerifiedHidden(1))
    }

    @Test func reusedHiddenHostIsNotWrittenAgain() {
        let hosts = FakeHosts()
        let scheduler = ManualScheduler()
        hosts.frames[1] = bannerFrame
        hosts.banners = [1]
        let hider = makeHider(hosts: hosts, scheduler: scheduler)

        hider.hide(1)
        scheduler.runAll()
        #expect(hider.hide(1) == .alreadyHidden)
        #expect(hosts.moves.count == 1)
        #expect(!hider.hasPendingCheck(1), "An already-hidden host must not restart the arrival checks")
    }

    @Test func bannerEndingCancelsItsChecks() {
        let hosts = FakeHosts()
        let scheduler = ManualScheduler()
        hosts.frames[1] = bannerFrame
        hosts.banners = [1]
        hosts.failingWrites = [1]
        let hider = makeHider(hosts: hosts, scheduler: scheduler)

        hider.hide(1)
        hosts.banners = []
        scheduler.runNext()
        #expect(!hider.hasPendingCheck(1))
        #expect(hosts.moves.count == 1, "A host without a banner must not be moved by a pending check")
    }

    @Test func pausingCancelsChecksAndStopsHiding() {
        let hosts = FakeHosts()
        let scheduler = ManualScheduler()
        var active = true
        hosts.frames[1] = bannerFrame
        hosts.banners = [1]
        hosts.failingWrites = [1]
        let hider = makeHider(hosts: hosts, scheduler: scheduler, shouldHide: { active })

        hider.hide(1)
        active = false
        scheduler.runAll()
        #expect(hosts.moves.count == 1)
        #expect(hider.hide(1) == .excluded)

        active = true
        hider.hide(1)
        hider.cancelAll()
        #expect(scheduler.pendingDelays.isEmpty)
        #expect(!hider.hasPendingCheck(1))
    }

    @Test func forgettingAHostCancelsOnlyItsChecks() {
        let hosts = FakeHosts()
        let scheduler = ManualScheduler()
        hosts.frames = [1: bannerFrame, 2: bannerFrame]
        hosts.banners = [1, 2]
        hosts.failingWrites = [1, 2]
        let hider = makeHider(hosts: hosts, scheduler: scheduler)

        hider.hide(1)
        hider.hide(2)
        hider.forget(key: 1)
        #expect(!hider.hasPendingCheck(1))
        #expect(hider.hasPendingCheck(2), "Rapid arrivals are tracked per host")
    }

    @Test func parkingClearsADisplayArrangedAbove() {
        let hosts = FakeHosts()
        let displays = [primary, above]
        hosts.frames[1] = bannerFrame
        hosts.banners = [1]
        let hider = makeHider(hosts: hosts, scheduler: ManualScheduler(), displays: displays)

        #expect(hider.hide(1) == .hidden)
        #expect(isOffscreen(hosts.frames[1], displays))
    }

    @Test func windowOverlappingASecondDisplayIsNotConsideredHidden() {
        let layout = DisplayLayout { [primary, above] }
        #expect(!layout.isOutsideAllDisplays(CGRect(x: 10, y: -500, width: 372, height: 100)))
        #expect(layout.isOutsideAllDisplays(CGRect(x: 10, y: -9999, width: 372, height: 100)))
        #expect(!layout.isOutsideAllDisplays(CGRect(x: 1400, y: 900, width: 372, height: 100)),
                "Partially visible is visible")
    }

    @Test func parkWithoutRecognitionStillVerifies() {
        let hosts = FakeHosts()
        hosts.frames[4] = bannerFrame
        let hider = makeHider(hosts: hosts, scheduler: ManualScheduler())

        #expect(hider.park(4) == .hidden)
        #expect(hider.isVerifiedHidden(4))
    }

    @Test func traceOrdersStagesAndMeasuresNotchPresentation() {
        let clock = ManualClock()
        let trace = HandoffTrace { clock.now }
        let hosts = FakeHosts()
        hosts.frames[1] = bannerFrame
        hosts.banners = [1]
        let hider = makeHider(hosts: hosts, scheduler: ManualScheduler(), trace: trace)

        #expect(trace.notchPresented(key: 1) == nil, "No arrival is recorded before a verified hide")
        trace.eventReceived("AXLayoutChanged")
        clock.now += 0.002
        hider.hide(1)
        let record = try! #require(trace.lastRecord)
        #expect(record.event == "AXLayoutChanged")
        #expect(record.startedMs <= record.recognizedMs)
        #expect(record.recognizedMs <= record.requestedMs)
        #expect(record.verifiedMs.map { $0 >= record.requestedMs } == true)

        clock.now += 0.030
        let presented = try! #require(trace.notchPresented(key: 1))
        #expect(abs(presented - 32) < 0.001)
        #expect(trace.notchPresented(key: 1) == nil)
    }
}
