---
id: TASK-53
title: >-
  Esc while I'm talking: once = start my answer over, twice = voicemail (or
  cancel when I started it)
status: Done
assignee: []
created_date: '2026-11-26T10:42:30Z'
labels:
  - hm-1396
dependencies: []
ordinal: 53000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Old id: HM-1396
Related: TASK-45 (HM-1374), TASK-47 (HM-1383)

The owner, 26 Nov ~10:42: "I should be able to stop my own transcription by pressing Esc."

* While the owner answers a question from Claude: Esc once = throw away what he said and listen again from scratch. Esc twice = move Claude's question to voicemail.
* When the owner started it ("Hey Claude…", the first turn): Esc once = start over. Esc twice = cancel, nothing sent.

## History

### 2026-11-26 10:56 UTC (agent)

Built and installed (branch hm-1383-router), not yet tried by voice:
* Hey Claude command / turn shortcut: Esc once = WakeListener.restartCommand (what he said is dropped, listening again, listening cue). Esc twice within 0.5 s = cancelCommand, nothing sent, cancelled sound.
* Answering an agent's ask/say: Esc once = recorder stopped, audio thrown away, listening again with a fresh wait. Twice = the question stored as a voicemail, the agent gets status "voicemail" ("pressed Escape twice").
* A "which chat?" question (his own command): twice = cancel.
* Esc is registered only while he talks (as before: only while Claude talks or a send counts down). Settings and docs/voice.md updated. 119 tests.

### 2026-11-26 10:58 UTC (agent)

Pushed to main as a871ccd (together with the unpushed HM-1374 commits). Release workflow run 45806237936 is building, signing and notarizing; Done once the release is published and the app updates to it.

### 2026-11-26 11:16 UTC (agent)

Released in Needs You v1.1.0 (tag v1.1.0, commit 8fbd5cb, release run 45807779219 succeeded). Appcast lists 1.1.0 (build 29) with NeedsYou-1.1.0.zip; DMG and zip attached. First run 45806237936 failed: the release compiler timed out type-checking a tmux expression from HM-1374; split up in 8fbd5cb.
<!-- SECTION:DESCRIPTION:END -->
