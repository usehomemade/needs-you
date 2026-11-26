---
id: TASK-37
title: >-
  Remove every top-right popup ("Sending…" etc.); show state in the notch island
  only
status: To Do
assignee: []
created_date: '2026-11-25T11:33:02Z'
labels:
  - hm-1363
  - needs-owner
dependencies: []
ordinal: 37000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Old id: HM-1363
Related: TASK-26 (HM-1350)

The owner (voice, 25 Nov 12:32): when he finishes talking and it sends, a small "Sending" popup shows in the top-right corner. He finds it ugly. Remove it, and every similar top-right indicator, from the whole codebase once and for all. Anything worth showing goes into the notch island (TASK-26 (HM-1350)) or nowhere.

## History

### 2026-11-25 11:39 UTC (agent)

Done and installed (main 61b1055, `SKIP_MODELS=1 scripts/install.sh`, `needs-you status` Ready).

Removed:
- **SendHUD**: the top-right "To <chat> … Sending… Press Esc, click, or say cancel" panel (an NSPanel that also activated the app and stole focus). Gone along with its view and KeyPanel class.
- **Notifier**: macOS notification banners (UNUserNotificationCenter). It was never posting, but asked for permission at launch. Deleted.
- "Not sent" flashes now go straight to the island's error state.

What replaces it: a new island **sending** state, the same compact black shape with the same springs. It shows the blue orb, the chat name and a thin ring that runs out over the 2 s. Saying "cancel" or pressing Esc stops it; Escape is only grabbed during those 2 s. After that the island shows the existing check (sent) or error (not sent). Clicking the island no longer cancels, because it is click-through. With Subtitles on Screen off, the countdown shows nothing.

Guard: `SurfaceGuardTests` fails `swift test` if any file other than Island.swift or Subtitles.swift creates a panel, window, popover or notification. I checked it catches a planted NSPanel. `--island-demo` now includes the sending state.

Needs owner: try one "Hey Claude, <chat>: …" and check the island countdown is enough.

### 2026-11-25 12:18 UTC (agent)

Waiting on the owner: say one "Hey Claude, <chat>: ..." message and confirm the island's 2 s sending countdown is enough and no top-right popup appears. The top-right Sending panel and notification banners are removed, and the island sending state is on main and installed.
<!-- SECTION:DESCRIPTION:END -->
