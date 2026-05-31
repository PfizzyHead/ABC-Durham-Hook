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

> **Status: Phase 1 scaffold.** Goal of this phase is to prove the pipeline:
> capture system audio → live captions on screen → save transcript. See
> *Roadmap* below.

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
2. Click **Start** and approve the screen/audio share prompt.
3. Watch the live transcript. **Save transcript** writes a `.txt` file.

## Configuration

Edit the tunables at the top of `renderer/renderer.js`:

| Constant | Default | Notes |
|---|---|---|
| `MODEL` | `Xenova/whisper-base.en` | `whisper-tiny.en` = faster, `whisper-small.en` = more accurate |
| `CHUNK_SECONDS` | `6` | Lower = snappier captions, higher = better accuracy |

## Roadmap

- **Phase 1 (this):** capture system audio + live captions + save. ✅
- **Phase 2:** sliding-window chunking with overlap (fewer word cuts), output
  device picker, timestamps, autosave.
- **Phase 3:** optional bundled `whisper.cpp` for a fully offline (no first-run
  download) build; optional text-to-speech read-back to earbuds; macOS support
  via ScreenCaptureKit.

## Notes & limitations

- Phase 1 transcribes fixed ~6-second chunks, so a word occasionally gets cut at
  a chunk boundary. Phase 2's overlap fixes this.
- `ScriptProcessorNode` is deprecated but used here for simplicity; it will move
  to an `AudioWorklet` later.

## License

MIT
