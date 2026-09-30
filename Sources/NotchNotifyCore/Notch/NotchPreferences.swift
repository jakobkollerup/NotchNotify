import AppKit
import Combine
import SwiftUI

enum NotchDisplayDuration: Int, CaseIterable, Identifiable {
    case three = 3, five = 5, eight = 8, ten = 10, fifteen = 15, thirty = 30
    case untilDismissed = 0

    var id: Int { rawValue }
    var seconds: Double { Double(rawValue) }
    var label: String { self == .untilDismissed ? "Until dismissed" : "\(rawValue) seconds" }
}

enum NotchDisplayTarget: String, CaseIterable, Identifiable {
    case main
    case builtIn
    case pointer

    var id: String { rawValue }
    var label: String {
        switch self {
        case .main: return "Main display"
        case .builtIn: return "Built-in display"
        case .pointer: return "Display with pointer"
        }
    }
    var explanation: String {
        switch self {
        case .main: return "Uses the main display selected in macOS Displays settings."
        case .builtIn: return "Uses the built-in display, or the main display when unavailable."
        case .pointer: return "Displays notifications on the screen under your pointer."
        }
    }

    /// AppKit orders the current primary display first. Resolve afresh so a
    /// primary-display change or a disconnected laptop panel takes effect.
    func resolve<Screen>(from screens: [Screen], isBuiltIn: (Screen) -> Bool) -> Screen? {
        switch self {
        case .main: return screens.first
        case .builtIn: return screens.first(where: isBuiltIn) ?? screens.first
        case .pointer: return nil // Let the engine select the pointer's screen.
        }
    }
}

/// A dedicated preferences domain and a compact UI for NotchNotify.
@MainActor
final class NotchPreferences: ObservableObject, NotificationSettingsProviding {
    enum Style: String, CaseIterable, Identifiable {
        case notch = "Notch"
        case native = "Native"
        var id: String { rawValue }
    }

    private let defaults: UserDefaults
    @Published var isEnabled: Bool { didSet { defaults.set(isEnabled, forKey: "enabled") } }
    @Published var style: Style { didSet { defaults.set(style.rawValue, forKey: "style") } }
    @Published var displayTarget: NotchDisplayTarget {
        didSet { defaults.set(displayTarget.rawValue, forKey: "displayTarget") }
    }
    @Published var notchAnimation: NotchAnimationStyle {
        didSet { defaults.set(notchAnimation.rawValue, forKey: "notchAnimation") }
    }
    @Published var notchMotionMode: NotchMotionMode {
        didSet { defaults.set(notchMotionMode.rawValue, forKey: "notchMotionMode") }
    }
    @Published var displayDuration: NotchDisplayDuration {
        didSet { defaults.set(displayDuration.rawValue, forKey: "displayDuration") }
    }
    @Published var stackNotifications: Bool {
        didSet { defaults.set(stackNotifications, forKey: "stackNotifications") }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.object(forKey: "enabled") as? Bool ?? true
        style = defaults.string(forKey: "style").flatMap(Style.init(rawValue:)) ?? .notch
        displayTarget = defaults.string(forKey: "displayTarget")
            .flatMap(NotchDisplayTarget.init(rawValue:)) ?? .main
        notchAnimation = defaults.string(forKey: "notchAnimation")
            .flatMap(NotchAnimationStyle.init(rawValue:)) ?? .expand
        notchMotionMode = defaults.string(forKey: "notchMotionMode")
            .flatMap(NotchMotionMode.init(rawValue:)) ?? .system
        displayDuration = (defaults.object(forKey: "displayDuration") as? Int)
            .flatMap(NotchDisplayDuration.init(rawValue:)) ?? .five
        stackNotifications = defaults.object(forKey: "stackNotifications") as? Bool ?? true
    }

    var isActive: Bool { isEnabled }
    var followActiveScreen: Bool { displayTarget == .pointer }
    var usesNotchOverlay: Bool { style == .notch }
    var pauseWhileStreaming: Bool { true }
    var avoidNCPanel: Bool { true }
    var protectDesktopWidgets: Bool { true }
    var pauseDuringFocus: Bool { false } // Only notifications macOS actually displays are observed.
    var holdWhileAsleep: Bool { false }
    var redactBannerContent: Bool { false }
    var targetDisplayID: CGDirectDisplayID { 0 }
    var autoDismissSeconds: Double { usesNotchOverlay ? displayDuration.seconds : 0 }
    var notchStackLimit: Int { stackNotifications ? 3 : 1 }
    var bannerScale: Double { 1 }
    var bannerColor: Color { .clear }
    var effectiveBannerTextColor: Color? { nil }
    var bannerAnimation: BannerAnimation { .default }

    var settingsDidChange: AnyPublisher<Void, Never> {
        objectWillChange.receive(on: DispatchQueue.main).eraseToAnyPublisher()
    }

    func resolvedTargetScreen() -> NSScreen? {
        // NSScreen.main follows keyboard focus; screens.first is the primary
        // display selected by the user in macOS, even when an external monitor.
        displayTarget.resolve(from: NSScreen.screens) { CGDisplayIsBuiltin($0.displayID) != 0 }
    }
    func resolvedTargetScreen(for appName: String?) -> NSScreen? { nil }
    func resolvedTargetScreen(forGroupID groupID: UUID?) -> NSScreen? { nil }
    func placement(for appName: String?, screen: NSScreen) -> ScreenPlacement {
        // Native banners stay below the physical camera even with an auto-hidden menu bar.
        let safeTop = screen.frame.maxY - screen.safeAreaInsets.top
        let offsets = NotchLayout.nativeOffsets(visibleFrame: screen.visibleFrame,
            safeTopY: safeTop, centerX: NotchLayout(screen: screen).frame.midX)
        return ScreenPlacement(position: .topCenter, xOffset: offsets.x, yOffset: offsets.y)
    }
    func placement(forGroupID groupID: UUID?, screen: NSScreen) -> ScreenPlacement {
        placement(for: nil, screen: screen)
    }
    func targetDisplay(for appName: String?) -> CGDirectDisplayID { 0 }
    func targetDisplay(forGroupID groupID: UUID?) -> CGDirectDisplayID { 0 }
    func recordAppName(_ name: String) {} // No notification/app history is persisted.
    func effectiveBannerColor(for appName: String?) -> Color { .clear }
    func effectiveBannerColor(forGroupID groupID: UUID?) -> Color { .clear }
    func effectiveBannerScale(for appName: String?) -> Double { 1 }
    func effectiveBannerScale(forGroupID groupID: UUID?) -> Double { 1 }
    func effectiveBannerMode(for appName: String?) -> BannerMode? { usesNotchOverlay ? .custom : .native }
    func effectiveBannerMode(forGroupID groupID: UUID?) -> BannerMode? { effectiveBannerMode(for: nil) }
    func shouldUseCustomBanner(for appName: String?) -> Bool { usesNotchOverlay }
    func shouldUseCustomBanner(forGroupID groupID: UUID?) -> Bool { usesNotchOverlay }
    func effectiveBannerAnimation(for appName: String?) -> BannerAnimation { .default }
    func effectiveBannerAnimation(forGroupID groupID: UUID?) -> BannerAnimation { .default }
}
