---
id: TASK-67
title: Public website for Needs You at needsyou.homemade.dev
status: Done
assignee: []
created_date: '2026-11-26T16:05:08Z'
updated_date: '2026-11-26T21:57:51Z'
labels:
  - hm-1427
dependencies: []
ordinal: 39.0625
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Old id: HM-1427

Owner, 26 Nov 2026: build a public page for the Needs You app, following the owner's app website playbook, with the look of another of his app sites. Include GitHub stars and similar repo stats. Publish it at needsyou.homemade.dev.

## History

### 2026-11-26 16:21 UTC (agent)

Preview of the website (built from site/ in commit ce0962b) is at [private preview link removed]. Waiting for the owner's look before it goes live at needsyou.homemade.dev.

### 2026-11-26 16:22 UTC (agent)

Preview v2: v1 showed the page unstyled because the site's absolute asset paths don't resolve under the preview's sub-path. Paths are now relative in the preview copy (the real site at a domain root is unaffected).

### 2026-11-26 16:33 UTC (agent)

Preview v3: [private preview link removed]. The hero now uses the app's real beam (Glow.swift shader ported to WebGL) and island. It tells one Claude Code story that ends in needs-you ask, plus a voice message to a second agent. Privacy/free/GPL-3.0 is the lead promise, and the copy went through a humanizer pass. Not deployed yet.

### 2026-11-26 16:42 UTC (agent)

Preview v4: [private preview link removed]. Changes:
- Hero rebuilt from Mobbin references (Aqua, Cursor, Monologue), in Apple's official MacBook Pro 14 bezel. The subagent accepted the Apple Design Resources click-through license when mounting the DMG.
- Headline leads with privacy.
- Star count shown in the nav and hero.
- Loop plays inside the artifact iframe (scripts inlined).
- Light/dark toggle in the nav.
- "Hey Mac" everywhere.

### 2026-11-26 16:46 UTC (agent)

Live: https://needsyou.homemade.dev (HTTP 200). Hosting: Dockerfile build from usehomemade/needs-you main /site, port 80. DNS record proxied to the server. Built from commit 2f5b6ea. Next deploy will add: copy button with check animation, live GitHub versions (none hardcoded), dark by default.

### 2026-11-26 17:52 UTC (agent)

Preview v8 (homepage reworked for mobile and desktop, subagent did its own research: Mobbin Aqua/Shop/WhatsApp, HIG via sosumi, the reference app site): [private preview link removed]. Not deployed yet.

### 2026-11-26 18:19 UTC (agent)

Status check (two independent checks): The live site has GitHub stars, copy button and dark default (commit 1fb43aa on main). The v8 homepage rework exists only as uncommitted edits in site/ and is not deployed. Left to do: get the owner's look at v8, commit and push site/ to main, redeploy needs-you-site, check the live page on mobile and desktop. Moved to Todo, waiting on the owner's look at v8.

### 2026-11-26 18:43 UTC (agent)

Preview v9: [private preview link removed]

Phones no longer get the cropped laptop. The hero shows a phone-sized Mac screen with the island, the Claude Code window and the subtitles at readable size, so the island is in the first screen. Buttons sit on one row, the brew box and the header Download are hidden on phones, the code example wraps, and the terminal dots no longer show as emoji in iOS Safari. Desktop is unchanged. Checked in iOS Simulator Safari (iPhone 17) from the artifact URL.

### 2026-11-26 19:16 UTC (agent)

Live: phone-first rework (preview v9) deployed to https://needsyou.homemade.dev from commit b6cfa34.

### 2026-11-26 19:36 UTC (agent)

Shipped 34b6a6b to needsyou.homemade.dev: Apple Sonoma wallpaper (light/dark), Dock with real Finder, Safari, System Settings, Ghostty, Homemade, Needs You and Trash icons; Homemade icon links to homemade.dev/home. Live check: page has the link, /scene/dock/finder.webp returns 200.
<!-- SECTION:DESCRIPTION:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-11-26 status check: Moved from In Progress to In Review: nobody is working on it and there is no uncommitted work. The site is live from 34b6a6b. Owner check: open the site on the iPhone and on the Mac and say if it is good to keep.

2026-11-26: the owner reviewed it and moved it to Done.
<!-- SECTION:NOTES:END -->
