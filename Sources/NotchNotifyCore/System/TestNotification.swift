import AppKit
import UserNotifications


package enum TestNotification {
    /// Sends the test banner and returns its unique title, so the repositioner can tell
    /// this specific banner apart from real notifications that arrive at the same time.
    ///
    /// Prefers `UNUserNotificationCenter` (no subprocess) when the user has granted
    /// notification permission — requested once, silently, at first launch. Falls back
    /// to `osascript`'s `display notification`, which posts under a distinct identity
    /// that doesn't require this app's own notification permission, when the user
    /// hasn't granted (or hasn't yet responded to) that request.
    @discardableResult
    static func send() -> String {
        let stamp = Int(Date().timeIntervalSince1970) % 100000
        let title = "Test #\(stamp)"
        dispatch(title: title, body: "Thank you for using NotchNotify!")
        return title
    }

    /// Fires `count` notifications back-to-back from a single AppleScript run (with a short delay
    /// between each) to reproduce the rapid-succession race. Used by the hidden Debug tab.
    static func sendBurst(count: Int) {
        let stamp = Int(Date().timeIntervalSince1970) % 100000
        var lines: [String] = []
        for i in 1...max(1, count) {
            lines.append("display notification \"Back-to-back message \(i) of \(count)\" with title \"Burst #\(stamp)-\(i)\"")
            if i < count { lines.append("delay 0.4") }
        }
        run(script: lines.joined(separator: "\n"))
    }

    /// One real-path notification with an arbitrary title/body — used by the Diagnostics tab to
    /// exercise content extraction (`splitTitleBody`), wrapping, unicode handling, and width logic.
    static func sendCustom(title: String, body: String) {
        dispatch(title: title, body: body)
    }

    /// Escapes a Swift string for safe embedding inside an AppleScript double-quoted literal.
    private static func escapeAS(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func dispatch(title: String, body: String) {
        // UNUserNotificationCenter.current() raises when the process has no bundle
        // identifier (unit tests, `swift run`), so take the osascript path there
        // rather than trapping.
        guard Bundle.main.bundleIdentifier != nil else {
            run(script: "display notification \"\(escapeAS(body))\" with title \"\(escapeAS(title))\"")
            return
        }
        Task { @MainActor in
            let center = UNUserNotificationCenter.current()
            let status = await center.notificationSettings().authorizationStatus
            var authorized = status == .authorized
            if status == .notDetermined {
                // Only the launch request has asked so far, and it went unanswered.
                // Sending a test is an explicit request for a notification, so ask
                // here: without permission the test goes through osascript, which
                // macOS shows as Script Editor with Script Editor's icon.
                authorized = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            }
            guard authorized else {
                AppLogger.shared.log("TestNotification: no notification permission, sent via osascript (shows as Script Editor)")
                run(script: "display notification \"\(escapeAS(body))\" with title \"\(escapeAS(title))\"")
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            do {
                try await UNUserNotificationCenter.current().add(request)
                AppLogger.shared.log("TestNotification: delivered via UNUserNotificationCenter")
            } catch {
                AppLogger.shared.log("TestNotification: UNUserNotificationCenter failed (\(error.localizedDescription)) — falling back to osascript", level: .warn)
                run(script: "display notification \"\(escapeAS(body))\" with title \"\(escapeAS(title))\"")
            }
        }
    }

    /// Tricky notification shapes that have historically broken extraction or layout.
    package struct Scenario: Identifiable {
        package let id = UUID()
        package let label: String
        let title: String
        let body: String
    }

    package static let scenarios: [Scenario] = [
        Scenario(label: "Long message", title: "NotchNotify",
                 body: "This is a deliberately long notification body to exercise text wrapping, the two-line clamp, and width handling in the custom overlay renderer so overflow is easy to see."),
        Scenario(label: "Comma in sender", title: "Stählin, Caspar",
                 body: "Tests the comma-containing title split that broke Teams-style senders."),
        Scenario(label: "Title only (no body)", title: "Reminder: stand up and stretch", body: ""),
        Scenario(label: "Emoji & unicode", title: "Café ☕️ 你好 🎉",
                 body: "Accents éàü, emoji 🔥✅🚀, and a long tail to nudge wrapping."),
        Scenario(label: "Unbroken long word", title: "Link",
                 body: "https://example.com/some/really/long/path/that/will/not/wrap/nicely/segment/end"),
    ]

    private static func run(script: String) {
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", script]
        let errPipe = Pipe()
        task.standardOutput = Pipe()
        task.standardError = errPipe
        task.terminationHandler = { t in
            let code = t.terminationStatus
            let errStr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            Task { @MainActor in
                if code != 0 || !errStr.isEmpty {
                    AppLogger.shared.log("TestNotification: osascript exit=\(code) err=\(errStr)", level: .warn)
                } else {
                    AppLogger.shared.log("TestNotification: osascript ok")
                }
            }
        }
        do {
            try task.run()
        } catch {
            Task { @MainActor in
                AppLogger.shared.log("TestNotification: failed to launch osascript: \(error)", level: .error)
            }
        }
    }
}
