import AppKit

/// Notification lifetimes belong to our cards, not Notification Center's reused
/// host window. This model has no windows or timers, so arrival/expiry races can
/// be checked with a monotonic test clock.
struct NotchNotificationQueue {
    struct Countdown {
        private(set) var remaining: TimeInterval?
        private(set) var startedAt: TimeInterval?

        init(seconds: TimeInterval) { remaining = seconds > 0 ? seconds : nil }

        mutating func setRunning(_ running: Bool, at now: TimeInterval) {
            guard remaining != nil else { return }
            if running, startedAt == nil {
                startedAt = now
            } else if !running, let start = startedAt {
                remaining = max(0, remaining! - max(0, now - start))
                startedAt = nil
            }
        }

        func hasExpired(at now: TimeInterval) -> Bool {
            guard let remaining, let startedAt else { return false }
            return now - startedAt >= remaining
        }
    }

    struct Item {
        let id: UUID
        var sourceKey: CFHashCode?
        var content: BannerContent
        var displayID: CGDirectDisplayID
        let receivedAt: TimeInterval
        var countdown: Countdown
    }

    private(set) var items: [UUID: Item] = [:]
    private(set) var order: [UUID] = []
    private var sources: [CFHashCode: UUID] = [:]
    private(set) var duration: TimeInterval = 5
    private(set) var stackLimit = 3

    func id(for sourceKey: CFHashCode) -> UUID? { sources[sourceKey] }

    mutating func configure(seconds: TimeInterval, stackLimit: Int) {
        let seconds = seconds.isFinite ? max(0, seconds) : 5
        if duration != seconds {
            duration = seconds
            for id in order { items[id]?.countdown = Countdown(seconds: seconds) }
        }
        self.stackLimit = max(1, min(3, stackLimit))
    }

    @discardableResult
    mutating func receive(_ content: BannerContent, sourceKey: CFHashCode,
                          displayID: CGDirectDisplayID, at now: TimeInterval) -> UUID {
        if let id = sources[sourceKey], var item = items[id] {
            if content == item.content || Self.isInitialRefinement(content, of: item, at: now) {
                item.content = content
                item.displayID = displayID
                items[id] = item
                return id // AX layout churn must not reset the countdown or entrance.
            }
            sourceEnded(sourceKey)
        }
        let id = UUID()
        items[id] = Item(id: id, sourceKey: sourceKey, content: content,
                         displayID: displayID, receivedAt: now,
                         countdown: Countdown(seconds: duration))
        sources[sourceKey] = id
        order.append(id)
        return id
    }

    mutating func sourceEnded(_ key: CFHashCode) {
        guard let id = sources.removeValue(forKey: key) else { return }
        items[id]?.sourceKey = nil
    }

    @discardableResult
    mutating func remove(_ id: UUID) -> Item? {
        guard let item = items.removeValue(forKey: id) else { return nil }
        if let source = item.sourceKey, sources[source] == id { sources.removeValue(forKey: source) }
        order.removeAll { $0 == id }
        return item
    }

    mutating func move(_ id: UUID, to displayID: CGDirectDisplayID) {
        items[id]?.displayID = displayID
    }

    func visibleIDs(capacities: [CGDirectDisplayID: Int] = [:]) -> [UUID] {
        var counts: [CGDirectDisplayID: Int] = [:]
        return order.filter { id in
            guard let item = items[id] else { return false }
            let limit = min(stackLimit, max(1, capacities[item.displayID] ?? stackLimit))
            guard counts[item.displayID, default: 0] < limit else { return false }
            counts[item.displayID, default: 0] += 1
            return true
        }
    }

    mutating func updateCountdowns(visibleIDs: Set<UUID>, hoveredDisplays: Set<CGDirectDisplayID>,
                                  at now: TimeInterval) {
        for id in order {
            guard let item = items[id] else { continue }
            items[id]?.countdown.setRunning(visibleIDs.contains(id) && !hoveredDisplays.contains(item.displayID),
                                           at: now)
        }
    }

    func expiredIDs(at now: TimeInterval) -> [UUID] {
        order.filter { items[$0]?.countdown.hasExpired(at: now) == true }
    }

    private static func isInitialRefinement(_ content: BannerContent, of item: Item,
                                            at now: TimeInterval) -> Bool {
        // A just-created AX child can gain its subtitle/body over several passes.
        // Different nonempty text represents a new notification in the same host.
        let old = item.content
        guard now - item.receivedAt < 0.8, content.appName == old.appName else { return false }
        return (old.title.isEmpty || content.title == old.title)
            && (old.subtitle.isEmpty || content.subtitle == old.subtitle)
            && (old.body.isEmpty || content.body == old.body)
    }
}
