---
id: doc-1
title: Needs You v1 plan
type: other
created_date: '2026-11-26T19:47:33Z'
---

The first build plan for Needs You (23 Nov 2026), moved from the old tracker. It is history: the app has moved on since (local speech models instead of ElevenLabs, a public repo, Developer ID signing).

## Goal

Agents call `needs-you ask "..."`; the Mac speaks it (ElevenLabs TTS), listens for the owner (VAD), transcribes (ElevenLabs STT), returns JSON. No answer after 30 s twice: publish an artifact and notify.

## Decisions

* Repo usehomemade/needs-you (private), local ~/Projects/needs-you. SwiftPM, two targets: app (SwiftUI menu bar + window) and CLI.
* CLI to app: Unix domain socket in ~/Library/Application Support/Needs You/ (dir mode 0700, peer uid check).
* Key: ELEVENLABS_API_KEY from the team's secret store, piped at install into the app's own Keychain item (app writes it itself, so no ACL prompt).
* Signed with the Apple Development identity (same as another app of the owner) so mic permission survives rebuilds.

## Status (done, 23 Nov)

- [X] Scaffold, build (commit 000bfe5 on usehomemade/needs-you main)
- [X] TTS (eleven_flash_v2_5, voice Sarah) + STT (scribe_v3 with keyterms) tested with generated audio, muted
- [X] Queue: second ask waited for the first
- [X] No-answer path (--simulate-silence --wait 2): published a private preview page, exit 2
- [X] Install script, live test with the owner: transcript "hello. Can you hear me?"
