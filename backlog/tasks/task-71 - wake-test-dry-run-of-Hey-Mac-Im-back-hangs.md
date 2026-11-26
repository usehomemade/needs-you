---
id: TASK-71
title: wake-test dry run of "Hey Mac, I'm back" hangs
status: To Do
assignee: []
created_date: '2026-11-26T20:17:44Z'
labels:
  - bug
dependencies: []
ordinal: 71000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 26 Nov 2026 during the backlog check: needs-you wake-test --transcript "Hey Mac, I'm back" ran for over 10 minutes and had to be killed. The live voice command works. A dry run should never wait on presence or voicemail playback.
<!-- SECTION:DESCRIPTION:END -->
