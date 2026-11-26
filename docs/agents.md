# Agents

Agents talk to Needs You through the `needs-you` command or through an MCP server. Both do the same thing.

## Commands

```bash
needs-you ask "The staging deploy is green. Shall I promote it to production?" \
  --title "Promote to production?" \
  --context ./tmp/promote-notes.md
```

`--context` takes a file or text. The app shows it and keeps it with the voicemail. `--project <label>` sets the project name; the default is the folder you run it in.

`ask` waits its turn if another conversation is running, then prints one JSON line:

```json
{"status":"answered","conversation_id":"20261123-174838-181a","transcript":"Yes, go ahead.","turns":[]}
{"status":"voicemail","conversation_id":"...","state":"The user did not answer, left as a voicemail.","turns":[]}
```

Exit code 0 means answered or interrupted, 2 means voicemail (or `no_answer` with `--once`), 1 means error.

Keep the spoken text to one or two sentences and put commands, links and detail in `--context`. Never put secrets in either. `ask` can block for minutes, so run it with a long timeout.

## Follow-ups

```bash
needs-you say "Done. Anything else before I merge?"   # speaks, listens, prints the next transcript
needs-you say "Merging now." --no-listen              # speaks only
needs-you done "Thanks, bye."                         # optional last words, then ends it
```

Keep calling `say` while the person keeps talking, and call `done` when they finish or `say` returns `no_answer`. An answered conversation closes by itself after 3 minutes without a `say`. `--id <conversation_id>` pins `say` or `done` to one conversation. `needs-you status` shows what the app is doing.

## Interrupting

Saying "Stop, Claude" while it speaks cuts the voice off and listens. The agent gets `"status":"interrupted"` with `spoken_until` (roughly what was heard) and the `transcript` of what the person said next. The conversation stays open, so answer with `say`.

Escape also stops the voice, from any app. Nothing listens afterwards and the conversation ends. The agent gets an empty transcript and a `state` saying so.

`transcript` has fillers like "uh" and stutters removed. `transcript_verbatim` has the exact words when they differ. Change this in Settings, Microphones, Transcript.

## Do not disturb

While do not disturb is on, `ask`, `say` and `done` return `{"status":"voicemail"}` at once. Nothing is spoken and the mic stays closed. The text is kept as a voicemail with the time, the folder and the terminal pane. When the person answers later, the answer is typed into your chat. Carry on with other work and don't ask again.

## Connecting a chat

Settings, Agents, Reach by Voice connects Claude Code and Codex. For Claude Code it runs:

```bash
claude mcp add --scope user needs-you -- needs-you mcp
```

For Codex it adds a marked block to `~/.codex/config.toml` and keeps a backup next to it.

`needs-you mcp` is an MCP server on stdio. It registers the chat with the app (process, folder, session id, and the herdr or tmux pane) and sends a heartbeat every 30 seconds. The chat disappears when its agent process ends. Its tools:

- `status`: one line on what the chat is working on.
- `ask`, `say`, `done`: same as the commands.
- `inbox`: messages waiting for this chat.

`needs-you chats` lists the registered chats.

Connecting also installs hooks (`needs-you hook <event> --agent claude|codex`) so the app knows each chat's state and recent prompts. Claude Code gets SessionStart, UserPromptSubmit, PostToolUse, Stop, Notification and SessionEnd in `~/.claude/settings.json`. Codex gets SessionStart, UserPromptSubmit and Stop in `~/.codex/hooks.json`. A backup named `<file>.needs-you-backup` is kept.

## Agent instructions

On launch the app writes `~/.claude/needs-you.md` and adds one import line, `@needs-you.md`, to `~/.claude/CLAUDE.md` between `<!-- needs-you:begin -->` and `<!-- needs-you:end -->`. It tells Claude Code when and how to ask. The text lives in `Sources/NeedsYouShared/AgentInstructions.swift`.

## Test flags

For development only: `--mute`, `--tts-out <file>`, `--input-file <audio>`, `--simulate-silence`, `--wait <seconds>`, `--vad-file <audio>`.

## Chat apps

- **Claude app**: Settings, Agents, Claude app adds the Needs You MCP server to `~/Library/Application Support/Claude/claude_desktop_config.json` (a backup is kept). The app reads it at launch, so Settings offers Restart Claude. Its chats can then answer out loud. The app runs one server for all its chats, so it never shows up as a chat of its own; voice reaches it as an app ("Hey Claude, new chat on Claude desktop, ...").
- **ChatGPT app**: its Codex tasks read `~/.codex/config.toml`, so the Codex switch covers them. Plain ChatGPT chats only take connectors on the internet and can't reach a server on this Mac. "Hey Claude, use ChatGPT to ask ..." still opens a new chat and types the question; the answer stays on screen.
