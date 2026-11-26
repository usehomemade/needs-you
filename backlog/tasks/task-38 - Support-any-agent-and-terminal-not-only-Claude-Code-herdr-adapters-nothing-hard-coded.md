---
id: TASK-38
title: >-
  Support any agent and terminal, not only Claude Code + herdr (adapters,
  nothing hard-coded)
status: To Do
assignee: []
created_date: '2026-11-25T11:37:24Z'
labels:
  - hm-1364
  - needs-owner
dependencies: []
ordinal: 38000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Old id: HM-1364
Related: TASK-46 (HM-1375), TASK-45 (HM-1374)

The owner (voice, 25 Nov ~12:37): he runs Needs You with herdr and Claude Code. Other users will use other agent environments. Can we support those without hard-coding anything?

**Today:**

* The ask/say/done CLI already works for any agent that can run a shell command.
* The tie-in is in delivery and discovery: herdr is mentioned about 40 times across 10 source files (Router, Conductor, VoiceCommands, DoNotDisturb, WakeListener…), and there are about 38 Claude Code paths (`~/.claude`, CLAUDE.md, transcripts).

**Proposal:** two small adapter layers.

1. **Session host:** list chats, type text into one, focus one. herdr first, then tmux, iTerm2, Ghostty, Terminal.app and the VS Code / Cursor terminals.
2. **Agent:** install the instructions file, hooks for "waiting" and "permission", and reading summaries. Claude Code first, then Codex CLI (AGENTS.md), Cursor, Gemini CLI, opencode and Pi.

Settings would pick which adapters are on, with auto-detect.

**Needs owner:** go or no-go, and which agents and terminals matter first.

## History

### 2026-11-25 12:10 UTC (agent)

The owner (voice, 25 Nov ~13:15):
- **Go:** "we are building Claude Code or Claude Desktop or Codex, a universal entry point for this app."
- **New problem:** matching by chat name sometimes picks the wrong agent today. He asked how chats get matched once there are many agents across apps.

**Plan:** design first, as an artifact, then build.
1. One chat registry across adapters (herdr, tmux, iTerm, Ghostty, Claude Desktop, Codex…). Each chat gets a stable short spoken handle: its name, plus a number when names clash.
2. Matching ranks title, folder, recent activity and phonetic closeness. When the top two are close, it asks out loud ("homemade or homemade-dev?") instead of guessing.
3. The island shows the target before sending (as today), and "no, the other one" re-routes.
4. A "list my chats" voice command.

### 2026-11-25 12:17 UTC (agent)

Design v1 published: [private preview link removed] (today's routing, the wrong matches in history.json explained, what each terminal/agent exposes, adapters + chat registry + matcher + "list my chats", 11-PR plan; first wave herdr + Claude Code + Codex about 30 to 43 h). Waiting on the owner for the 6 open questions at the bottom; no code changed.

Wrong-match causes found:
1. Stale Claude Code titles: the "homemade" tab is titled "Recipe notes" (ai-title from 9 Nov); 42 of 71 sends showed that name.
2. Any words before a colon count as a chat name: "two questions: ..." (25 Nov 12:07) and "one more thing: ..." (11:45) opened new chats in ~ instead of going to the chat in front (the two "voice" tabs).
3. A named chat that is in front gets byFocus=true, so "Homemade. ..." (11:52) was refused when focus moved during the countdown.
4. Matcher weighs title, folder and tab label equally, no recency or phonetics, ignores herdr workspace labels.

### 2026-11-25 12:22 UTC (agent)

PR 1 shipped to main (62b64f1, merge 2c40576) and installed locally (`needs-you status`: Ready, listening).
- New `ChatMatcher` in NeedsYouShared: tab label 1.0 > folder 0.85 (none for home-folder chats) > title 0.7. Junk labels ("1", "voice", "continue"...) and labels two chats share are ignored; "voice: X" counts as X.
- Bug 2: words before a colon that match no chat and no project folder now send the whole sentence to the chat in front. Switch: `ChatMatcher.unmatchedName` (`.chatInFront` / `.ask`).
- Bug 3: a named chat no longer counts as "this one", so a focus change during the countdown doesn't cancel it.
- Routing log: each send's history entry has `route` (heard name, top 3 with score and field, why); also `route: ...` lines in audio.log.
- 11 unit tests built from his real chats and the history.json cases; all 36 tests pass.
Stays Todo + Needs owner for the 6 open questions on the design page.

### 2026-11-25 12:35 UTC (agent)

Design v3 published on the same page: [private preview link removed] (shows the MCP registry, how messages get into chats, routing with a local model, migration plan).
- Answer to the owner: we no longer need terminal names. Chats register through `needs-you mcp` plus hooks (session id, cwd, prompts, state, pane id from the agent's own env). An MCP server can't start a turn in an idle chat, so delivery tries, in order: Stop hook handover for busy chats (Claude Code, Codex, Gemini, works today); a Claude Code channel for idle chats (preview, needs `--dangerously-load-development-channels` with a warning screen every launch); typing into the pane the agent reported.
- Routing uses Apple's on-device model. Measured on this Mac: 430 to 520 ms per pick, sensible picks on his 11 chats. The model's own confidence numbers were useless, so "sure enough" comes from agreement with the fast matcher and his past picks. To reach 300 ms, the model starts on the partial transcript.
- When unsure, the island shows 1 to 4 and he answers by voice or number key; each pick is saved to routing-memory.json.
- First wave about 36 to 49 h in 7 PRs. 5 open questions for the owner at the bottom. Stays Todo + Needs owner for his OK.

### 2026-11-25 12:48 UTC (agent)

The owner, 25 Nov ~13:50: no typing into agent terminals at all. His voice reaches an agent only as an MCP tool-call response (ask answers plus an inbox). He types manually when he wants to start something himself.

### 2026-11-25 12:49 UTC (agent)

PR 2 merged (54652cf) and installed: `needs-you mcp` (stdio MCP server with status/ask/say/done/inbox, registers the agent's chat, 30 s heartbeat) plus the app's chat registry, which lists only agents that registered, joined by agent pid. Connecting is opt-in in Settings → Agents → Reach by Voice (Claude Code via `claude mcp add`, Codex via a marked block in config.toml). `needs-you chats` lists them; it shows 0 until he connects.
Plan change from the owner: nothing will be typed into terminals. Voice reaches an agent only as an MCP tool result or a hook response (inbox, delivered on the chat's next tool call or turn end). The old typed "Hey Claude, <chat>:" path stays until the MCP path replaces it, then that code is removed.
Also found: install.sh can relaunch the old binary (the app came back before the copy finished); fixed in the next PR.

### 2026-11-25 12:54 UTC (agent)

PR 3 merged (rebased onto the new root, merge a861339) and installed. `needs-you hook <event>` reports state, recent prompts and the last reply. It hands over waiting voice messages as hook responses (Stop: block + reason; UserPromptSubmit and PostToolUse: additionalContext), and MCP tool results carry them too. Nothing is typed into a terminal. Connecting in Settings → Reach by Voice now also adds the hooks to Claude Code settings.json and Codex hooks.json; Needs You finds its entries by their command and keeps a backup. install.sh now restarts an app that came back with the old binary.

### 2026-11-25 13:00 UTC (agent)

PR 4 merged (b339417, rebased onto the new root) and installed. Once any chat is connected, "Hey Claude, <chat>: …" only targets connected chats. The message waits in that chat's inbox and the island shows "Queued for <chat>". The chat gets it on its next tool call, turn end or prompt, and nothing is typed. "This one" now means the connected chat he typed into or spoke to last. If nothing is in front, it asks instead of opening a chat. Voicemail answers also go to the connected chat's inbox. The old typing path stays only until an agent is connected; that code gets removed once the MCP path covers everything (new chats still open through herdr). Checked on the installed app: register, then the chat shows in `needs-you chats`, then it disappears when the process ends.

### 2026-11-25 13:02 UTC (agent)

PR 5 merged (4e95277) and installed. When the name matcher is unsure, Apple's on-device model picks the chat. It sees only the chat number, name, folder and what each chat works on, and nothing leaves the Mac. The model loads on "Hey Claude" and starts guessing from the partial transcript, so the pick is usually ready when he stops talking. A pick counts only when it agrees with the matcher or with one of his earlier picks. Otherwise Needs You asks, with the model's pick first. Tested on 6 sample phrasings: 6/6 correct, 390 to 450 ms warm, about 800 ms cold.

### 2026-11-25 13:06 UTC (agent)

PR 6 merged (5912e1d) and installed. "Which chat?" now numbers the chats: "1, homemade. 2, needs-you. Or 3, garden-planner?". He can press 1 to 4, or say the number or the name. The keys are registered only while the question is open. Each pick, and each named message that went out, is saved in routing-memory.json (the last 200). The key is the chat's folder, or its name when there is no folder, so a pick still applies after the chat restarts. The same words go to the same chat next time, and recent picks are fed to the on-device model as examples.

### 2026-11-25 13:09 UTC (agent)

Bug, the owner 25 Nov 14:08: the which-chat question (garden-planner or Recipe notes) got the answer "two", then said it didn't send. The log shows the app heard its own question ("Which?") as the answer, then cancelled. The same thing happened at 14:03. Sent to the build agent: wait for the question to finish, accept two/2/iki/name, re-ask once, and never drop the message silently.

The owner also asked how a voice message can START a turn in an idle chat with MCP only. It can't. See the reply in chat; his decision is pending.

### 2026-11-25 13:10 UTC (agent)

PR 7 merged (d90de2c) and installed. "Hey Claude, list my chats" reads out the connected chats, what each one is doing, and how many messages are waiting for it. The main window has a Chats section (⌘3) that shows the same list. Its detail view shows the queued messages, recent prompts and last reply. Per the owner's open question, the terminal-typing path stays in place until he decides how an idle chat should get a voice message.

### 2026-11-25 13:17 UTC (agent)

The owner, 25 Nov ~14:20: no per-terminal typing code (Ghostty, Terminal, Orca… is too much custom code) and no Claude Code channel (the app must stay agent-agnostic). New idea: a local model that controls the computer. It finds the right app/tab/chat on screen, focuses it and pastes what he said, so no per-app code. Answer and options in chat; his go is pending.

### 2026-11-25 13:23 UTC (agent)

Fixed the "which chat?" bug the owner hit at 13:03 and 13:08 (merged d06ef08, installed). Three causes. Our own question reached the mic. "Yes" did not count as picking the only chat offered. And an unclear answer threw the message away.
- Needs You now waits 0.35 s after the question before it listens. It drops the question's own words from the start of what it heard; it matches them loosely, so "Witchchat" counts as "which chat".
- It accepts "two", "2", "number two", "the second (one)", iki/ikinci, zwei, a lone "To." and the chat's name. "Yes" picks it when there is one choice. The 1 to 4 keys still work.
- If the answer is unclear, it asks once more. If that also fails, the message is kept for 5 minutes and the island says "Not sent, say the chat". Saying "Hey Claude, <chat>" or "Hey Claude, two" then sends it.
- The on-device model now warms up at launch and on "Hey Claude", so the cold 1.2 s pick should not repeat.
- New silent test `needs-you clarify-test --title "a|b" --vad-file <wav> --mute` runs the real listening path with a file as the mic. Results: question echo then "Two." picks 2. Echo then "Number two, please" picks 2. Echo only is unclear, asks again and nothing is sent wrongly.
Typing into terminals stays in place while the owner decides about idle chats.

### 2026-11-25 13:55 UTC (agent)

Found where the 13:48 voice message went (merged 13650fe, installed). Routing and the queue both worked. Then a background subagent of that chat ran a tool. Its PostToolUse hook runs in the same agent process, so it took the inbox and the text went to the subagent as additionalContext. The subagent's transcript (agent-a5ce6f96…) has it at line 74. The main chat never saw it.

Fix:
- Hooks that fire inside a subagent (Claude Code sends `agent_id`) now only mark the chat alive. They never take its messages or change its state.
- MCP tool results no longer carry messages, since subagents can call those tools too. Messages are handed over only by the chat's own Stop, UserPromptSubmit or PostToolUse hook, or the explicit `inbox` tool. Nothing is typed.
- History now says "Queued" until the chat really takes the message, then "Delivered via <hook> at <time>".
- Every delivery step is logged in audio.log (`deliver:` lines: queued, handed over, chat ended with messages waiting). A new hooks.log has one line per hook run (event, pid, subagent, count; no message text).
- The registered chat's title no longer repeats its status.

Silent test with a stand-in chat process: a subagent PostToolUse took nothing, Notification took nothing, the main Stop took the message, a second Stop took nothing, and history went from queued to delivered. That test left one "To test chat" entry in his history.

### 2026-11-25 18:17 UTC (agent)

Tracker hygiene: moved from In Progress to Todo and added Needs owner, because nobody is working on it right now. The MCP, routing and AX delivery code is built and installed, and it's merged into local main at f3f4465, which isn't pushed yet. It's waiting on the owner's live test together with HM-1374. After he says "works, release", I push main, which releases automatically.
<!-- SECTION:DESCRIPTION:END -->
