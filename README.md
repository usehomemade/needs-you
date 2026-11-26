<p align="center"><img src="docs/assets/logo.png" width="128" alt="Needs You"></p>

# Needs You

A Mac app that lets your coding agents ask you things out loud. The agent calls `needs-you ask`, the app speaks the question, listens for your answer and hands the text back. If you don't answer, the question waits as a voicemail. You can also talk into any connected chat by saying "Hey Mac".

Speech recognition and speech output run on your Mac. No audio or text goes to a cloud service.

## Install

Download the DMG from [GitHub Releases](https://github.com/usehomemade/needs-you/releases/latest), or use Homebrew:

```bash
brew install --cask usehomemade/tap/needs-you
```

Runs on macOS 14 or later; the wake phrase needs macOS 26. The app updates itself.

## Quick start

1. Open Needs You and allow microphone access. The speech models download on first launch.
2. In Settings, open Agents and connect Claude Code or Codex.
3. Test it from a terminal:

```bash
needs-you ask "Shall I deploy?" --title "Deploy?"
```

## Docs

- [Agents](docs/agents.md): the `ask`, `say` and `done` commands, the MCP server and hooks.
- [Voice](docs/voice.md): wake phrase, shortcuts, languages, subtitles, sounds, do not disturb.
- [Permissions by voice](docs/permissions.md): approve risky agent actions by speaking.
- [Privacy](docs/privacy.md): what stays on your Mac.
- [Building](docs/building.md): build from source and the release pipeline.

Third-party credits are in [ACKNOWLEDGEMENTS.md](ACKNOWLEDGEMENTS.md).

## License

Needs You is free software under the [GNU General Public License v3.0](LICENSE). You can use, study, change and share it. If you share a changed version, it must stay open source under the same license.
