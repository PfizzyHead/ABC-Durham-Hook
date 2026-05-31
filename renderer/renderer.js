// Fully-local, real-time-ish transcription of system (meeting) audio.
//
// Pipeline:
//   getDisplayMedia({audio:'loopback'})  ->  AudioContext @ 16 kHz
//     -> ScriptProcessor collects mono samples
//     -> every CHUNK_SECONDS we run Whisper (Transformers.js) on the buffer
//     -> append recognized text to the transcript
//
// The captured audio is NEVER played back (the loopback tap is non-destructive,
// so your earbuds already hear the meeting). The processor is connected through
// a gain-0 node only so the audio graph keeps running without feedback.

import {
  pipeline,
  env,
} from "https://cdn.jsdelivr.net/npm/@huggingface/transformers@3.3.3";

// We want remote (Hugging Face) model weights, cached locally after first run.
env.allowLocalModels = false;
env.useBrowserCache = true;

// ---- Tunables -------------------------------------------------------------
const MODEL = "Xenova/whisper-base.en"; // try whisper-tiny.en (faster) or whisper-small.en (more accurate)
const TARGET_SAMPLE_RATE = 16000; // Whisper expects 16 kHz mono
const CHUNK_SECONDS = 6; // how much audio to transcribe per pass
// ---------------------------------------------------------------------------

const startBtn = document.getElementById("startBtn");
const stopBtn = document.getElementById("stopBtn");
const saveBtn = document.getElementById("saveBtn");
const clearBtn = document.getElementById("clearBtn");
const statusEl = document.getElementById("status");
const meterEl = document.getElementById("meter");
const transcriptEl = document.getElementById("transcript");
const interimEl = document.getElementById("interim");
const envEl = document.getElementById("env");

let transcriber = null;
let mediaStream = null;
let audioContext = null;
let sourceNode = null;
let processor = null;
let sink = null;

let collecting = false;
let pending = []; // Float32Array chunks awaiting transcription
let pendingSamples = 0;
let busy = false; // true while a transcription pass is running

function setStatus(text, cls) {
  statusEl.textContent = text;
  statusEl.className = "status-pill " + (cls || "idle");
}

if (window.appInfo) {
  envEl.textContent = `Electron ${window.appInfo.versions.electron} · Chromium ${window.appInfo.versions.chrome} · ${window.appInfo.platform}`;
}

// ---- Model load -----------------------------------------------------------
(async function loadModel() {
  setStatus("Downloading / loading model (first run can take a minute)…", "working");
  let device = "webgpu";
  try {
    transcriber = await pipeline("automatic-speech-recognition", MODEL, {
      device: "webgpu",
      progress_callback: (p) => {
        if (p && p.status === "progress" && p.file) {
          const pct = p.progress ? ` ${Math.round(p.progress)}%` : "";
          setStatus(`Loading ${p.file}${pct}`, "working");
        }
      },
    });
  } catch (err) {
    // No WebGPU? Fall back to WASM (CPU) — slower but works everywhere.
    device = "wasm";
    try {
      transcriber = await pipeline("automatic-speech-recognition", MODEL, {
        device: "wasm",
      });
    } catch (err2) {
      setStatus("Failed to load model: " + err2.message, "error");
      return;
    }
  }
  setStatus(`Model ready (${device}). Click Start.`, "idle");
  startBtn.disabled = false;
  startBtn.textContent = "Start";
})();

// ---- Start capture --------------------------------------------------------
async function start() {
  try {
    // Video must be requested for getDisplayMedia; we drop it immediately.
    mediaStream = await navigator.mediaDevices.getDisplayMedia({
      video: true,
      audio: true,
    });
  } catch (err) {
    setStatus("Could not start capture: " + err.message, "error");
    return;
  }

  mediaStream.getVideoTracks().forEach((t) => t.stop());

  const audioTracks = mediaStream.getAudioTracks();
  if (audioTracks.length === 0) {
    setStatus("No system audio track was provided.", "error");
    return;
  }

  // AudioContext resamples to 16 kHz for us.
  audioContext = new AudioContext({ sampleRate: TARGET_SAMPLE_RATE });
  await audioContext.resume();

  sourceNode = audioContext.createMediaStreamSource(mediaStream);
  processor = audioContext.createScriptProcessor(4096, 1, 1);

  processor.onaudioprocess = (e) => {
    if (!collecting) return;
    const input = e.inputBuffer.getChannelData(0);
    pending.push(new Float32Array(input));
    pendingSamples += input.length;

    // Simple level meter (RMS).
    let sum = 0;
    for (let i = 0; i < input.length; i++) sum += input[i] * input[i];
    const rms = Math.sqrt(sum / input.length);
    meterEl.style.setProperty("--level", Math.min(100, rms * 400) + "%");

    if (pendingSamples >= CHUNK_SECONDS * TARGET_SAMPLE_RATE) {
      flush();
    }
  };

  // Gain 0 -> destination keeps the ScriptProcessor firing without audible
  // playback (which would otherwise feed back into the loopback capture).
  sink = audioContext.createGain();
  sink.gain.value = 0;
  sourceNode.connect(processor);
  processor.connect(sink);
  sink.connect(audioContext.destination);

  collecting = true;
  startBtn.disabled = true;
  stopBtn.disabled = false;
  saveBtn.disabled = false;
  setStatus("Live — listening to system audio", "live");
}

// ---- Transcribe one buffered chunk ----------------------------------------
async function flush() {
  if (busy || pendingSamples === 0) return;
  busy = true;

  const total = pendingSamples;
  const audio = new Float32Array(total);
  let offset = 0;
  for (const part of pending) {
    audio.set(part, offset);
    offset += part.length;
  }
  pending = [];
  pendingSamples = 0;

  try {
    interimEl.textContent = "…transcribing…";
    const result = await transcriber(audio);
    const text = (result.text || "").trim();
    if (text) {
      transcriptEl.textContent += (transcriptEl.textContent ? " " : "") + text;
      transcriptEl.scrollIntoView({ block: "end" });
    }
    interimEl.textContent = "";
  } catch (err) {
    interimEl.textContent = "(transcription error: " + err.message + ")";
  } finally {
    busy = false;
    // If more than a chunk piled up while we were busy, process it.
    if (collecting && pendingSamples >= CHUNK_SECONDS * TARGET_SAMPLE_RATE) {
      flush();
    }
  }
}

// ---- Stop -----------------------------------------------------------------
async function stop() {
  collecting = false;
  if (pendingSamples > 0) await flush(); // catch the tail
  if (processor) processor.disconnect();
  if (sink) sink.disconnect();
  if (sourceNode) sourceNode.disconnect();
  if (audioContext) await audioContext.close();
  if (mediaStream) mediaStream.getTracks().forEach((t) => t.stop());

  processor = sink = sourceNode = audioContext = mediaStream = null;
  meterEl.style.setProperty("--level", "0%");
  startBtn.disabled = false;
  stopBtn.disabled = true;
  setStatus("Stopped", "idle");
}

// ---- Save / clear ---------------------------------------------------------
function save() {
  const text = transcriptEl.textContent.trim();
  if (!text) return;
  const blob = new Blob([text], { type: "text/plain" });
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  const stamp = new Date().toISOString().replace(/[:.]/g, "-");
  a.href = url;
  a.download = `meeting-transcript-${stamp}.txt`;
  a.click();
  URL.revokeObjectURL(url);
}

function clear() {
  transcriptEl.textContent = "";
  interimEl.textContent = "";
}

startBtn.addEventListener("click", start);
stopBtn.addEventListener("click", stop);
saveBtn.addEventListener("click", save);
clearBtn.addEventListener("click", clear);
