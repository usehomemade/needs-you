---
id: TASK-55
title: >-
  A reply to a voice message came back on the wrong place (Claude app chat, 26
  Nov 12:22)
status: Done
assignee: []
created_date: '2026-11-26T11:25:30Z'
updated_date: '2026-11-26T21:57:50Z'
labels:
  - hm-1398
dependencies: []
ordinal: 312.5
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Old id: HM-1398

The owner by voice, passed on by the home-folder chat (home-chat-1), 26 Nov ~12:24: "I asked what did Houseplant care say … it did find the correct chat using the Claude desktop app. That's fine. But the Needs You agent spoke through a Mac, that I also have this app installed … if I talk in this app, sorry, in the Mac, it needs to be replied back to me with this Mac."

Facts from the logs: 11:21:59Z the Mac mic won (no other device took part); 11:22:04Z "What did Houseplant care say? (sent by voice: reply by voice with needs-you)" was typed into the Claude app chat "Houseplant care for beginners". The Claude app has the Needs You MCP server, so its chat was told to answer out loud.

Unclear what should have happened instead → asking the owner.

Also reported: home-chat-1's `needs-you say --no-listen` hung past 120 s while a voice message reached it through a PostToolUse hook.

## History

### 2026-11-26 11:28 UTC (agent)

The owner (by voice, 12:26): "it shouldn't be able to access anyone else's Needs You app … whatever happens with this app needs to stay local on this Mac. No other Macs, even sharing the same account or network … super strict, local only."
Cause: the voice line ("reply by voice with needs-you") went into a Claude app chat; Claude app chats sync through the account, so his other Mac's Claude app (also with Needs You) answered out loud there.
Fix (local build, not released): messages to chat apps (Claude app, ChatGPT, any found app) never carry the voice line and the app stays in front: the answer is on screen on this Mac. Herdr/terminal chats and connected Claude Code chats are local processes and keep the voice line.
Open: home-chat-1's `needs-you say --no-listen` hung past 120 s (separate).

### 2026-11-26 11:31 UTC (agent)

Correction (the owner: "of course I want them read out loud, that's the whole idea"): text-only reverted. Now voice messages to chat apps end with "(sent by voice from Desk Mac: reply by voice with needs-you, for_mac "Desk Mac")". The MCP tools ask/say/done take for_mac; Needs You on any other Mac refuses ("Not spoken: … only Desk Mac speaks the reply") and speaks nothing. Proven with a for_mac "Some Other MacBook" say: refused, nothing spoken. The other Mac needs this version too, and the two Macs need different names.
Also fixed: answering "which chat?" with "Claude Code, needs-you chat" picked "Claude Code in your home folder"; words every chat shares (Claude, Code, chat…) no longer pick. 120 tests. Local build, not released.

### 2026-11-26 12:19 UTC (agent)

Status check (two independent checks): The fix is on needs-you main in commit 14554c4, but no release has it yet. Release run 45817637324 was still running, and v1.1.0 does not contain it. Left to do: 1) Confirm the new release contains 14554c4. 2) Install it on both Macs and give them different names. 3) Send one voice message into a Claude app chat and check that only the Mac that heard it speaks the reply. 4) Fix the `needs-you say --no-listen` hang past 120 s, or split it into its own issue.
<!-- SECTION:DESCRIPTION:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-11-26 status check: Still In Review. The fix (14554c4) is in v1.2.0 and later; installed app is v1.6.0. Needs two Macs to prove, and no log here shows it. Owner check: with Needs You on both Macs, send one voice message into a Claude app chat and confirm only the Mac that heard it speaks the reply.

2026-11-26: the owner reviewed it and moved it to Done.
<!-- SECTION:NOTES:END -->
