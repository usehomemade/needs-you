---
id: TASK-66
title: Which chat? An answer pointing at another chat got sent to the offered one
status: In Review
assignee: []
created_date: '2026-11-26T15:58:27Z'
labels:
  - hm-1425
dependencies: []
ordinal: 66000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Old id: HM-1425
Related: TASK-68 (HM-1428)

Owner, 26 Nov 2026, on 1.5.0: Needs You asked "needs-you?". He answered "No, the homemade chat in my home folder. It's called homemade general in herdr" (heard as "Now the Homemade Chat … Homemade General Inherder"). It decided send(needs-you) right away, the 2 s countdown was cancelled, and history shows Cancelled.

Causes:

1. ClarifyConversation.next accepts the model's pick when it equals the offered chat, even though the model said it was unclear and his words point elsewhere.
2. Chat descriptions don't include the herdr workspace name ("general", "homemade") or the tab label, so "homemade general" matched nothing (meaning 0.53 vs 0.51 vs 0.49).

## History

### 2026-11-26 16:14 UTC (agent)

Fixed in commit bc08335 on main (not pushed), installed locally, 179 tests pass. The model's unsure pick no longer sends; an unknown name gets "I can't find a chat called X"; herdr tab and workspace labels are in chat descriptions; the countdown logs why it cancels. Not verified live yet.

### 2026-11-26 18:19 UTC (agent)

Status check (two independent checks): The fix is on local main only (now 7b6bb68, ahead of origin/main by 3). It is not pushed or released, and not verified live. Left to do: push 7b6bb68 to origin/main and ship a release. Then answer "which chat?" with another chat's herdr name, such as "homemade general". It must go to that chat, and an unknown name must get "I can't find a chat called X". Then comment with the release version and proof, and move to Done. State set to Todo because nobody is working on it.

### 2026-11-26 18:41 UTC (agent)

Released in v1.6.0 (run 45876703935) and installed.
<!-- SECTION:DESCRIPTION:END -->
