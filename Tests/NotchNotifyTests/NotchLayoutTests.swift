import Foundation
import Testing
@testable import NotchNotifyCore

@Suite("Notch layout")
struct NotchLayoutTests {
    @Test func meetsTheCameraAndReservesItsHeight() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let layout = NotchLayout(screenFrame: screen, safeTop: 32, notchCenterX: 756, notchWidth: 180)
        #expect(layout.frame.maxY == screen.maxY)
        #expect(layout.frame.midX == 756)
        #expect(layout.topInset == 32)
        #expect(layout.frame.height - layout.topInset == 106)
        #expect(layout.frame.width > 180)
    }

    @Test(arguments: [CGRect(x: -1920, y: 250, width: 1920, height: 1080),
                      CGRect(x: 1512, y: -1080, width: 1920, height: 1080),
                      CGRect(x: 0, y: 982, width: 2560, height: 1440)])
    func externalDisplaysUseGlobalCoordinates(_ screen: CGRect) {
        let layout = NotchLayout(screenFrame: screen, safeTop: 0, notchCenterX: nil, notchWidth: 0)
        #expect(layout.frame.maxY == screen.maxY)
        #expect(layout.frame.midX == screen.midX)
        #expect(screen.contains(layout.frame))
        #expect(layout.topInset == 12)
    }

    @Test func subsequentBannersDoNotOverlap() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let layouts = (0..<4).map {
            NotchLayout(screenFrame: screen, safeTop: 32, notchCenterX: 756,
                        notchWidth: 180, stackIndex: $0)
        }
        for index in 1..<layouts.count {
            #expect(layouts[index].frame.maxY < layouts[index - 1].frame.minY)
            #expect(layouts[index].topInset == 12)
        }
    }

    @Test func stackCapacityFitsSmallAndLargeScreens() {
        #expect(NotchLayout.stackCapacity(availableHeight: 200, safeTop: 32) == 1)
        #expect(NotchLayout.stackCapacity(availableHeight: 300, safeTop: 32) == 2)
        #expect(NotchLayout.stackCapacity(availableHeight: 900, safeTop: 32) == 3)
    }

    @Test func usesThePhysicalCameraCenter() {
        let layout = NotchLayout(screenFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                                 safeTop: 38, notchCenterX: 1000, notchWidth: 240)
        #expect(layout.frame.midX == 1000)
        #expect(layout.topInset == 38)
    }

    @Test func clampsToNarrowDisplay() {
        let screen = CGRect(x: 50, y: -500, width: 320, height: 480)
        let layout = NotchLayout(screenFrame: screen, safeTop: 0, notchCenterX: 100, notchWidth: 180)
        #expect(layout.frame.minX >= screen.minX + 12)
        #expect(layout.frame.maxX <= screen.maxX - 12)
    }

    @Test func collapsedShapeMatchesTheCameraCutout() {
        let layout = NotchLayout(screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                 safeTop: 32, notchCenterX: 756, notchWidth: 180)
        #expect(layout.collapsedSize == CGSize(width: 180, height: 32))
    }

    @Test func bounceCanvasKeepsTheBannerAtTheCamera() {
        let layout = NotchLayout(screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                 safeTop: 32, notchCenterX: 756, notchWidth: 180)
        #expect(layout.panelFrame.maxY == layout.frame.maxY)
        #expect(layout.panelFrame.midX == layout.frame.midX)
        #expect(layout.panelFrame.contains(layout.frame))
        #expect(layout.panelFrame.width > layout.frame.width)
        #expect(layout.panelFrame.height > layout.frame.height)
    }

    @Test func externalDisplayAnimationStartsInsideTheExpandedSurface() {
        let layout = NotchLayout(screenFrame: CGRect(x: -1920, y: 250, width: 1920, height: 1080),
                                 safeTop: 0, notchCenterX: nil, notchWidth: 0)
        #expect(layout.collapsedSize.width > 0)
        #expect(layout.collapsedSize.height > 0)
        #expect(layout.collapsedSize.width < layout.frame.width)
        #expect(layout.collapsedSize.height < layout.topInset)
    }

    @Test func stackedBannerDoesNotCollapseToADuplicateCamera() {
        let layout = NotchLayout(screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                 safeTop: 32, notchCenterX: 756, notchWidth: 180, stackIndex: 1)
        #expect(layout.collapsedSize.width < 180)
        #expect(layout.collapsedSize.height < layout.topInset)
    }

    @Test func nativePlacementStaysUnderCameraWithSideDockAndHiddenMenu() {
        let visible = CGRect(x: 80, y: 0, width: 1432, height: 982)
        let offsets = NotchLayout.nativeOffsets(visibleFrame: visible, safeTopY: 950, centerX: 756)
        let origin = NotificationPosition.topCenter.axOrigin(
            forWindowSize: CGSize(width: 372, height: 100), visibleFrame: visible,
            primaryHeight: 982, xOffset: offsets.x, yOffset: offsets.y)
        #expect(origin.x + 186 == 756)
        #expect(origin.y == 40) // 32 pt camera + the native 8 pt margin.
    }
}

@Suite("Notch preferences")
@MainActor
struct NotchPreferencesTests {
    @Test func isolatesDefaultsAndPersistsUserChoices() {
        let domain = "NotchNotifyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let first = NotchPreferences(defaults: defaults)
        #expect(first.isEnabled)
        #expect(first.usesNotchOverlay)
        #expect(first.displayTarget == .main)
        #expect(!first.followActiveScreen)
        #expect(first.autoDismissSeconds == 5)
        #expect(first.stackNotifications)
        #expect(first.notchAnimation == .expand)
        #expect(first.notchMotionMode == .system)
        first.style = .native
        first.isEnabled = false
        first.displayTarget = .pointer
        let restored = NotchPreferences(defaults: defaults)
        #expect(!restored.usesNotchOverlay)
        #expect(!restored.isActive)
        #expect(restored.followActiveScreen)
        #expect(restored.displayTarget == .pointer)
        #expect(!restored.shouldUseCustomBanner(for: "Mail"))
    }

    @Test func earlierPrototypeUsesNewMainDisplayDefault() {
        let domain = "NotchNotifyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(true, forKey: "followActiveScreen")
        let preferences = NotchPreferences(defaults: defaults)
        #expect(preferences.displayTarget == .main)
        #expect(!preferences.followActiveScreen)
    }

    @Test(arguments: NotchDisplayDuration.allCases)
    func durationAndStackPreferencesSurviveRelaunch(_ duration: NotchDisplayDuration) {
        let domain = "NotchNotifyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = NotchPreferences(defaults: defaults)
        preferences.displayDuration = duration
        preferences.stackNotifications = false
        let restored = NotchPreferences(defaults: defaults)
        #expect(restored.displayDuration == duration)
        #expect(restored.autoDismissSeconds == duration.seconds)
        #expect(restored.notchStackLimit == 1)
        restored.style = .native
        #expect(restored.autoDismissSeconds == 0, "Native appearance retains the system banner lifetime")
    }

    @Test func invalidDurationFallsBackToFiveSeconds() {
        let domain = "NotchNotifyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(-42, forKey: "displayDuration")
        #expect(NotchPreferences(defaults: defaults).displayDuration == .five)
    }

    @Test func explicitMainDisplayChoicePersists() {
        let domain = "NotchNotifyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = NotchPreferences(defaults: defaults)
        preferences.displayTarget = .builtIn
        #expect(NotchPreferences(defaults: defaults).displayTarget == .builtIn)
        preferences.displayTarget = .main
        let restored = NotchPreferences(defaults: defaults)
        #expect(restored.displayTarget == .main)
        #expect(!restored.followActiveScreen)
    }

    @Test(arguments: NotchAnimationStyle.allCases)
    func animationChoiceReachesTheEngineAndSurvivesRelaunch(_ animation: NotchAnimationStyle) {
        let domain = "NotchNotifyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = NotchPreferences(defaults: defaults)
        preferences.notchAnimation = animation
        preferences.style = .native
        let restored = NotchPreferences(defaults: defaults)
        restored.style = .notch
        let engineSettings: any NotificationSettingsProviding = restored
        #expect(engineSettings.notchAnimation == animation)
    }

    @Test func unknownAnimationFallsBackToTheExistingExpandStyle() {
        let domain = "NotchNotifyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set("removed-style", forKey: "notchAnimation")
        #expect(NotchPreferences(defaults: defaults).notchAnimation == .expand)
    }

    @Test func fullAnimationsSurviveRelaunchAndReachTheEngineWithReduceMotionEnabled() {
        let domain = "NotchNotifyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = NotchPreferences(defaults: defaults)
        #expect(preferences.notchMotionMode.reducesMotion(systemEnabled: true))
        preferences.notchMotionMode = .full
        let restored = NotchPreferences(defaults: defaults)
        let engineSettings: any NotificationSettingsProviding = restored
        #expect(engineSettings.notchMotionMode == .full)
        #expect(!engineSettings.notchMotionMode.reducesMotion(systemEnabled: true))
        #expect(!engineSettings.notchMotionMode.reducesMotion(systemEnabled: false))
        restored.notchMotionMode = .system
        #expect(restored.notchMotionMode.reducesMotion(systemEnabled: true))
        #expect(!restored.notchMotionMode.reducesMotion(systemEnabled: false))
    }

    @Test func unknownMotionPreferencePreservesTheSystemAccessibilitySetting() {
        let domain = "NotchNotifyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set("unknown", forKey: "notchMotionMode")
        let preferences = NotchPreferences(defaults: defaults)
        #expect(preferences.notchMotionMode == .system)
        #expect(preferences.notchMotionMode.reducesMotion(systemEnabled: true))
    }

    @Test(arguments: NotchAnimationStyle.allCases)
    func dismissingDuringEntranceCancelsTheContentReveal(_ animation: NotchAnimationStyle) async throws {
        let controller = NotchAnimationController(animation: animation)
        controller.present(reduceMotion: false)
        controller.dismiss {}
        try await Task.sleep(for: animation.contentRevealDelay + .milliseconds(50))
        #expect(!controller.expanded)
        #expect(!controller.contentVisible)
    }
}

@Suite("Notification display selection")
struct NotchDisplaySelectionTests {
    private struct Display: Equatable {
        let name: String
        let builtIn: Bool
    }
    private let external = Display(name: "External primary", builtIn: false)
    private let laptop = Display(name: "Laptop", builtIn: true)

    @Test func mainDisplayWinsOverAttachedMacBook() {
        let selected = NotchDisplayTarget.main.resolve(from: [external, laptop], isBuiltIn: { $0.builtIn })
        #expect(selected == external)
    }

    @Test func builtInRemainsAvailableAsAnExplicitChoice() {
        let selected = NotchDisplayTarget.builtIn.resolve(from: [external, laptop], isBuiltIn: { $0.builtIn })
        #expect(selected == laptop)
    }

    @Test func closedOrDisconnectedLaptopFallsBackToPrimary() {
        let selected = NotchDisplayTarget.builtIn.resolve(from: [external], isBuiltIn: { $0.builtIn })
        #expect(selected == external)
    }

    @Test func changingThePrimaryDisplayTakesEffectWithoutRestart() {
        let policy = NotchDisplayTarget.main
        #expect(policy.resolve(from: [external, laptop], isBuiltIn: { $0.builtIn }) == external)
        #expect(policy.resolve(from: [laptop, external], isBuiltIn: { $0.builtIn }) == laptop)
    }

    @Test func pointerModeDoesNotForceAFixedScreen() {
        let selected = NotchDisplayTarget.pointer.resolve(from: [external, laptop], isBuiltIn: { $0.builtIn })
        #expect(selected == nil)
    }

    @Test func noScreensIsHandledDuringDisplayReconfiguration() {
        for policy in NotchDisplayTarget.allCases {
            #expect(policy.resolve(from: [Display](), isBuiltIn: { $0.builtIn }) == nil)
        }
    }
}
