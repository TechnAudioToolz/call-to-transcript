# To do

**Goal:** record client calls (my microphone and the Mac's sound as separate tracks) and turn them into
word-for-word transcripts with "Me" and the client as speakers, saved as PDF and DOCX. Branched from
Transcript Maker; the recorder may move into Transcript Maker later.

## Day 1 (2026-10-28)
- [x] Engine call mode (--me/--them): tested on a synthetic two-voice call, Me/Client correct, speaker echo removed
- [x] App: Record/Pause/Stop, mic + Core Audio process tap, level meters, menu bar/Dock REC sign, consent notice
- [x] App run on the test call wrote PDF and DOCX (Me and Client); Call.m4a mixes both sides
- [x] Installed in /Applications (rebuild + `ditto` to update; ad-hoc signed, so macOS asks for permissions again after each update)
- [ ] Live recording test on a real call (needs Allow for Microphone and System Audio Recording)
- [x] README for Call Transcriber
- [ ] Later: move the recorder into Transcript Maker
- [x] App icon from the artwork in app/Resources/AppIcon-source.jpg (swift make_icon.swift)
- [x] Published on GitHub

## Next
- [ ] If the output device changes mid-call (AirPods connect), keep recording the other side
- [ ] Optional echo cancellation on the microphone (Apple voice processing) for calls without headphones
- [ ] Offline edition DMG (the models inside), like Transcript Maker's
