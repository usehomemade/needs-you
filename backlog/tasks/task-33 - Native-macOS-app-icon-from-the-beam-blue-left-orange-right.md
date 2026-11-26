---
id: TASK-33
title: Native macOS app icon from the beam (blue left, orange right)
status: To Do
assignee: []
created_date: '2026-11-24T21:40:14Z'
labels:
  - hm-1357
  - needs-owner
dependencies: []
ordinal: 33000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Old id: HM-1357
Related: TASK-26 (HM-1350), TASK-32 (HM-1356)

The owner, 24 Nov: a native macOS app icon made from the speaking beam. A dark icon with the blue beam (his turn) on the left and the orange beam (Claude's turn) on the right, blended. The centre stays mostly empty, so the beam surrounds the icon.

## History

### 2026-11-24 21:45 UTC (agent)

Icon v1 for review: [private preview link removed] (the icon at 1024, the Dock on a dark and a light wallpaper, 128/64/32/16, list rows, and how macOS 26 draws it).

Design: dark squircle tile. The speaking glow runs round the inside edge, blue (#9ecbff/#7fb4ff) on the left and orange (#d97757/#c25e3c) on the right, blended across the top and bottom. Same rim, band and halo falloff as Glow.swift. The centre stays dark with a faint light. Grid is 1024 canvas, 824 tile, continuous corners at radius 185, soft shadow. At 16 and 32 the glow is drawn wider so it still reads.

Files are in `~/Projects/needs-you/Resources/AppIcon/`: `AppIcon.icns`, `AppIcon-1024.png`, `AppIcon.icon` (Icon Composer, compiles with actool to Assets.car plus a fallback .icns) and `render.py` (regenerates everything). Both the .icns and the .icon render correctly on macOS 26. Nothing is wrapped in a gray box.

Not committed yet: main has uncommitted tracked changes from another agent, so I left the files untracked and did not touch README.md. Stays In Progress until the owner reviews.

### 2026-11-25 00:22 UTC (agent)

Cleanup: no agent is working on this. The icon is built and installed (main 3d9e900) and waits for the owner's review at [private preview link removed]. Moved to Todo + Needs owner.

### 2026-11-25 00:23 UTC (agent)

Waiting on the owner: open [private preview link removed] and approve the icon or leave comments on it. The icon is built, merged in local main (3d9e900) and installed in the app, but not pushed to origin yet.
<!-- SECTION:DESCRIPTION:END -->
