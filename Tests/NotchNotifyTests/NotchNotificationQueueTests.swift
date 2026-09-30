import Foundation
import Testing
@testable import NotchNotifyCore

@Suite("Notch notification lifetimes")
struct NotchNotificationQueueTests {
    private func content(_ title: String = "Message", body: String = "Hello") -> BannerContent {
        BannerContent(appName: "Messages", title: title, body: body, appIcon: nil)
    }

    @Test func reusedNativeHostStacksSeparateNotifications() {
        var queue = NotchNotificationQueue()
        let first = queue.receive(content("First"), sourceKey: 42, displayID: 1, at: 0)
        let second = queue.receive(content("Second"), sourceKey: 42, displayID: 1, at: 0.1)
        #expect(first != second)
        #expect(queue.visibleIDs() == [first, second])
        #expect(queue.items[first]?.sourceKey == nil)
        #expect(queue.id(for: 42) == second)
        queue.remove(first)
        #expect(queue.id(for: 42) == second, "An older card must not dismiss a newer banner's source")
    }

    @Test func initialRefinementAndRepeatedLayoutsKeepTheOriginalDeadline() {
        var queue = NotchNotificationQueue()
        let id = queue.receive(content(body: ""), sourceKey: 1, displayID: 1, at: 0)
        queue.updateCountdowns(visibleIDs: [id], hoveredDisplays: [], at: 0)
        #expect(queue.receive(content(), sourceKey: 1, displayID: 1, at: 0.1) == id)
        #expect(queue.receive(content(), sourceKey: 1, displayID: 1, at: 4.9) == id)
        #expect(queue.expiredIDs(at: 5) == [id])
    }

    @Test func differentBodiesWithTheSameTitleAreSeparateCards() {
        var queue = NotchNotificationQueue()
        let first = queue.receive(content(body: "First message"), sourceKey: 1, displayID: 1, at: 0)
        let second = queue.receive(content(body: "Another message"), sourceKey: 1, displayID: 1, at: 0.1)
        #expect(first != second)
        #expect(queue.items.count == 2)
    }

    @Test func nativeExpiryDoesNotShortenOurLifetimeAndAllowsANewIdenticalArrival() {
        var queue = NotchNotificationQueue()
        let first = queue.receive(content(), sourceKey: 42, displayID: 1, at: 0)
        queue.updateCountdowns(visibleIDs: [first], hoveredDisplays: [], at: 0)
        queue.sourceEnded(42)
        #expect(queue.items[first] != nil)
        #expect(queue.items[first]?.sourceKey == nil)
        let second = queue.receive(content(), sourceKey: 42, displayID: 1, at: 2)
        #expect(first != second)
        #expect(queue.expiredIDs(at: 4).isEmpty)
        #expect(queue.expiredIDs(at: 5) == [first])
    }

    @Test func hoveringPausesTheEntireStackOnlyOnItsDisplay() {
        var queue = NotchNotificationQueue()
        let first = queue.receive(content("First"), sourceKey: 1, displayID: 1, at: 0)
        let second = queue.receive(content("Second"), sourceKey: 2, displayID: 1, at: 0)
        let other = queue.receive(content("Other screen"), sourceKey: 3, displayID: 2, at: 0)
        let visible = Set(queue.visibleIDs())
        queue.updateCountdowns(visibleIDs: visible, hoveredDisplays: [], at: 0)
        queue.updateCountdowns(visibleIDs: visible, hoveredDisplays: [1], at: 2)
        #expect(queue.expiredIDs(at: 100) == [other])
        queue.remove(other)
        queue.updateCountdowns(visibleIDs: [first, second], hoveredDisplays: [], at: 100)
        #expect(queue.expiredIDs(at: 102.9).isEmpty)
        #expect(queue.expiredIDs(at: 103) == [first, second])
    }

    @Test func queuedCardsGetTheirFullDurationAfterPromotion() {
        var queue = NotchNotificationQueue()
        let ids = (1...4).map { queue.receive(content("\($0)"), sourceKey: UInt($0), displayID: 1, at: 0) }
        queue.updateCountdowns(visibleIDs: Set(queue.visibleIDs()), hoveredDisplays: [], at: 0)
        #expect(queue.visibleIDs() == Array(ids.prefix(3)))
        #expect(queue.expiredIDs(at: 7) == Array(ids.prefix(3)))
        for id in ids.prefix(3) { queue.remove(id) }
        queue.updateCountdowns(visibleIDs: Set(queue.visibleIDs()), hoveredDisplays: [], at: 7)
        #expect(queue.expiredIDs(at: 11.9).isEmpty)
        #expect(queue.expiredIDs(at: 12) == [ids[3]])
    }

    @Test func untilDismissedSurvivesNativeExpiryAndLongWaits() {
        var queue = NotchNotificationQueue()
        queue.configure(seconds: 0, stackLimit: 3)
        let id = queue.receive(content(), sourceKey: 1, displayID: 1, at: 0)
        queue.updateCountdowns(visibleIDs: [id], hoveredDisplays: [], at: 0)
        queue.sourceEnded(1)
        #expect(queue.expiredIDs(at: 86_400).isEmpty)
        #expect(queue.visibleIDs() == [id])
        queue.remove(id)
        #expect(queue.order.isEmpty)
    }

    @Test func changingDurationWhileHoveredWaitsForPointerExit() {
        var queue = NotchNotificationQueue()
        let id = queue.receive(content(), sourceKey: 1, displayID: 1, at: 0)
        queue.updateCountdowns(visibleIDs: [id], hoveredDisplays: [], at: 0)
        queue.updateCountdowns(visibleIDs: [id], hoveredDisplays: [1], at: 2)
        queue.configure(seconds: 10, stackLimit: 3)
        queue.updateCountdowns(visibleIDs: [id], hoveredDisplays: [1], at: 3)
        #expect(queue.expiredIDs(at: 100).isEmpty)
        queue.updateCountdowns(visibleIDs: [id], hoveredDisplays: [], at: 100)
        #expect(queue.expiredIDs(at: 109.9).isEmpty)
        #expect(queue.expiredIDs(at: 110) == [id])
    }

    @Test func unrelatedSettingsDoNotRestartTimers() {
        var queue = NotchNotificationQueue()
        let id = queue.receive(content(), sourceKey: 1, displayID: 1, at: 0)
        queue.updateCountdowns(visibleIDs: [id], hoveredDisplays: [], at: 0)
        queue.configure(seconds: 5, stackLimit: 1)
        #expect(queue.expiredIDs(at: 5) == [id])
    }

    @Test func capacitiesAndSingleCardModeKeepOverflowQueued() {
        var queue = NotchNotificationQueue()
        let ids = (1...4).map { queue.receive(content("\($0)"), sourceKey: UInt($0), displayID: 1, at: 0) }
        let other = queue.receive(content("Other"), sourceKey: 5, displayID: 2, at: 0)
        #expect(queue.visibleIDs(capacities: [1: 2]) == [ids[0], ids[1], other])
        queue.configure(seconds: 5, stackLimit: 1)
        #expect(queue.visibleIDs() == [ids[0], other])
        queue.move(other, to: 1)
        #expect(queue.visibleIDs() == [ids[0]])
        #expect(queue.items.count == 5)
    }
}
