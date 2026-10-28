# Transcript Maker

A Mac app that turns videos and recordings into word-for-word transcripts, with each speaker labeled
(Person 1, Person 2, …). Made for studying lectures and webinars, preparing for tests, and looking closely at
how people talk: every "um", "uh", false start and repeated word is kept.

Everything runs on your Mac. Nothing is uploaded.

- **Drop videos on top, audio below.** MP4, MOV, M4V, MKV, WebM and more; MP3, M4A, WAV, FLAC and more.
  Files are transcribed one after another, in the order shown; the arrows change the order.
- **Who said what.** Voices are told apart automatically. If you know how many people talk, say so for better
  results. Rename "Person 1" to "Teacher" and the saved files are written again.
- **Save as** PDF and Word (DOCX), plus plain text, SRT and VTT subtitles if you like, with timestamps before
  each paragraph so a passage is easy to find in the video.
- **Toolbar:** add files, pause, stop, the output folder, verbose mode (what the engine is doing), settings,
  donate, and a coffee cup that keeps the Mac awake for long queues.

Needs macOS 14 Sonoma or newer on Apple Silicon (M1 or later).

## How it works

1. The sound is taken out of the video (16 kHz mono).
2. NVIDIA's Parakeet speech recognition ("ultra" build, 2.1 % word error rate on LibriSpeech test-clean) hears
   the words, with the time of each one. It runs on the Mac's Neural Engine, roughly 20-30 times faster than real time.
3. pyannote's speaker models (segmentation, WeSpeaker embeddings, VBx clustering) work out who spoke when.
4. Each word goes to the voice speaking at that moment, and the words are grouped into paragraphs per speaker.

Both models run through [FluidAudio](https://github.com/FluidInference/FluidAudio). A copy of it lives in
`app/Vendor/FluidAudio` with one fix for macOS 14 (see `VENDORED.md` there).

**No transcript is perfect.** Expect slips with people talking over each other, heavy accents, music under
speech, and unusual names. Two similar voices can be merged, or one voice split in two. The timestamps make it
quick to check a passage against the video.

## Build

```bash
cd app
./build.sh --open
```

The first transcript downloads the models (about 650 MB, once) into
`~/Library/Application Support/Transcript Maker/models`.

From Terminal, the same engine:

```bash
app/.build/release/transcribe-cli lecture.mp4 --speakers 2 --out ~/Desktop
```

## License

MIT. Parakeet (CC-BY-4.0, NVIDIA), FluidAudio (Apache 2.0) and the pyannote models keep their own licenses.
