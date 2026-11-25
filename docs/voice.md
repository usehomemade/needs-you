# Voice

## Hey Claude

Turn on "Listen for Hey Claude" in the menu bar or in Settings. Then say:

- "Hey Claude, this one: run the tests again" goes to the chat in front.
- "Hey Claude, trip planner: book the hotel for Friday" goes to the chat whose title, folder or terminal tab matches.
- "Hey Claude, new chat in website: look at the failing deploy" opens a new terminal tab in the closest folder under `~/Projects` and starts `claude` with your message.

If the chat is idle (its turn has ended), the message is typed into it, in whatever app shows it (see below). If it is busy, or a check fails, the message waits in that chat's inbox and arrives on its next tool call, turn end or prompt. For 2 seconds before it is sent, the island shows the chat it goes to. Esc or saying "cancel" stops it. Every message ends with a line telling the agent it came by voice, so it answers out loud.

### Typing into an idle chat

Needs You types through macOS Accessibility, the same way in every app (Terminal, Ghostty, iTerm, VS Code, Cursor, the Claude app), so it needs Accessibility access (System Settings, Privacy & Security, Accessibility). The code is `Sources/NeedsYou/AXDelivery.swift`.

1. It finds the app that shows the chat from the agent's processes. For herdr and tmux it first selects the chat's pane with their own focus command, by the pane id the agent reported, and only if that pane really runs the agent.
2. It scores each window and tab: the chat's folder in the window's title or document, its last reply or prompt on screen, the pane's own text. It goes on only when one place clearly wins (`AXMatch`).
3. It waits until you have not typed or moved the mouse for 1.5 seconds.
4. It brings that window and tab to the front and focuses the chat's text field. In an editor or a chat app this is the field labelled as the terminal or the prompt.
5. It checks the app, window, tab and field, pastes the message as one line through a clipboard item that clipboard managers skip, checks again and presses Return.
6. It puts back your app, window, text field, the tab that was showing, the pane and the clipboard.

If any check fails, nothing is sent and the message waits in the inbox. Test hooks that never touch real chats: `needs-you voice-test "<text>" --title ax-send:<agent pid>` or `ax-scan:<agent pid>`. They only work for a chat whose folder has a `.needs-you-axtest` file, never for one in the main herdr session; `tools/ax-proof/fake-agent.py` is a stand-in chat. `--title ax-send:desktop` works only while the Claude app shows a new, empty session.

Change the phrase in Settings, Hey Claude, Wake phrase. The field warns about phrases that are very short or common ("hey you", "hey Siri"). Test listens for 20 seconds and shows what it heard.

Speech before the wake word is recognized on the Mac with Apple's SpeechAnalyzer (macOS 26 or later). After the wake word, Whisper large-v3-turbo transcribes your words.

## Your voice

Settings, Hey Claude, Learn My Voice reads six short lines for you to repeat (about a minute). After that, "Hey Claude" only counts in your voice, and your turn ends when only other voices are left.

Training (Window, Training) records up to 30 minutes of your voice while music, a game or a video plays. Learn From Recordings then improves the voiceprint.

## Your turn shortcut

Default Option+Shift+Space, changeable in Settings, Hey Claude. It does the same as the wake phrase without the wake word or the voice check, and works even when listening is off. Press it again to finish.

## Interrupting

Say "Stop, Claude" while it speaks, or press Escape. See [Agents](agents.md#interrupting) for what the agent receives.

## Do not disturb

Say "Hey Claude, good night" or "do not disturb", or use the switch in the menu bar or Settings. The menu bar icon becomes a moon. It has no timer and survives restarts. While on, agents can't speak, play sounds or open the mic. What they wanted to say is kept as voicemails.

"Hey Claude, I'm back" or "good morning" turns it off and reads the voicemails in order. After each one you have 8 seconds to answer, and the answer is typed into that agent's chat. Say "next" to skip or "stop" to keep the rest for later. "Hey Claude, what did you work on last night?" speaks a summary per chat.

## Languages

Settings, Microphones, Languages I Usually Speak lists English, Turkish, German, French, Italian and Russian (default English). With Only These Languages off, Whisper can still follow a language you didn't pick once it is clearly detected. With it on, only your languages are considered. Transcripts stay in the language spoken.

Agent replies are spoken in the language they are written in, sentence by sentence, so a reply that mixes languages switches voice partway.

## Subtitles and island

While you or Needs You talk, large subtitles show at the bottom of the screen with the mouse. Your words are white and Needs You's are warm peach. Turn them off with Subtitles on Screen in Settings.

A black island at the top of the screen shows what the app is doing: wake heard, listening, thinking, sending, speaking, done. On a MacBook it grows out of the notch. Settings, Voice, Island style picks automatic, MacBook notch or external monitor.

## Sounds

The default set, Rosewood, is soft marimba and log drum, made from CC0 recordings listed in [ACKNOWLEDGEMENTS.md](../ACKNOWLEDGEMENTS.md). Settings, Voice, Sounds switches to Classic.

## Models

Settings, Models lets you pick the speech-to-text model (Whisper large-v3-turbo, Whisper large-v3, distil-large-v3, Canary 1B v2, Parakeet v3 or v2, Cohere) and the speaker check. Each downloads the first time you use it. With an iPhone nearby, Two mics can use its microphone too.

Text-to-speech uses Kokoro for English, with Supertonic-3 for other languages. Pick the voice in Settings, Voice.
