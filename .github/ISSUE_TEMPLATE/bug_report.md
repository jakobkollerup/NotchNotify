---
name: Bug report
about: Something is not working right
title: "[Bug] "
labels: bug
---

**What happened?**

**What did you expect to happen?**

**Steps to reproduce**
1.
2.
3.

**Setup**
- NotchNotify version (menu bar › About NotchNotify):
- macOS version:
- Mac model, and whether it has a notch:
- Displays attached, and which one is the main display:
- Appearance (Notch or Native) and animation style:

**Timing log (optional)**
If the original banner flickers or stays visible, run this in Terminal, trigger a
notification, then paste the output. It contains window IDs and timings only, not
notification text.

```sh
log stream --info --predicate 'subsystem == "io.github.jakobkollerup.notchnotify" AND category == "handoff"'
```
