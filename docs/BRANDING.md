# NotchNotify identity

Concept C — Stack was approved on 2026-09-30. The identity pairs a camera-notch
capsule with stacked notification cards and a small unread indicator.

- [Approved concept](branding/approved-concept-c.png)
- [App icon source](../Resources/Brand/NotchNotify-Icon.png)
- [Logo](../Resources/Brand/NotchNotify-Logo.png)
- [Menu-bar template](../Resources/Brand/NotchNotify-MenuBar.png)
- [macOS icon bundle](../Resources/NotchNotify.icns)
- [Exact generation prompts](brand-prompts.json)

The production artwork was extracted from the approved concept with the built-in
image generation tool. Transparency is retained. macOS icon sizes were packaged
with `sips` and `iconutil`; the app loads the menu symbol as an AppKit template so
it follows the menu bar appearance. These assets replace the previous placeholder
bell in Settings, the menu bar, and synthetic previews.

The bundle identifier is `io.github.jakobkollerup.notchnotify`.
Required third-party copyright and permission notices live in `LICENSE` and
`THIRD_PARTY_NOTICES.md`, including inside the built app.
