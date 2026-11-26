---
id: TASK-7
title: Hey Claude starts a new chat when none matches
status: Done
assignee: []
created_date: '2026-11-23T17:31:42Z'
updated_date: '2026-11-26T20:07:57Z'
labels:
  - hm-1317
dependencies: []
ordinal: 7000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Old id: HM-1317
Related: TASK-3 (HM-1313)

The owner 23 Nov (by voice): when no chat matches or none is open, Hey Claude starts a new Claude chat inside herdr and types the message there.

* "Hey Claude, new chat in <project>: …" opens it in that project folder (spoken name matched to folders under ~/Projects; asks by voice if unclear). No project named: opens in ~.
* Uses herdr to open a tab running `claude`, waits until it is ready, then sends the text plus the voice suffix.
* Says by voice where it went ("Started a new chat in homemade").
* Tests use a throwaway folder and pane only.

## History

### 2026-11-23 18:32 UTC (agent)

Done. Installed (9ac6611, plus background test tabs in 0bdc054) and verified on 23 Nov, in throwaway folders and panes only. `wake-test --transcript "Hey Claude, new chat in nyfixture alpha: ..." --send --projects-root <scratch>` opened an unfocused herdr tab "needs-you test: nyfixture-alpha" in that folder, started claude, and delivered the message with the voice suffix. The agent picked it up (status working). Both test tabs were closed and the pane was disarmed afterwards.

One side effect: the test agent followed the suffix and answered out loud with `needs-you ask` before its tab closed. Since 0bdc054, an ask whose caller is gone stops before asking a second time and does not publish an artifact.
<!-- SECTION:DESCRIPTION:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-11-26 check: Still works, now chosen by the on-device model instead of phrase patterns (TASK-56, v1.2.0 14554c4). new_chat is an intent in VoiceIntent.swift, covered by IntentJudgeTests.
<!-- SECTION:NOTES:END -->
