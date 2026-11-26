---
id: TASK-32
title: Full native macOS redesign (app window, Settings, Dock app, simpler menu bar)
status: Done
assignee: []
created_date: '2026-11-24T21:40:13Z'
updated_date: '2026-11-26T20:08:01Z'
labels:
  - hm-1356
dependencies: []
ordinal: 32000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Old id: HM-1356
Related: TASK-33 (HM-1357), TASK-27 (HM-1351)

The owner, 24 Nov: fully redesign the app and the Settings page with a fully native macOS look. It should also be able to live in the Dock, not only in the menu bar. Reorder and redesign the menu bar menu: nothing fancy, a list is fine, but it should be useful.

Today's menu: Ready / Listen for "Hey Claude" / Use iPhone Mic / Do Not Disturb / Play Voicemails (1) / Open Needs You / Training… / Settings… / Quit.

## History

### 2026-11-24 22:00 UTC (agent)

Shipped on main (merge 3d9e900) and installed in ~/Applications/Needs You.app. Do Not Disturb is still on.

Screenshots: [private preview link removed]

- Main window: sidebar with Conversations, Voicemails (unheard badge) and the 10 most recent chats; list grouped by day; search; voicemails can be played, answered by typing, marked heard or deleted. Dock click opens it (checked on the installed app).
- Settings: toolbar panes General, Hey Claude, Voice, Microphones (incl. Languages I Speak from HM-1351), Models, Do Not Disturb, Agents. UserDefaults keys unchanged.
- Dock: Show in Dock (default on) switches .regular/.accessory at runtime; Show in Menu Bar; one stays on. Main menu File/Edit/View/Window/Help plus a Dock menu.
- Menu bar: status line, Do Not Disturb, Voicemails (n) submenu, Recent Conversations, Listen for wake phrase, Microphone submenu, Open Needs You ⌘O, Settings… ⌘,, Quit ⌘Q.
- Fix found on the way: SwiftPM stamped SDK 14.0 into the binary, so AppKit ran in its macOS 14 look. install.sh now restamps the real SDK with vtool, which turns on the macOS 26 glass design.
- App icon (HM-1357) wired in via actool from Resources/AppIcon.

Needs owner: look at the window, Settings and menu and say what to change.

### 2026-11-25 00:23 UTC (agent)

Waiting on the owner: Open Needs You and the screenshots at [private preview link removed]. Look at the main window, Settings and the menu bar menu, then say what to change or approve it. The redesign is merged on local main and installed on the Mac, and it waits for your design review.
<!-- SECTION:DESCRIPTION:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-11-26 check: Shipped in v1.0.0 and later (AppShell.swift: Dock, menu bar, Settings panes). The owner uses the main window and Settings (saved window frames). The main window was redesigned again in v1.1.0 (9fb7dcc); further Chats page work is TASK-48.
<!-- SECTION:NOTES:END -->
