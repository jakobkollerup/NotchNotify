import AppKit
import NotchNotifyCore

@main
enum NotchNotify {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        if CommandLine.arguments.contains("--render-preview") {
            do {
                try NotchApplicationDelegate.renderPreview()
            } catch {
                fputs("Preview failed: \(error)\n", stderr)
                exit(1)
            }
            return
        }
        let delegate = NotchApplicationDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
