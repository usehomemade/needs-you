---
id: TASK-29
title: Escape stops Claude talking
status: To Do
assignee: []
created_date: '2026-11-24T20:28:10Z'
labels:
  - hm-1353
  - needs-owner
dependencies: []
ordinal: 29000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Old id: HM-1353

The owner, 24 Nov: pressing Escape while Needs You is speaking should stop the voice at once. Escape must only be captured while speech plays, never at other times.

## History

### 2026-11-24 20:36 UTC (agent)

Built and installed (main 83b6501, app restarted, DND still on).

- Escape stops Needs You's voice at once, from any app. It is a Carbon hot key that is registered only while the voice plays and unregistered when it stops, so Escape behaves normally everywhere else. No Accessibility permission needed.
- It goes through the same stop path as "Stop, Claude" (stop sound, subtitles, island and glow end). One difference: "Stop, Claude" keeps the conversation open and listens for what he says next. Escape means quiet, so nothing listens afterwards and an open ask/say ends. The agent gets `status: interrupted` with `spoken_until`, an empty `transcript` and a `state` saying he pressed Escape. The island folds back instead of showing "thinking". AGENTS.md and README are updated.
- During voicemails Escape keeps the rest for later. During "Which chat?" it cancels.
- Verified: swift build, swift test (new ShortcutTests), and the silent hook `needs-you voice-test --title keys:escape` ("nothing playing"; Escape is not registered while idle). Escape has not been pressed during real speech yet.

Needs owner: during any `say`, press Escape once to check it stops right away.

### 2026-11-25 00:24 UTC (agent)

Waiting on the owner: during any Needs You say or ask, press Escape once and confirm the voice stops right away. Escape-to-stop is built, merged on main and installed, but nobody has pressed it during real speech yet.
<!-- SECTION:DESCRIPTION:END -->
