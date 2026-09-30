@preconcurrency import ApplicationServices

@MainActor
final class AppNameResolver {
    private static let bannerSubroles: Set<String> = [
        "AXNotificationCenterBanner",
        "AXNotificationCenterBannerStack",
        "AXNotificationCenterAlert",
        "AXNotificationCenterAlertStack",
    ]

    private var cache: [CFHashCode: String] = [:]
    private var bannerCache: [CFHashCode: AXUIElement] = [:]

    func appName(for window: AXUIElement) -> String? {
        let key = CFHash(window)
        if let cached = cache[key] { return cached }
        let el = findBannerElement(in: window) ?? window
        guard let name = nameFromElement(el) else { return nil }
        cache[key] = name
        return name
    }

    func invalidate(key: CFHashCode) {
        cache.removeValue(forKey: key)
        bannerCache.removeValue(forKey: key)
    }

    func hasCachedBanner(in window: AXUIElement) -> Bool {
        bannerCache[CFHash(window)] != nil
    }

    /// Revalidates a previously found banner with one subrole read instead of
    /// walking the host's tree again. Only the immediate hide path uses this:
    /// a stale hit there hides a banner host, which is what that path does anyway.
    func validatedBannerElement(in window: AXUIElement) -> AXUIElement? {
        let key = CFHash(window)
        if let cached = bannerCache[key], isBanner(cached) { return cached }
        guard let found = findBannerElement(in: window) else {
            bannerCache.removeValue(forKey: key)
            return nil
        }
        bannerCache[key] = found
        return found
    }

    func invalidateAll() {
        cache.removeAll()
    }

    func invalidateBanners() {
        bannerCache.removeAll()
    }

    func findBannerElement(in el: AXUIElement, depth: Int = 0) -> AXUIElement? {
        guard depth < 7 else { return nil }
        if isBanner(el) { return el }
        for child in el.children() {
            if let found = findBannerElement(in: child, depth: depth + 1) { return found }
        }
        return nil
    }

    private func isBanner(_ el: AXUIElement) -> Bool {
        el.stringAttribute(kAXSubroleAttribute as String).map(Self.bannerSubroles.contains) ?? false
    }

    private func nameFromElement(_ el: AXUIElement) -> String? {
        guard let str = el.stringAttribute("AXAttributedDescription"),
              let first = str.components(separatedBy: ", ").first else { return nil }
        let cleaned = cleanAXString(first)
        return cleaned.isEmpty ? nil : cleaned
    }
}
