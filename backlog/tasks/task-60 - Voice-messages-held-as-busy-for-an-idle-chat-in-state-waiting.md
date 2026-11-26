---
id: TASK-60
title: Voice messages held as 'busy' for an idle chat in state waiting
status: Done
assignee: []
created_date: '2026-11-26T13:46:37Z'
updated_date: '2026-11-26T21:57:50Z'
labels:
  - hm-1412
dependencies: []
ordinal: 15.625
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Old id: HM-1412

Owner, 26 Nov 2026: two voice messages to an idle Claude Code chat were not typed in. History showed "Queued". They only arrived with his next typed prompt, through the UserPromptSubmit hook.

Log: "queued for needs-you: it is busy" / "deliver: queued for pid:… (waiting, 1 waiting)". The chat had ended its turn (Stop hook fired) and was idle at the prompt. State "waiting" (idle at its prompt, waiting for the user) must count as free: type the message in right away.

## History

### 2026-11-26 14:00 UTC (agent)

Released in v1.3.0 (commit 1e0f80e, run 45833091952) and installed. In Review until checked in real use.
<!-- SECTION:DESCRIPTION:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-11-26 status check: Still In Review. Fix in v1.3.0 (1e0f80e), installed v1.6.0; ChatStateTests passes. Since then every queued message in audio.log was for a working chat and went in through PostToolUse; no message to a chat idle at its prompt is in the log yet. Owner check: when a Claude Code chat has finished its turn, send it a voice message and confirm it is typed in right away.

2026-11-26: the owner reviewed it and moved it to Done.
<!-- SECTION:NOTES:END -->
