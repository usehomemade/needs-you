# Privacy

Everything runs on your Mac. No audio, transcripts or text are sent to a cloud service.

- Speech to text, wake word detection, speaker check and text to speech all run locally on the Neural Engine, using models downloaded once to your Mac.
- The `needs-you` command and the app talk over a Unix socket in `~/Library/Application Support/Needs You/`. The folder is mode 0700, the socket 0600, and the peer's user id is checked.
- History (the last 200 requests), voicemails and do not disturb state are files in that same folder.
- The only network traffic is model downloads, and update checks against this repository's GitHub Releases.
- Hooks and the agent instructions only edit files in your home folder, and keep backups. See [Agents](agents.md) and [Permissions](permissions.md).

Third-party models and libraries are credited in [ACKNOWLEDGEMENTS.md](../ACKNOWLEDGEMENTS.md).
