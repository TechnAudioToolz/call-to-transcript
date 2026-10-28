# To do

Plan (2026-10-28): get the Mac version solid and well tested first, the same way as Audiobook Maker, then
publish to GitHub with an offline installer.
**Goal:** word-for-word transcripts of videos and recordings, with speakers, for studying, test prep and
looking at language patterns.

## Done on day 1 (2026-10-28)
- [x] Engine: sound out of the video, Parakeet "ultra" speech recognition with word times, speaker separation,
      words matched to speakers, paragraphs per speaker. Keeps um, uh, repeats.
- [x] macOS 14 crash in speaker separation fixed (Apple's Core ML CPU bug; FluidAudio vendored with the fix)
- [x] First run after an install can fail in the speech model: retries on the graphics chip automatically
- [x] Window like Audiobook Maker: videos on top, audio below, settings on the right, log at the bottom,
      toolbar (+, start/pause/resume, stop, output folder, verbose, settings, donate, coffee cup)
- [x] Queue with up/down arrows and "Queued · #2", saved between launches
- [x] Saves PDF and DOCX (plus TXT, SRT, VTT if ticked), timestamps on or off
- [x] Rename speakers ("Person 1" -> "Teacher"): the saved files are written again
- [x] Quick replies split off better (denser speaker windows)

## Now: test and polish
- [ ] Try it on real study videos of different kinds: one speaker (lecture), two (interview), many (Zoom).
      Note words heard wrong and speaker mix-ups
- [ ] Long files (2-3 hours): memory, time, progress and time left
- [ ] MKV / WebM / AVI: needs ffmpeg inside the app (today it uses Homebrew's if present)
- [ ] **Closed captions:** when a video carries a subtitle or caption track, save it too ("Captions from the
      video" as an extra file), and maybe compare it with what was heard
- [ ] **Words to know** (names, jargon) per file or for all files, to steer spelling (FluidAudio has custom
      vocabulary support)
- [ ] Words the recogniser was unsure of: show them faintly in the preview, optionally mark them in the PDF/DOCX
- [ ] Click a paragraph's time in the preview to play the video from there
- [ ] Notification when a transcript is finished (like Audiobook Maker)
- [ ] App icon
- [ ] Settings: choose the default formats there too; Check for updates (like Audiobook Maker)
- [ ] VoiceOver pass

## Publish
- [ ] Offline edition DMG: the app with the models inside (about 700 MB), like Audiobook Maker's
- [ ] README screenshots (public-domain or self-made videos only)
- [ ] Create the GitHub repo and the first release (ask first)

## Later
- [ ] Other languages (Parakeet ultra knows 25 European languages)
- [ ] Linux, then Windows

## Call Transcriber (paused 2026-10-28)
- [x] Engine call mode (--me/--them): tested on a synthetic two-voice call, Me/Client correct, speaker echo removed
- [x] App: Record/Pause/Stop, mic + Core Audio process tap, level meters, menu bar/Dock REC sign, consent notice
- [ ] Check the app run on the test call wrote PDF/DOCX (was in progress)
- [ ] Live recording test on a real call (needs Allow for Microphone and System Audio Recording)
- [ ] README for Call Transcriber; merge the recorder into Transcript Maker later
