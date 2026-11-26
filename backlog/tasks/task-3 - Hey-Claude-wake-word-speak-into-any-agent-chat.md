---
id: TASK-3
title: '''Hey Claude'' wake word + speak into any agent chat'
status: Done
assignee: []
created_date: '2026-11-23T17:01:32Z'
updated_date: '2026-11-26T20:07:56Z'
labels:
  - hm-1313
dependencies: []
ordinal: 3000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Old id: HM-1313
Related: TASK-8 (HM-1318), TASK-7 (HM-1317), TASK-4 (HM-1314)

The owner 23 Nov: (1) What he says gets typed into the right Claude chat in Ghostty, as if he wrote it. The tab is picked by session title or 'this one'; it asks when unclear. Text is pasted and Enter pressed via macOS accessibility, with a 2 s 'sending…' cancel window and 'cancel' by voice. (2) Wake word 'Hey Claude', detected on-device by Apple speech (nothing leaves the Mac before the wake word); then record with the 3 s pause rule, transcribe with ElevenLabs and send.

## History

### 2026-11-23 17:18 UTC (agent)

Incident during testing: one wake-word test typed "needs-you test. Hello from generated audio." into a real Claude session, the orchestrator session (herdr pane w2:p13, the focused chat). Cause: Scribe wrote the spoken "needs-you test:" with a period instead of a colon, so no chat name was parsed. The router then fell back to "the focused chat", and test runs could still see real chats.

Fixed (on next build, verified):
- Test runs only see the one armed test pane and send to it by exact herdr pane id. No title matching, no focus, no voice questions.
- Verify-before-send is now part of the product. Right before typing, Needs You re-reads the target from herdr. It aborts if the chat is gone, its title changed, or (for "this one") focus moved to another chat. It checks again right after focusing the chat. Test: renaming the test tab during the 2 s countdown aborted the send with "That chat changed its title…". An unchanged tab got the text.
- "Name." and "Name," now count as a chat name when they clearly match one, so this phrasing would now route by name.

Note: the owner's claude sessions run inside herdr (one Ghostty tab), not in separate Ghostty tabs. Routing and delivery use herdr's agent API (`herdr agent list` for titles, `herdr agent prompt` for bracketed paste plus Enter), not Ghostty AppleScript or the clipboard. Test target: a throwaway herdr tab "needs-you test" running `cat` (pane w2:p1T).

### 2026-11-23 17:26 UTC (agent)

Done, and the owner confirmed it by voice: "yeah, they work". Builds 1160413 and 8f9f640 on usehomemade/needs-you main, installed with the same signing.

Why "Hey Claude" didn't work at first:
- SFSpeechRecognizer refuses on his Mac ("Siri and Dictation are disabled"). Switched to Apple's SpeechAnalyzer/SpeechTranscriber (macOS 26+, on-device, works without Dictation).
- Once the wake word fired (heard as "Hey Cloud", which counts), recording never ended. The noise floor didn't follow his room (about -39 dB), so it ran to the 2-minute cap. The noise floor is now the 15th percentile of the last 8 s of levels.
- A repeated "Hey Claude" left an empty message. Now the last wake word followed by real words wins.
- New: a dot on the menu bar icon while it listens for the wake word, a "Listening…" panel after the wake word, and the 2 s "Sending…" panel.

Proof:
- Generated audio (clean, fan noise, loud room): the message arrived in a throwaway herdr tab running `cat`. A clip without the wake word was ignored.
- Esc during the countdown cancelled the send. Renaming the tab during the countdown aborted it.
- Live: the owner said "Hey Claude. This one, test." and "test." arrived in the throwaway tab. History shows it as sent to "needs-you test". The tab is closed, and no test pane is armed anymore.

Follow-up from the owner, filed as HM-1314: pickup from across a noisy room.
<!-- SECTION:DESCRIPTION:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-11-26 check: Still works, with changes since: the wake phrase is now "Hey Mac" (TASK-68, v1.6.0, 544c9b8), and chats outside herdr are reached through Accessibility (TASK-45). history.json has voice sends with outcome sent or delivered every day from 24 to 26 Nov.
<!-- SECTION:NOTES:END -->
