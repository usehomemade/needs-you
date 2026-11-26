---
id: TASK-44
title: Token for automatic Homebrew cask bumps, delete the old private repo
status: Done
assignee: []
created_date: '2026-11-25T13:13:46Z'
updated_date: '2026-11-26T20:16:36Z'
labels:
  - hm-1373
dependencies: []
ordinal: 44000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Old id: HM-1373
Related: TASK-39 (HM-1366)

Follow-up to TASK-39 (HM-1366). Release 1.0.0 is public. Two small things remain, and only the owner can do them.

1. **Automatic cask bumps.** The release workflow pushes `Casks/needs-you.rb` to `usehomemade/homebrew-tap` only when the repo has a `HOMEBREW_TAP_TOKEN` secret. Until then it skips the step with a warning, and I pushed 1.0.0 by hand. GitHub has no API to create fine-grained tokens, and deploy keys are disabled in the org.
   * Open [https://github.com/settings/personal-access-tokens/new](https://github.com/settings/personal-access-tokens/new). Choose resource owner **usehomemade**, repository access **Only select repositories → homebrew-tap**, permission **Contents: Read and write**, expiry 1 year.
   * Paste the token to an agent. It stores it in the team's secret store as `HOMEBREW_TAP_TOKEN` and sets it with `gh secret set HOMEBREW_TAP_TOKEN -R usehomemade/needs-you`.
2. **Old repo.** `usehomemade/needs-you-old-history` is the old private repo, renamed and still private. The local mirror is at `~/Projects/needs-you-old-history.git`. Delete it on GitHub (Settings → Danger Zone) when you no longer need it; our token has no `delete_repo` scope.

## History

### 2026-11-25 13:17 UTC (agent)

Done, 25 Nov:
- The owner created the fine-grained tap token (usehomemade/homebrew-tap, Contents RW). It's stored as HOMEBREW_TAP_TOKEN in the team's secret store and as a GitHub secret on usehomemade/needs-you. Reading Casks/needs-you.rb with it returns 200, and the clipboard was cleared afterwards.
- The owner deleted usehomemade/needs-you-old-history. The local mirror backup stays at ~/Projects/needs-you-old-history.git.
<!-- SECTION:DESCRIPTION:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-11-26 status check: Kept Done. The cask bump step has worked since commit 986f34a (clone the tap with the token); releases v1.1.0 to v1.6.0 ran after it.
<!-- SECTION:NOTES:END -->
