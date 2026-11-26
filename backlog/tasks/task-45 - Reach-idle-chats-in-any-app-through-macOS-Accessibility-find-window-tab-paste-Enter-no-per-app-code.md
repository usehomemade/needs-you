---
id: TASK-45
title: >-
  Reach idle chats in any app through macOS Accessibility (find window/tab,
  paste, Enter), no per-app code
status: In Review
assignee: []
created_date: '2026-11-25T13:42:55Z'
updated_date: '2026-11-26T20:16:36Z'
labels:
  - hm-1374
dependencies: []
ordinal: 45000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Old id: HM-1374
Related: TASK-38 (HM-1364), TASK-52 (HM-1395), TASK-51 (HM-1394), TASK-49 (HM-1385), TASK-50 (HM-1389), TASK-53 (HM-1396), TASK-47 (HM-1383), TASK-48 (HM-1384), TASK-46 (HM-1375)

The owner, 25 Nov ~14:25: "go for idle chats for accessibility". He doesn't want per-terminal typing code (Ghostty, Terminal, Orca…) or Claude Code channels, because the app must stay agent-agnostic.

The approach is one generic path through the macOS Accessibility API:

1. Read the windows, tabs and text fields of all apps.
2. The on-device model picks the target from what he said plus the chats' MCP registrations.
3. Focus the target, paste, press Enter.
4. Restore his previous focus.
5. Ask "1 or 2?" when unsure.

Step 1 is a proof (2–4 h) with throwaway windows only. Step 2 builds it into the app (1–2 days) and replaces the herdr typing path.

## History

### 2026-11-25 14:02 UTC (agent)

Phase 1 (AX proof) is done. One generic AX path reached the right window and tab in Terminal, Ghostty, TextEdit and Cursor, with no per-app code. Each send took 200–310 ms after the idle wait. Focus and clipboard came back each time. I used only throwaway windows and closed them all at the end. The owner's Ghostty (pid 699) was not touched. Probe: `tools/ax-proof/ax2.swift`, commit 4e66725 on branch hm-ax (not pushed).

| App | Windows | Tabs | Panes in one window | Right target focused | Paste + Return landed | Time after idle | Restore |
|---|---|---|---|---|---|---|---|
| Terminal.app | yes: title, cwd (AXDocument), screen text (AXValue) | yes, 4 tabs; each tab is its own AXWindow, so the window is looked up again after the tab press | n/a | yes | 6/6, right tab each time | 220–265 ms | front app, focused field and clipboard back; the target's selected tab stays switched |
| Ghostty | yes: title, cwd (AXDocument after OSC 7), screen text | yes (AXTabGroup, press works) | native splits not tested (menu item not reachable while in background) | yes. Twice the first AXFrontmost on a background instance did not take; the check aborted, nothing was pasted, it worked next time | 4/4 | 200–310 ms | same |
| TextEdit | yes, with the file path | n/a | n/a | yes | yes (Return adds a newline) | 226 ms | same |
| Cursor (VS Code, Electron) | only after setting AXManualAccessibility | the panel tab "Terminal (⌃`)" | — | yes, when the terminal already had focus | yes | 201 ms | same |
| tmux inside a Terminal tab | one text area for the whole tab | — | **no**: the paste reached only the active pane (pane 0 got it, pane 1 got nothing) | — | — | 301 ms | same |
| iTerm2 | not installed | | | | | | |
| herdr | not tested (the owner's real session). It works like tmux: one text area per window, and the pid chain ends at the Ghostty that started the herdr server, not the window that shows the pane | | | | | | |

**Matching**
- A registered chat's folder (cwd) matches exactly. Terminal puts it in the tab title and AXDocument; Ghostty puts it in AXDocument.
- Following the agent pid up its parent processes reaches the GUI app for a plain shell (Terminal). It finds no app for tmux, and for herdr it reaches the Ghostty that started the server, not the window.
- Terminal and Ghostty expose the screen text (AXValue). Matching it against the chat's last reply is a strong signal. Cursor exposes no terminal text.
- Weak spots:
  - Ghostty tabs with the same title can only be told apart by switching to each one and reading its folder, which flickers on screen.
  - Cursor's text fields have no labels.
  - A plain substring match picked "term-a2" for "term-a". Matching now uses word boundaries.

**The guard worked:** 4 sends stopped because the focused window was not the target after a tab switch. Nothing was pasted.

**Timing:** listing all 16 windows of every running app takes 1.3–1.6 s, mostly Needs You itself (543 ms), Chrome (208 ms) and System Settings (169 ms). The test apps take 16–45 ms each. So scan only the likely apps, skip our own, and cache the results.

**Risks:**
1. Focus moves away from what the owner is doing. Wait until he has not typed for 1.5 s, and stop if he types during the send.
2. Clipboard managers keep a copy of the text. Mark the pasted item as transient and concealed.
3. A wrong Return. Check again right before pressing it.
4. Window tabs switched in the target app stay switched; switch them back.
5. Needs You runs as a background app and may get different rules for bringing another app to the front. Phase 2 has to test this from inside the app.

**Phase 2 plan (1–2 days)**
1. One AXDelivery path in the app, no per-app code. Candidates: apps that own a registered agent's process, plus apps that held chats before. For each window it reads the title, folder, tabs, text fields and the end of the screen text.
2. Each tab gets a score against the chat's registration: folder, title, screen text against the last reply or prompt, the app that owns the process. A clear winner is sent; otherwise "1 or 2?" with the existing question.
3. Panes inside one window (herdr or tmux): select the pane first with the multiplexer command already in the registration. **This needs the owner's OK.**
4. Send steps:
   - wait for 1.5 s with no typing;
   - save the front app, window, focused field and clipboard;
   - bring the target app to the front, raise the window, press the tab, look the window up again and focus the text field;
   - check: right app in front, right window, a text field, right tab, the screen text still matches;
   - paste as a transient clipboard item, check again, press Return;
   - put back focus, the target's previous tab and the clipboard.
   If any check fails, nothing is sent, the message stays in the inbox and the island says so.
5. Only for idle chats, after the 2 s countdown. Busy chats keep the inbox path.
6. A silent self-test (`needs-you ax-test`) that uses throwaway windows only.

Also: the owner's voice question ("does Hey Claude without MCP still paste?") arrived through a PostToolUse hook inside a subagent of the main chat, not in the main chat itself. The code answers it: once a chat is connected, messages wait in its inbox and nothing is typed. The herdr typing path runs only when no agent is connected.

### 2026-11-25 14:04 UTC (agent)

The owner, 25 Nov ~15:10 (voice): go for phase 2, option A. Small focus commands for tmux and herdr panes are fine. The Claude desktop app must work too. No per-app code for everything else; the generic AX path covers it.

### 2026-11-25 14:19 UTC (agent)

Phase 2 is built but cannot be tested yet: **Needs You.app has no Accessibility access.** Tested from inside the app, `AXIsProcessTrusted()` returns false. I did not change any privacy settings.

To unblock it, the owner turns on Needs You under System Settings → Privacy & Security → Accessibility ("Device Control and Data Access" on macOS 27). If it is not in the list, add `~/Applications/Needs You.app` with +.

**What is built** (branch hm-ax, rebased on main 13650fe, commit 7c7d929, not merged, not pushed):
- `AXDelivery` is one Accessibility path for every app. It finds the window and tab, waits for 1.5 s with no typing, then focuses, checks, pastes, checks again, presses Return and restores. The paste goes through a transient, concealed clipboard item. Electron apps (Cursor, VS Code, the Claude app) get AXManualAccessibility first.
- `Mux` selects the pane first: herdr uses `agent focus` or `tab focus` by `$HERDR_PANE_ID`; tmux uses `switch-client`, `select-window` and `select-pane` by `$TMUX_PANE`. It switches back afterwards. It also checks that the pane really runs the agent. During setup a test Terminal inherited my herdr pane id, which would have sent the paste to the wrong pane, so this check is needed.
- `AXMatch` scores each window and tab against the chat's registration: its folder in the AXDocument or title, its last reply or prompt on screen, and the pane's own text from herdr or tmux. It picks only a clear winner. 7 new unit tests; all 99 tests pass.
- Routing: an idle connected chat is typed into. A busy one, or one where a check failed, keeps the message in its inbox (main's queued-until-delivered history). The old herdr `agent prompt` and `send-text`/`send-keys` typing paths and the separate Claude-app paste are gone; everything that types goes through AXDelivery.
- Silent test hook: `needs-you voice-test "<text>" --title ax-send:<pid>` and `--title ax-scan:<pid>`. It works only for chats whose folder holds a `.needs-you-axtest` file, and never for a pane in the main herdr session. `tools/ax-proof/fake-agent.py` registers a throwaway chat.

I briefly installed the branch build, then installed main 13650fe again, so the installed app is main. Test windows and the Claude app I had opened are closed. The Claude app also showed a "Verify your payment method" dialog, which I left alone. While it is open, nothing can be typed into the Claude app.

### 2026-11-25 14:51 UTC (agent)

Phase 2 is merged to main (184d34e) and installed, not pushed. A voice message to an idle connected chat is now typed into it in whatever app shows it. A busy chat, or one where a check fails, gets the message from its inbox as before. The Accessibility grant survived the reinstalls; the app was checked from inside.

**In-app tests, throwaway targets only.** All of them ran from the installed app in the background, with real Accessibility access. Each message landed only in its own chat, and focus went back to the app in front (TextEdit) every time.

| Target | Result | Total time |
|---|---|---|
| Terminal, chat in a background tab | typed, tab switched back | 325 ms |
| Terminal, chat in the front tab | typed | 282 ms |
| Ghostty (second instance) | typed | 294 ms |
| tmux, chat in the inactive pane | typed, pane switched back to %0 | 1.46 s |
| herdr, separate session `axtest`, chat in a background tab | typed, tab switched back | 892 ms |
| Cursor terminal (picked by its label "Terminal 4, Python", not the AI prompt box) | typed | 338 ms |
| Claude app, new session (chat mode) | typed and sent, Claude answered "OK" | 357 ms |
| Busy chat | not typed, kept in the inbox | — |

**Fixed while testing:**
- Terminal tabs: the window is looked up again after the tab press.
- The full terminal text is read now; the end of it alone missed the herdr pane.
- After a pane switch, the scan retries for up to 0.6 s.
- The message is pasted as one line. Without bracketed paste, a newline in it would have sent it before the checks allowed Return.
- Restore falls back to `activate` and then a Dock-style open. Finder needed this and took 0.6 s.
- In Electron apps, the text field must say it is the terminal or the prompt.

**Live test for the owner (about 5 minutes)**
1. Pick a real chat that is idle (its turn has ended), e.g. one in herdr. Stay in another app, e.g. Chrome.
2. Say "Hey Claude, <that chat>: say hi back out loud". After the 2 s island countdown, keep your hands off the keyboard and mouse for 1.5 s.
3. Expected: the chat gets the message and starts a turn. Your app and clipboard come back, and so does the herdr tab you had in front.
4. Say "Hey Claude, <a busy chat>: …" while it is working. Expected: "Queued for <chat>", and it arrives on the chat's next tool call.
5. If something goes wrong, the reason is in `audio.log` (lines starting with `ax:`).

**Two things for the owner:**
- The test left one throwaway chat called "OK" in the Claude app's Recents. Its menu does not open without a real click, so please delete it by hand.
- When the window is unclear, the message is kept in the inbox; there is no "1 or 2?" question at window level. The which-chat question still asks when it is unclear which chat is meant.

Cleanup: all test windows, tmux, the herdr session `axtest`, the isolated Cursor and the fake chats are gone. The hm-ax worktree is removed.

### 2026-11-25 15:18 UTC (agent)

Codex, ChatGPT and Cursor tested from inside the installed app (main 5b338c4, docs f3f4465). Throwaway chats only. Not pushed.

| Target | Connected how | AX finds input | Lands and sent | Notes |
|---|---|---|---|---|
| Codex CLI (Terminal) | MCP block + hooks.json, already there from the app's opt-in at 14:01 | yes, Terminal "shell" field, scored on folder in title | yes, 998 ms, restored to Finder | Codex 0.172 asks to trust new hooks. Untrusted, it never reports idle, so I set the idle state by hand for the test |
| Codex desktop app | not installed | - | - | skipped |
| ChatGPT app (com.openai.codex) | none, it has no hooks or MCP | yes, "Ask ChatGPT" ProseMirror field | yes, new chat, 344 ms, it replied OK | name only ("Hey Claude, ChatGPT: ..."), types into the open chat |
| Cursor agent chat | new Settings > Agents toggle "Cursor (agent chat)": ~/.cursor/mcp.json + ~/.cursor/hooks.json, backup kept | yes, "Prompt" field (aislash-editor-input) | yes, 3 sends, ~380 ms; the third ran on Cursor's real hooks only | |

Fixes:
- Cursor's MCP server starts in Cursor's own folder. It now registers with WORKSPACE_FOLDER_PATHS.
- Cursor runs its hooks in the extension host, not in the MCP process. A hook now joins the one MCP chat of that agent in the same folder. This also covers handing over waiting messages.
- Cursor hooks use Cursor's own format: beforeSubmitPrompt, stop (followup_message), afterAgentResponse (last reply).
- Chat apps are reachable by name: the Claude app and ChatGPT. Web AX is turned on for every app, since ChatGPT doesn't say it is Electron.
- The input choice follows the agent: a process with a tty types into the terminal field, an app agent into its prompt field.
- The test hook no longer adds the voice suffix. Its new form `ax-send:app:<bundle>` only works on a new, empty chat.

Needs owner:
1. Codex: open any Codex chat and choose "Trust all" on "Hooks need review". Until then Codex chats only get messages through MCP calls, never typed.
2. Delete the throwaway ChatGPT chat "Reply OK". Its menu doesn't open headless, and agent-desktop blocks cmd+shift+delete.
3. Delete the Claude app chat "OK" from phase 2.

Cleaned up:
- The Codex session file and its history line.
- The Cursor chat rows, its workspaceStorage and the ~/.cursor/projects test folders.
- The test Terminal window and /tmp/nyax2.

### 2026-11-26 18:18 UTC (agent)

Waiting on the owner: run the live test from the 25 Nov 14:51 comment (say "Hey Mac, <idle chat>: say hi back out loud" while in another app), choose "Trust all" on Codex's "Hooks need review", and delete the throwaway chats "Reply OK" (ChatGPT) and "OK" (Claude app). Accessibility delivery is built and ships in Needs You releases v1.1.0 to v1.5.0, and in-app tests passed on throwaway chats. One gap remains: when the window is unclear, the message stays in the inbox instead of asking "1 or 2?".
<!-- SECTION:DESCRIPTION:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-11-26 status check: In Review. Accessibility delivery ships in v1.1.0 to v1.6.0. Real use: on 26 Nov 14:56 UTC a real voice message was typed into an idle herdr pane in Ghostty ("ax: picked ... in Ghostty", "ax: pasted and sent"), and route learning recorded it. Later 15:12 to 15:13 runs were test-pane runs. No real delivery into a chat app window (Claude app, ChatGPT) is in the logs. Known gap stays: when the window is unclear the message waits in the inbox instead of asking "1 or 2?". Owner check: say "Hey Mac, <a Claude app chat>: say hi back" while another app is in front.
<!-- SECTION:NOTES:END -->
