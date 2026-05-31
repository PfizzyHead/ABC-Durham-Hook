# Meeting Live Transcribe

A small **Windows desktop app** (Electron) that taps your system audio — i.e.
whatever a meeting app is playing (Zoom, Teams, Google Meet, native *or* in a
browser) — and shows a **real-time, fully-local transcription** using Whisper.

- 🔒 **Fully local inference.** Your audio never leaves the machine. The Whisper
  model weights are downloaded once from Hugging Face on first run, then cached
  and used offline.
- 🎧 **Passthrough by design.** Capture uses WASAPI **loopback**, a
  non-destructive tap on the output device — so the meeting keeps playing to
  your Bluetooth earbuds normally. The app only *listens*; it never replays
  audio (which would cause feedback).
- 🪟 **Works with any meeting source.** Because it captures at the OS audio
  layer, it doesn't care which app the meeting runs in.

> **Status: Phase 2.** Live captions now use an overlapping sliding window
> (no clipped words at boundaries), tag each line with a `[mm:ss]` timestamp,
> let you pick the Whisper model size, and **autosave** the transcript to disk
> continuously. See *Roadmap* below.

## How it works

```
Meeting app (any)
      │  audio rendered to your default output (earbuds)
      ▼
 WASAPI loopback tap  ──►  Electron app
                              ├─► AudioContext @ 16 kHz → 6s chunks
                              │       └─► Whisper (Transformers.js, WebGPU/WASM)
                              │               └─► live transcript (saveable)
                              └─► (no playback — passthrough is automatic)
```

## Requirements

- Windows 10/11
- [Node.js](https://nodejs.org/) 18+ (to install/run)
- A GPU with WebGPU helps a lot (Whisper falls back to CPU/WASM otherwise)
- Internet access **on first run only**, to download the model weights

## Setup

```bash
npm install
npm start
```

First launch downloads the Whisper model (`whisper-base.en` by default), so the
first run takes a minute. Then:

1. Start your meeting and make sure its audio is playing to your normal output
   (your earbuds).
2. Pick a **Model** size (start with `base.en`) and click **Start**, then
   approve the screen/audio share prompt.
3. Watch the live transcript. It **autosaves** to
   `Documents/MeetingTranscribe/transcript-<session>.txt` as it goes; the path
   is shown under the controls. **Download .txt** also exports a copy on demand.

## Configuration

In the UI: choose the **Model** size and toggle **Timestamps** on/off.

Finer tuning lives at the top of `renderer/renderer.js`:

| Constant | Default | Notes |
|---|---|---|
| `WINDOW_SECONDS` | `12` | Context window sent to Whisper each pass |
| `STEP_SECONDS` | `4` | New audio between passes; smaller = snappier captions, more CPU/GPU |
| `AUTOSAVE_MS` | `4000` | How often the transcript is flushed to disk |

How it stays accurate at boundaries: consecutive windows overlap by
`WINDOW_SECONDS − STEP_SECONDS`, and emitted segments are de-duplicated by their
absolute timestamp — so a word spanning a boundary is transcribed with full
context and only emitted once.

## Roadmap

- **Phase 1:** capture system audio + live captions + save. ✅
- **Phase 2:** overlapping sliding-window transcription (no word cuts),
  `[mm:ss]` timestamps, model-size selector, continuous autosave to disk. ✅
- **Phase 3:** optional bundled `whisper.cpp` for a fully offline (no first-run
  download) build; optional text-to-speech read-back to earbuds; macOS support
  via ScreenCaptureKit; move capture to an `AudioWorklet`.

## Notes & limitations

- Throughput depends on hardware: with WebGPU, `base.en` keeps up comfortably;
  on CPU/WASM a larger model or small `STEP_SECONDS` may fall behind (the app
  catches up by transcribing the latest window, so audio isn't lost unless a
  single pass takes longer than `WINDOW_SECONDS`).
- An **output device picker** was considered but doesn't fit this design: the
  app never plays audio — loopback is a passive tap on the OS default output, so
  there's no output stream to route. Passthrough to your earbuds is handled by
  Windows itself.
- `ScriptProcessorNode` is deprecated but used here for simplicity; it will move
  to an `AudioWorklet` in Phase 3.

## License

MIT
