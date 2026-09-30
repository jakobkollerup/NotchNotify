import AppKit
import Combine
import SwiftUI
import UserNotifications

private enum NotchSettingsLayout {
    static let size = NSSize(width: 500, height: 760)
}

@MainActor
package final class NotchApplicationDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let preferences = NotchPreferences()
    private var repositioner: NotificationRepositioner?
    private let previews = NotchBannerManager()
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var preferenceChanges: AnyCancellable?
    private let notificationDelegate = NotchNotificationDelegate()
    private let launchAtLogin = LaunchAtLogin()

    package override init() { super.init() }

    package func applicationDidFinishLaunching(_ notification: Notification) {
        if let icon = NotchBrand.appIcon { NSApp.applicationIconImage = icon }
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            NSApp.terminate(nil)
            return
        }
        let engine = NotificationRepositioner()
        repositioner = engine
        preferenceChanges = preferences.settingsDidChange.sink { [weak self] in
            guard let self else { return }
            self.previews.configure(seconds: self.preferences.displayDuration.seconds,
                stackLimit: self.preferences.notchStackLimit, screen: self.preferences.resolvedTargetScreen(),
                motionMode: self.preferences.notchMotionMode)
        }
        if !CommandLine.arguments.contains("--smoke-test") { engine.bind(to: preferences) }
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().delegate = notificationDelegate
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem?.button?.image = NotchBrand.menuBarIcon ?? NSImage(systemSymbolName: "rectangle.stack.fill",
                                            accessibilityDescription: "NotchNotify")
        let menu = NSMenu()
        menu.delegate = self
        statusItem?.menu = menu
        if CommandLine.arguments.contains("--smoke-test") {
            guard NotchBrand.appIcon != nil, NotchBrand.logo != nil, NotchBrand.menuBarIcon?.isTemplate == true else {
                fputs("Approved brand assets are missing from the bundle.\n", stderr)
                exit(1)
            }
            guard NSScreen.main != nil else {
                fputs("No desktop display is accessible to the smoke test.\n", stderr)
                exit(1)
            }
            openSettings()
            for (index, animation) in NotchAnimationStyle.allCases.enumerated() {
                let start = Double(index) * 1.65
                DispatchQueue.main.asyncAfter(deadline: .now() + start) { [self] in
                    showPreview(animation: animation, restart: true)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + start + 0.04) { [self] in
                    showPreview(animation: animation, restart: false)
                    guard previews.hasActive, !previews.hasClosingPanels else {
                        fputs("Updating a preview restarted its entrance animation.\n", stderr)
                        exit(1)
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + start + 0.80) { [self] in previews.dismissAll() }
                DispatchQueue.main.asyncAfter(deadline: .now() + start + 1.50) { [self] in
                    guard !previews.hasActive, !previews.hasClosingPanels else {
                        fputs("Synthetic preview did not finish dismissing.\n", stderr)
                        exit(1)
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(NotchAnimationStyle.allCases.count) * 1.65) {
                print("NotchNotify launched; settings UI and preview created successfully; animated replacement and dismissal completed for all five styles.")
                NSApp.terminate(nil)
            }
        } else {
            openSettings()
        }
    }

    package func applicationWillTerminate(_ notification: Notification) {
        repositioner?.stopAndRestore()
        previews.dismissAll()
    }

    package func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return true
    }

    package func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        let status = repositioner?.hasAccessibilityPermission == true
            ? (preferences.isEnabled ? "NotchNotify is running" : "NotchNotify is paused")
            : "Accessibility access needed"
        menu.addItem(withTitle: status, action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        addItem("About NotchNotify…", action: #selector(showAbout), to: menu)
        addItem("Settings…", action: #selector(openSettings), to: menu, key: ",")
        addItem("Preview notch", action: #selector(preview), to: menu)
        addItem("Preview stack", action: #selector(previewStack), to: menu)
        addItem(preferences.isEnabled ? "Pause" : "Resume", action: #selector(toggleEnabled), to: menu)
        launchAtLogin.refresh()
        addItem("Open at Login", action: #selector(toggleLaunchAtLogin), to: menu)
            .state = launchAtLogin.isEnabled ? .on : .off
        menu.addItem(.separator())
        addItem("Quit NotchNotify", action: #selector(quit), to: menu, key: "q")
    }

    @discardableResult
    private func addItem(_ title: String, action: Selector, to menu: NSMenu, key: String = "") -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func toggleEnabled() { preferences.isEnabled.toggle() }

    @objc private func toggleLaunchAtLogin() {
        launchAtLogin.setEnabled(!launchAtLogin.isEnabled)
        guard let error = launchAtLogin.lastError else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Could not change Open at Login"
        alert.informativeText = "\(error)\n\nMove NotchNotify to the Applications folder and try again."
        alert.runModal()
    }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc private func openSettings() {
        if settingsWindow == nil, let repositioner {
            let view = NotchSettingsView(preferences: preferences, engine: repositioner,
                requestAccess: { [weak self] in self?.requestAccess() },
                preview: { [weak self] in self?.preview() },
                previewStack: { [weak self] in self?.previewStack() },
                sendTest: { [weak self] in self?.sendTest() })
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "NotchNotify"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.setContentSize(NotchSettingsLayout.size)
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func requestAccess() {
        repositioner?.requestAccessibilityPermission()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func preview() {
        showPreview(animation: preferences.notchAnimation, restart: true)
    }

    private func showPreview(animation: NotchAnimationStyle, restart: Bool) {
        let screen = preferences.resolvedTargetScreen()
            ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.screens.first
        guard let screen else { return }
        if restart { previews.dismissAllImmediately() }
        previews.show(content: Self.previewContent, screen: screen,
                      autoDismissSeconds: preferences.displayDuration.seconds,
                      animation: animation, motionMode: preferences.notchMotionMode,
                      stackLimit: preferences.notchStackLimit,
                      onOpen: { [weak self] in self?.openSettings() }, onDismiss: nil,
                      key: CFHashCode.max)
    }

    @objc private func previewStack() {
        let screen = preferences.resolvedTargetScreen()
            ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.screens.first
        guard let screen else { return }
        previews.dismissAllImmediately()
        let examples = [
            ("Hover to keep these open", "The countdown pauses while your pointer is over the stack."),
            ("Room for another notification", "Each notification has its own card and close button."),
            ("Extras wait their turn", "Close a card to make room for the next notification."),
            ("Here is the next notification", "Queued cards get their full display time when they appear.")
        ]
        for (title, body) in examples {
            previews.show(content: BannerContent(appName: "NotchNotify", title: title, body: body, appIcon: NotchBrand.appIcon),
                screen: screen, autoDismissSeconds: preferences.displayDuration.seconds,
                animation: preferences.notchAnimation, motionMode: preferences.notchMotionMode,
                stackLimit: preferences.notchStackLimit,
                onOpen: { [weak self] in self?.openSettings() }, onDismiss: nil, key: CFHashCode.max)
        }
    }

    private func sendTest() {
        // Request notification permission only when the user explicitly sends a test.
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            guard granted else {
                Task { @MainActor in
                    let alert = NSAlert()
                    alert.messageText = "Allow test notifications"
                    alert.informativeText = error?.localizedDescription
                        ?? "Enable notifications for NotchNotify in System Settings. Preview notch works without notification permission."
                    alert.runModal()
                }
                return
            }
            let content = UNMutableNotificationContent()
            content.title = "A little closer to the center"
            content.body = "This is a real macOS notification, delivered through Notification Center."
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false))
            UNUserNotificationCenter.current().add(request) { error in
                guard let error else { return }
                Task { @MainActor in
                    let alert = NSAlert()
                    alert.messageText = "Could not send the test notification"
                    alert.informativeText = error.localizedDescription
                    alert.runModal()
                }
            }
        }
    }

    static var previewContent: BannerContent {
        BannerContent(appName: "NotchNotify", title: "Right where you’re looking.",
                      body: "Your notifications, tucked into the notch.\nClick to open. Dismiss to get back to work.",
                      appIcon: NotchBrand.appIcon)
    }

    /// Renders synthetic content only. Never attaches an AX observer or reads notifications.
    package static func renderPreview() throws {
        let index = CommandLine.arguments.firstIndex(of: "--render-preview")!
        let directory = CommandLine.arguments.dropFirst(index + 1).first ?? "build/previews"
        let destination = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let layout = NotchLayout(screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                 safeTop: 32, notchCenterX: 756, notchWidth: 180)
        let view = NotchBannerView(content: previewContent, layout: layout,
                                   controller: NotchAnimationController(), animated: false,
                                   onDismiss: {}, onOpen: {})
        try savePreview(view, to: destination.appendingPathComponent("notch-preview.png"))
        let domain = "NotchNotify.ReadOnlyPreview"
        let settings = NotchSettingsContent(
            preferences: NotchPreferences(defaults: UserDefaults(suiteName: domain)!),
            hasAccessibilityPermission: false, isObserving: false,
            requestAccess: {}, preview: {}, previewStack: {}, sendTest: {})
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .light)
        try saveHostedPreview(settings, to: destination.appendingPathComponent("settings-preview.png"))
        if let icon = NotchBrand.appIcon, let logo = NotchBrand.logo, let menu = NotchBrand.menuBarIcon {
            let assets = VStack(spacing: 24) {
                Image(nsImage: icon).resizable().scaledToFit().frame(width: 160, height: 160)
                Image(nsImage: logo).resizable().scaledToFit().frame(width: 400, height: 270)
                HStack(spacing: 30) {
                    Image(nsImage: menu).renderingMode(.template).foregroundStyle(.black)
                        .padding(16).background(.white)
                    Image(nsImage: menu).renderingMode(.template).foregroundStyle(.white)
                        .padding(16).background(.black)
                }
            }.padding(30).background(.white)
            try savePreview(assets, to: destination.appendingPathComponent("brand-preview.png"))
        }
    }

    // ImageRenderer omits AppKit-backed controls such as segmented pickers.
    // Cache the hosted view itself to include the real native controls.
    private static func saveHostedPreview<V: View>(_ view: V, to url: URL) throws {
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: NotchSettingsLayout.size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            throw NSError(domain: "NotchNotify", code: 2)
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "NotchNotify", code: 3)
        }
        try data.write(to: url)
        print(url.path)
        window.orderOut(nil)
    }

    private static func savePreview<V: View>(_ view: V, to url: URL) throws {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.cgImage,
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw NSError(domain: "NotchNotify", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Could not render the banner"])
        }
        try data.write(to: url)
        print(url.path)
    }
}

private final class NotchNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}

private struct NotchSettingsView: View {
    @ObservedObject var preferences: NotchPreferences
    @ObservedObject var engine: NotificationRepositioner
    let requestAccess: () -> Void
    let preview: () -> Void
    let previewStack: () -> Void
    let sendTest: () -> Void

    var body: some View {
        NotchSettingsContent(preferences: preferences,
                             hasAccessibilityPermission: engine.hasAccessibilityPermission,
                             isObserving: engine.isObserving,
                             requestAccess: requestAccess, preview: preview, previewStack: previewStack,
                             sendTest: sendTest)
    }
}

private struct NotchSettingsContent: View {
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @ObservedObject var preferences: NotchPreferences
    let hasAccessibilityPermission: Bool
    let isObserving: Bool
    let requestAccess: () -> Void
    let preview: () -> Void
    let previewStack: () -> Void
    let sendTest: () -> Void

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                if let icon = NotchBrand.appIcon {
                    Image(nsImage: icon).resizable().scaledToFit().frame(width: 64, height: 64)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("NotchNotify").font(.system(size: 25, weight: .bold))
                    Text("A quieter place for your notifications.").foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 8) {
                Circle().fill(statusColor).frame(width: 7, height: 7)
                Text(status).font(.system(size: 12, weight: .medium))
                Spacer()
                if !hasAccessibilityPermission {
                    Button("Grant access", action: requestAccess).buttonStyle(.borderedProminent)
                }
            }
            .padding(14).background(.quaternary, in: RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 16) {
                Toggle("Move notifications to the top center", isOn: $preferences.isEnabled)
                Picker("Appearance", selection: $preferences.style) {
                    ForEach(NotchPreferences.Style.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)
                Text(preferences.style == .notch
                     ? "A black banner extends from the top center of the display. Click to open; × hides the banner."
                     : "Keep the original macOS banner and its actions, centered at the top of the display.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(height: 40, alignment: .topLeading)
                Picker("Show on", selection: $preferences.displayTarget) {
                    ForEach(NotchDisplayTarget.allCases) { Text($0.label).tag($0) }
                }
                Text(preferences.displayTarget.explanation)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 7) {
                    Picker("Motion", selection: $preferences.notchMotionMode) {
                        ForEach(NotchMotionMode.allCases) { Text($0.label).tag($0) }
                    }
                    .disabled(preferences.style != .notch)
                    .onChange(of: preferences.notchMotionMode) { _, _ in
                        if preferences.style == .notch { preview() }
                    }
                    Picker("Animation", selection: $preferences.notchAnimation) {
                        ForEach(NotchAnimationStyle.allCases) { Text($0.label).tag($0) }
                    }
                    .disabled(preferences.style != .notch)
                    .onChange(of: preferences.notchAnimation) { _, _ in
                        if preferences.style == .notch { preview() }
                    }
                    Text(animationExplanation)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Show for", selection: $preferences.displayDuration) {
                        ForEach(NotchDisplayDuration.allCases) { Text($0.label).tag($0) }
                    }
                    Toggle("Stack up to three notifications", isOn: $preferences.stackNotifications)
                    Text("Hover the notch or any card to pause the countdown. Extra notifications wait their turn.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .disabled(preferences.style != .notch)
            }
            Divider()
            HStack {
                Button("Preview notch", action: preview)
                Button("Preview stack", action: previewStack)
                Button("Send test notification", action: sendTest)
                    .disabled(!hasAccessibilityPermission || !preferences.isEnabled)
            }
            Text("Choosing an animation previews it instantly. Full animations applies only to NotchNotify; Follow macOS respects Reduce Motion.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            HStack {
                Text("NotchNotify · \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0")")
                Spacer()
                Button("Licenses", action: NotchBrand.openLicenses).buttonStyle(.plain)
            }.font(.system(size: 10)).foregroundStyle(.tertiary)
        }
        .padding(28)
        }
        .frame(width: NotchSettingsLayout.size.width, height: NotchSettingsLayout.size.height)
    }

    private var animationExplanation: String {
        if preferences.style != .notch { return "Native appearance uses the macOS banner animation." }
        if preferences.notchMotionMode.reducesMotion(systemEnabled: systemReduceMotion) {
            return "macOS Reduce Motion is on, so all styles use a fade. Choose Full animations to see each style."
        }
        return preferences.notchAnimation.explanation
    }

    private var status: String {
        if !hasAccessibilityPermission { return "Accessibility access needed" }
        if !preferences.isEnabled { return "Paused" }
        return isObserving ? "Ready for notifications" : "Waiting for Notification Center"
    }
    private var statusColor: Color {
        hasAccessibilityPermission && isObserving && preferences.isEnabled ? .green : .orange
    }
}
