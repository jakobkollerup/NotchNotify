import AppKit

/// The approved stack identity, shared by app chrome and synthetic notifications.
@MainActor
enum NotchBrand {
    static let appIcon = image(named: "NotchNotify-Icon")
    static let logo = image(named: "NotchNotify-Logo")

    static var menuBarIcon: NSImage? {
        guard let image = image(named: "NotchNotify-MenuBar") else { return nil }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        image.accessibilityDescription = "NotchNotify"
        return image
    }

    private static func image(named name: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "Brand") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }

    static func openLicenses() {
        guard let url = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md") else { return }
        NSWorkspace.shared.open(url)
    }
}
