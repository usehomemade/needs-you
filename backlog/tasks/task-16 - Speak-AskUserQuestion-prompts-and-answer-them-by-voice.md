---
id: TASK-16
title: Speak AskUserQuestion prompts and answer them by voice
status: Done
assignee: []
created_date: '2026-11-23T21:33:34Z'
updated_date: '2026-11-26T20:07:58Z'
labels:
  - hm-1329
dependencies: []
ordinal: 16000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Old id: HM-1329

The owner (23 Nov): when Claude Code asks a question with selectable options (AskUserQuestion), he hears nothing and has to go to the keyboard. Plan: a global PreToolUse hook on AskUserQuestion reads the question and options out with needs-you, listens, maps his spoken answer to an option and returns it as the tool's answers; anything unclear falls back to the keyboard. Also a Notification hook so permission prompts and 'waiting for input' are spoken.

## History

### 2026-11-23 21:33 UTC (agent)

Agent started: building AskUserQuestion voice hook + Notification hook.

### 2026-11-23 21:46 UTC (agent)

Done. PreToolUse hook on AskUserQuestion (~/.claude/hooks/voice-ask.py) speaks each question + options via needs-you, listens, maps the answer (number words -> fuzzy label -> gpt-4.1-mini fallback), returns updatedInput.answers + allow. Verified in Claude Code 2.1.325: updatedInput with answers answers the tool without UI.
Proof: (1) live with the owner 23 Nov 22:45 — throwaway session asked 'Which color do you prefer?', he said 'Blue.', session got 'Which color do you prefer? → Blue'. (2) throwaway session, canned answers: multiSelect 'two and three' -> 'Ham, Olives'; 'other: deploy on friday instead' -> free-text answer. (3) 'keyboard' -> normal UI shows. (4) recorded wav through needs-you STT -> 'The second one please' -> SQLite.
Notification hook (~/.claude/hooks/voice-notify.py) speaks '<tab/folder> needs your permission / is waiting for you' for permission_prompt, idle_prompt, elicitation*, agent_needs_input; skips a session the question hook spoke in the last 5 min (verified: AskUserQuestion UI fallback's permission_prompt was skipped) and repeats.
Limits: if nobody answers, needs-you's own 2-try ask publishes its no-answer artifact before the UI shows (~1 min); the session's UI is blocked while the hook waits (max 115 s). Off switch: touch ~/.claude/hooks/voice.off. Settings backup: ~/.claude/settings.json.bak-hm1329-20261123223814.

### 2026-11-23 21:59 UTC (agent)

`needs-you ask --once` was added in needs-you 13f2d11. It asks one time with no "Sorry to ask again" retry and no no-answer artifact, and exits 2 right away. ~/.claude/hooks/voice-ask.py now passes `--once` on its ask call.

Tested outside any real session:
- Direct run (`ask --once --mute`, silent input): exit 2, one agent turn, no artifactURL.
- Hook run with a fake AskUserQuestion payload (session "throwaway-once-test", silent input): logged "no answer (no_answer), UI shows". The history entry is no_answer, has no artifact, and has only one question turn.
- Live timing is one try: the 20 s wait plus the spoken question, about 30 s. Before, it was two tries plus artifact publishing.
<!-- SECTION:DESCRIPTION:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-11-26 check: Still in use. The AskUserQuestion voice hook is a script in ~/.claude/hooks (personal setup, not part of the app), registered in the Claude Code settings. Its log shows a live run on 26 Nov 09:49 UTC: three questions spoken, an unclear answer fell back to the keyboard UI as designed. The app now installs its own Notification and permission hooks (needs-you hook ..., TASK-41).
<!-- SECTION:NOTES:END -->
