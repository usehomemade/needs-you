---
id: TASK-46
title: Much shorter README with the logo, details moved to docs/
status: Done
assignee: []
created_date: '2026-11-25T14:22:00Z'
updated_date: '2026-11-26T20:16:36Z'
labels:
  - hm-1375
dependencies: []
ordinal: 46000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Old id: HM-1375
Related: TASK-38 (HM-1364), TASK-45 (HM-1374)

The owner, 25 Nov: make the README WAY shorter and add the app logo at the top. Move each detailed section into its own docs/ file where needed. Run the humanizer on the README and the docs.

## History

### 2026-11-25 14:22 UTC (agent)

The owner, 25 Nov: "release everything". Push main (README + the unpushed HM-1364 fixes) as soon as this README merge lands, which triggers the automatic public release. HM-1374 ships in the next release when it merges.

### 2026-11-25 14:23 UTC (agent)

README cut from 168 lines to 37 (logo, pitch, 2 install ways, 3-step quick start, docs list). Detail moved to docs/agents.md, voice.md, permissions.md, privacy.md, building.md. Logo at docs/assets/logo.png (512 px). Humanizer pass applied, all links checked. Merged into local main (5425447), not pushed.

### 2026-11-25 14:37 UTC (agent)

Released as Needs You 1.0.1: https://github.com/usehomemade/needs-you/releases/tag/v1.0.1. It contains the 37-line README with the logo, docs/, and the HM-1364 fixes.

The release run's cask step failed because `gh repo clone` had no git credentials. Fixed in b0f6820 (clone with the token URL, commit marked [skip release]). I bumped the cask to 1.0.1 by hand in homebrew-tap. Done.
<!-- SECTION:DESCRIPTION:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-11-26 status check: Kept Done. README.md on origin/main is 41 lines with the logo; detail lives in docs/.
<!-- SECTION:NOTES:END -->
