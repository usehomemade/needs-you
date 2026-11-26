---
id: TASK-30
title: Keyboard shortcut that acts like saying the wake phrase
status: Done
assignee: []
created_date: '2026-11-24T20:28:12Z'
updated_date: '2026-11-26T20:08:00Z'
labels:
  - hm-1354
dependencies: []
ordinal: 30000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Old id: HM-1354

The owner, 24 Nov: add a global shortcut. Pressing it does the same as saying "Hey Claude": it opens his turn right away, with no wake word and no voice check. The shortcut can be changed in Settings.

## History

### 2026-11-24 20:36 UTC (agent)

Built and installed (main 83b6501, app restarted, DND still on).

- Default shortcut **⌥⇧Space**. ⌥Space is the ChatGPT launcher on this Mac, ⌃Space and ⌃⌥Space switch input sources (symbolichotkeys 60/61), ⌘Space is Spotlight and ⌘⇧Space is 1Password. Raycast/Alfred are not installed.
- A press works like a heard wake phrase: it calls the same wake path (chime, ears, listening, recording), with no wake word and no own-voice check. It also works when "Listen for Hey Claude" is off: the mic opens for that one command, then closes again (2 min safety net).
- Press again while talking: ends the command, like "done". While he answers an ask: ends the answer. While Claude speaks: cuts it off like "Stop, Claude" and listens to him (inside an ask that is his answer; after a plain announcement it opens a Hey Claude turn).
- Do not disturb: a press only shows a moon ("Do not disturb") on the island for 1.6 s. It never bypasses DND.
- Settings → Voice → Your Turn Shortcut: click to record, Esc cancels, Delete clears. Buttons to clear it and to go back to ⌥⇧Space. The field shows an error when another app holds the combo.
- Verified: swift build, swift test (TurnKey state logic, combo display/validation). In the installed app, `needs-you voice-test --title keys` returned "turn ⌥⇧Space registered, would do: moon", and `--title keys:turn` ran the real handler and returned "pressed: moon", with DND untouched.

Needs owner: when DND is off, press ⌥⇧Space, say a short message to a test chat, press again to send.

### 2026-11-25 00:24 UTC (agent)

Waiting on the owner: With Do Not Disturb off, press Option+Shift+Space, say a short message to a test chat, press it again to send, and confirm the message arrives. The turn shortcut is built, merged and running in the installed app, but nobody has tested the full flow outside Do Not Disturb yet.
<!-- SECTION:DESCRIPTION:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-11-26 check: Shipped in v1.0.0 and later (Hotkeys.swift, ShortcutTests). Live: audio.log 25 Nov 11:19 UTC "keys: turn shortcut -> openCommand", the wake debug log "wake by the turn shortcut", and a voice send with outcome sent at 11:19:36 UTC. It also showed the moon under do not disturb on 24 Nov.
<!-- SECTION:NOTES:END -->
