---
id: TASK-73
title: Remove leftover word matching after the move to the on-device model
status: To Do
assignee: []
created_date: '2026-11-26T20:17:44Z'
labels:
  - cleanup
dependencies: []
ordinal: 73000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 26 Nov 2026 (see TASK-56): Router.pick(_:from:) is unused, and Conductor.swift still has a next/skip regex (about line 1273). The on-device model decides what commands mean; remove both.
<!-- SECTION:DESCRIPTION:END -->
