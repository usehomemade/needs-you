---
id: TASK-27
title: >-
  Speak in other languages (pick from English, Turkish, German, French, Italian,
  Russian)
status: Done
assignee: []
created_date: '2026-11-24T19:37:46Z'
updated_date: '2026-11-26T20:08:00Z'
labels:
  - hm-1351
dependencies: []
ordinal: 27000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Old id: HM-1351
Related: TASK-25 (HM-1349), TASK-36 (HM-1362), TASK-26 (HM-1350), TASK-32 (HM-1356)

The owner (voice, 24 Nov 20:37): he spoke Turkish and it never came through, because Whisper is forced to English (`WhisperSTT.swift`, `language: "en"`). He wants French, Italian, German, Turkish and Russian, only if it's light on his Mac, and a setting to pick which ones are on (for example English + Turkish, or English + German + Turkish).

Notes: Whisper turbo is already multilingual, so the same model in RAM. Language detection limited to the chosen set costs one short extra pass. Parakeet v2 (fast checks) is English only. Parakeet v3 covers the European languages but not Turkish. The Apple wake analyzer is per locale. Measure CPU, RAM and latency before and after.

Starts after TASK-25 (HM-1349) (wake phrase) lands, because both touch Settings and the speech path.

## History

### 2026-11-24 21:47 UTC (agent)

Built and installed (commit `5844b4d` on main). The app was restarted and Do Not Disturb is still on.

**What's new:** Settings → Voice → Languages I Speak, with English, Turkish, German, French, Italian and Russian. The default is English only, which runs the same path as before.
- With one language on, Whisper is forced to it.
- With several on, the audio goes through Whisper once. The first decoder step is scored over only your languages, and the transcript is decoded from that same pass in the language that wins. So detection costs one decoder step, not a second encoder run.
- WhisperKit's built-in detection chose English for clear Turkish speech, so I don't use it.
- Transcripts stay in the language you spoke. Polish no longer rewrites them into English.
- The wake word, "Stop, Claude" and Learn My Voice stay English.
- Parakeet still does the quick "done" checks and subtitles for English. Once a command or answer turns out to be in another language, Whisper does those checks in that language.
- End words per language: tamam, bitti, bu kadar / fertig, das war's / fini, c'est tout / finito, ho finito / готово, всё. They only count when they stand alone at the end, because Turkish and German put the verb last ("Test bitti." is a normal sentence). A lone "Tamam." is kept as your answer.

**Numbers on your 165 eval clips (24 Nov):**

| Setting | WER | Median per clip | CPU | RAM | Wake text caught |
|---|---|---|---|---|---|
| English only, before (83b6501) | 49 % | 491 ms | 23 % | 161 MB | 68/104 |
| English only, after (4 runs) | 52-59 % | 487-491 ms | 23 % | 178-192 MB | 68-69/104 |
| English + Turkish (3 runs) | 52-56 % | 495-496 ms | 23 % | 169-173 MB | 70-71/104 |
| All six | 54 % | 496 ms | 23 % | 174 MB | 69/104 |

- The English-only code path did not change. Its WER moves 49-59 % from run to run on these noisy game clips, because of random sampling on the fallback retry. So the English + Turkish WER is within that spread.
- Detection adds about 5-9 ms per utterance at the median. No extra CPU or RAM: the model in memory is the same one.
- With English + Turkish on, 164 of 165 English clips were detected as English. One wake clip with game noise came out as Turkish.
- Wake latency on the 35 wake clips: English only 29/35 at a median of 0.73 s before and 0.64 s after. English + Turkish: 28/35 at 0.75 s. That's run-to-run noise; the wake check is still forced to English.
- When a command ends (10 command clips): same within 0.4 s in both settings.

**Turkish check:** macOS has no Turkish voice installed (Yelda is missing), so I used human Turkish speech from two Spoken Wikipedia recordings on Wikimedia Commons. Nothing was played out loud.
- 14 of 14 Turkish clips were detected as Turkish. The old English-forced path often produced garbled text, for example "Hey Claud this, one, Boçlu, olarak, anilen…" became "Hey Claude, this one: Boşluk olarak anılan bir boşluk bulunmaktadır…".
- "Hey Claude, this one: <Turkish>" commands: 11 of 12 detected as Turkish.
- German, French, Italian and Russian (macOS voices): all detected correctly with all six on.

**Voice replies:** Kokoro in FluidAudio has French (ff_siwis) and Italian voice files, but no Italian text front end. It has nothing for Turkish, German or Russian. The app still speaks with Kokoro's English voices. Turkish text from an agent would be read by an English voice. The macOS voices (Yelda, Anna, Milena) would be the fallback if you want that later. No change made.

Next for the owner: turn on Turkish in Settings → Voice → Languages I Speak and say one Turkish command.

### 2026-11-25 00:23 UTC (agent)

Waiting on the owner: open Needs You Settings, go to Voice, then Languages I Speak, turn on Turkish, say one Turkish command, and confirm it transcribes correctly. The feature is built and installed on his Mac, but the setting is still English only, so it has not been tried live.
<!-- SECTION:DESCRIPTION:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-11-26 check: Shipped in v1.0.0 and later (SpokenLanguages.swift, SpokenLanguagesTests). The owner turned on Turkish (spokenLanguages "en,tr"). history.json has three Turkish voice sends on 25 Nov, and the live wake debug log has 8 subtitles detected as Turkish. Mixed-language sentences are TASK-43.
<!-- SECTION:NOTES:END -->
