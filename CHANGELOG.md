# Changelog

## 1.0.0 — unreleased

First public release of NotchNotify, based on
[Notification Nanny](https://github.com/chessper53/NotificationNanny) 8.0.2.

- Notifications appear as cards that grow out of the camera notch, with five
  animation styles, stacking, hover-to-pause, and a choice of display.
- Native mode keeps the real macOS banner and moves it to the top center.
- The original banner is hidden as soon as it is recognized, before the notch card
  is prepared. Each hide is confirmed off every display, and failed or reset moves
  are retried for a short, limited time.
- **Open at Login** in the menu bar.
- Universal build for Apple silicon and Intel, macOS 14 or later.
- Notification text is no longer written to the in-memory activity log.
