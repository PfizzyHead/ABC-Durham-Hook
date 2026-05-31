// Fully-local, near-real-time transcription of system (meeting) audio.
//
// Phase 2 approach — overlapping sliding window + time-based dedup:
//   - We keep a rolling WINDOW_SECONDS buffer of 16 kHz mono audio.
//   - Every STEP_SECONDS of new audio we transcribe the WHOLE window with
//     word/segment timestamps. Because consecutive windows overlap by
//     (WINDOW - STEP) seconds, words near a boundary always get transcribed
//     with surrounding context — no more clipped words.
//   - We dedup by ABSOLUTE TIME: each transcribed segment carries a timestamp
//     relative to the window start, which we convert to a session-absolute
//     time. We only emit segments that start after the last time we emitted.
//
// The captured audio is NEVER played back (the loopback tap is non-destructive,
// so your earbuds already hear the meeting). A gain-0 node keeps the audio
// graph running without feedback.

import {
  pipeline,
  env,
} from "https://cdn.jsdelivr.net/npm/@huggingface/transformers@3.3.3";

env.allowLocalModels = false;
env.useBrowserCache = true;

// ---- Tunables -------------------------------------------------------------
const TARGET_SAMPLE_RATE = 16000; // Whisper expects 16 kHz mono
const WINDOW_SECONDS = 12; // audio context window sent to Whisper each pass
const STEP_SECONDS = 4; // how much new audio before we re-transcribe
const AUTOSAVE_MS = 4000; // debounce for writing the transcript to disk
const DEDUP_SLACK = 0.4; // seconds of tolerance when deduping by time
// ---------------------------------------------------------------------------

const WINDOW_SAMPLES = WINDOW_SECONDS * TARGET_SAMPLE_RATE;
const STEP_SAMPLES = STEP_SECONDS * TARGET_SAMPLE_RATE;

const startBtn = document.getElementById("startBtn");
const stopBtn = document.getElementById("stopBtn");
const saveBtn = document.getElementById("saveBtn");
const clearBtn = document.getElementById("clearBtn");
const statusEl = document.getElementById("status");
const meterEl = document.getElementById("meter");
const transcriptEl = document.getElementById("transcript");
const interimEl = document.getElementById("interim");
const envEl = document.getElementById("env");
const modelSelect = document.getElementById("modelSelect");
const tsToggle = document.getElementById("tsToggle");
const autosaveEl = document.getElementById("autosave");

let transcriber = null;
let activeDevice = "wasm";
let mediaStream = null;
let audioContext = null;
let sourceNode = null;
let processor = null;
let sink = null;

let collecting = false;
let busy = false; // a transcription pass is running

// Rolling audio buffer.
let ring = []; // Float32Array chunks
let ringLength = 0; // samples currently held in `ring`
let bufferStartSample = 0; // absolute index (from session start) of ring[0]
let samplesSeen = 0; // total samples captured this session
let lastPassSample = 0; // samplesSeen value at the last pass trigger
let lastEmittedTime = 0; // absolute seconds; segments before this are dups

// Transcript model: ordered entries { t: seconds, text }.
let entries = [];
let sessionId = null;
let autosaveTimer = null;
let autosavePath = null;

function setStatus(text, cls) {
  statusEl.textContent = text;
  statusEl.className = "status-pill " + (cls || "idle");
}

function fmtTime(sec) {
  const s = Math.max(0, Math.floor(sec));
  const m = Math.floor(s / 60);
  const r = s % 60;
  return `${String(m).padStart(2, "0")}:${String(r).padStart(2, "0")}`;
}

if (window.appInfo) {
  envEl.textContent = `Electron ${window.appInfo.versions.electron} · Chromium ${window.appInfo.versions.chrome} · ${window.appInfo.platform}`;
}

// ---- Model load (also used when the model selector changes) ---------------
async function loadModel(modelName) {
  startBtn.disabled = true;
  modelSelect.disabled = true;
  setStatus(`Loading ${modelName} (first run downloads weights)…`, "working");

  // Free any previous instance before swapping models.
  if (transcriber) {
    try {
      await transcriber.dispose();
    } catch (_) {
      /* ignore */
    }
    transcriber = null;
  }

  const progress = (p) => {
    if (p && p.status === "progress" && p.file) {
      const pct = p.progress ? ` ${Math.round(p.progress)}%` : "";
      setStatus(`Loading ${p.file}${pct}`, "working");
    }
  };

  try {
    transcriber = await pipeline("automatic-speech-recognition", modelName, {
      device: "webgpu",
      progress_callback: progress,
    });
    activeDevice = "webgpu";
  } catch (_) {
    try {
      transcriber = await pipeline("automatic-speech-recognition", modelName, {
        device: "wasm",
        progress_callback: progress,
      });
      activeDevice = "wasm";
    } catch (err) {
      setStatus("Failed to load model: " + err.message, "error");
      modelSelect.disabled = false;
      return;
    }
  }

  setStatus(`Model ready (${activeDevice}). Click Start.`, "idle");
  startBtn.disabled = false;
  startBtn.textContent = "Start";
  modelSelect.disabled = false;
}

loadModel(modelSelect.value);

modelSelect.addEventListener("change", () => {
  if (collecting) return; // can't swap mid-capture
  loadModel(modelSelect.value);
});

// ---- Start capture --------------------------------------------------------
async function start() {
  try {
    mediaStream = await navigator.mediaDevices.getDisplayMedia({
      video: true,
      audio: true,
    });
  } catch (err) {
    setStatus("Could not start capture: " + err.message, "error");
    return;
  }

  mediaStream.getVideoTracks().forEach((t) => t.stop());

  if (mediaStream.getAudioTracks().length === 0) {
    setStatus("No system audio track was provided.", "error");
    return;
  }

  // Reset session state.
  ring = [];
  ringLength = 0;
  bufferStartSample = 0;
  samplesSeen = 0;
  lastPassSample = 0;
  lastEmittedTime = 0;
  sessionId = new Date().toISOString().replace(/[:.]/g, "-");
  autosavePath = null;

  audioContext = new AudioContext({ sampleRate: TARGET_SAMPLE_RATE });
  await audioContext.resume();
  sourceNode = audioContext.createMediaStreamSource(mediaStream);
  processor = audioContext.createScriptProcessor(4096, 1, 1);

  processor.onaudioprocess = (e) => {
    if (!collecting) return;
    const input = e.inputBuffer.getChannelData(0);
    const copy = new Float32Array(input);
    ring.push(copy);
    ringLength += copy.length;
    samplesSeen += copy.length;

    // Trim from the front so we keep ~WINDOW_SECONDS of audio.
    while (ring.length > 1 && ringLength - ring[0].length >= WINDOW_SAMPLES) {
      const removed = ring.shift();
      ringLength -= removed.length;
      bufferStartSample += removed.length;
    }

    // Level meter (RMS).
    let sum = 0;
    for (let i = 0; i < input.length; i++) sum += input[i] * input[i];
    meterEl.style.setProperty(
      "--level",
      Math.min(100, Math.sqrt(sum / input.length) * 400) + "%"
    );

    if (!busy && samplesSeen - lastPassSample >= STEP_SAMPLES) {
      lastPassSample = samplesSeen;
      transcribePass();
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
  modelSelect.disabled = true;
  setStatus(`Live — listening (${activeDevice})`, "live");
  scheduleAutosave();
}

// ---- One transcription pass over the current window -----------------------
async function transcribePass() {
  if (busy || ringLength === 0) return;
  busy = true;

  // Snapshot the buffer synchronously (onaudioprocess may run during awaits).
  const startSample = bufferStartSample;
  const audio = new Float32Array(ringLength);
  let offset = 0;
  for (const part of ring) {
    audio.set(part, offset);
    offset += part.length;
  }
  const base = startSample / TARGET_SAMPLE_RATE; // window start, absolute seconds

  try {
    interimEl.textContent = "…transcribing…";
    const result = await transcriber(audio, { return_timestamps: true });

    const chunks =
      result && Array.isArray(result.chunks) ? result.chunks : null;

    if (chunks) {
      const fresh = [];
      let maxEnd = lastEmittedTime;
      for (const c of chunks) {
        const ts = c.timestamp;
        if (!ts || ts[0] == null) continue;
        const absStart = base + ts[0];
        const absEnd = base + (ts[1] == null ? ts[0] : ts[1]);
        if (absStart >= lastEmittedTime - DEDUP_SLACK) {
          const txt = (c.text || "").trim();
          if (txt) fresh.push({ t: absStart, text: txt });
          if (absEnd > maxEnd) maxEnd = absEnd;
        }
      }
      if (fresh.length) {
        // Merge this pass's new segments into one timestamped line.
        appendEntry(fresh[0].t, fresh.map((f) => f.text).join(" "));
      }
      lastEmittedTime = maxEnd;
    } else if (result && result.text) {
      // No timestamps came back — fall back to emitting once per pass.
      const txt = result.text.trim();
      if (txt) appendEntry(base, txt);
      lastEmittedTime = base + ringLength / TARGET_SAMPLE_RATE;
    }

    interimEl.textContent = "";
  } catch (err) {
    interimEl.textContent = "(transcription error: " + err.message + ")";
  } finally {
    busy = false;
    // If a lot piled up while we were busy, catch up.
    if (collecting && samplesSeen - lastPassSample >= STEP_SAMPLES) {
      lastPassSample = samplesSeen;
      transcribePass();
    }
  }
}

// ---- Transcript rendering / persistence -----------------------------------
function appendEntry(t, text) {
  entries.push({ t, text });
  renderTranscript();
  scheduleAutosave();
}

function renderTranscript() {
  const showTs = tsToggle.checked;
  transcriptEl.textContent = entries
    .map((e) => (showTs ? `[${fmtTime(e.t)}] ${e.text}` : e.text))
    .join(showTs ? "\n" : " ");
  transcriptEl.scrollIntoView({ block: "end" });
}

tsToggle.addEventListener("change", renderTranscript);

function transcriptToText() {
  return entries.map((e) => `[${fmtTime(e.t)}] ${e.text}`).join("\n");
}

function scheduleAutosave() {
  if (autosaveTimer || !sessionId) return;
  autosaveTimer = setTimeout(async () => {
    autosaveTimer = null;
    if (!entries.length || !window.transcripts) return;
    try {
      autosavePath = await window.transcripts.write(
        sessionId,
        transcriptToText()
      );
      autosaveEl.textContent = `Autosaved → ${autosavePath}`;
    } catch (err) {
      autosaveEl.textContent = "Autosave failed: " + err.message;
    }
  }, AUTOSAVE_MS);
}

// ---- Stop -----------------------------------------------------------------
async function stop() {
  collecting = false;
  if (!busy && ringLength > 0) await transcribePass(); // catch the tail
  if (processor) processor.disconnect();
  if (sink) sink.disconnect();
  if (sourceNode) sourceNode.disconnect();
  if (audioContext) await audioContext.close();
  if (mediaStream) mediaStream.getTracks().forEach((t) => t.stop());
  processor = sink = sourceNode = audioContext = mediaStream = null;

  // Final flush to disk.
  if (entries.length && window.transcripts && sessionId) {
    try {
      autosavePath = await window.transcripts.write(
        sessionId,
        transcriptToText()
      );
      autosaveEl.textContent = `Saved → ${autosavePath}`;
    } catch (_) {
      /* ignore */
    }
  }

  meterEl.style.setProperty("--level", "0%");
  startBtn.disabled = false;
  stopBtn.disabled = true;
  modelSelect.disabled = false;
  setStatus("Stopped", "idle");
}

// ---- Manual download / clear ----------------------------------------------
function download() {
  if (!entries.length) return;
  const blob = new Blob([transcriptToText()], { type: "text/plain" });
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = `meeting-transcript-${sessionId || "session"}.txt`;
  a.click();
  URL.revokeObjectURL(url);
}

function clear() {
  entries = [];
  lastEmittedTime = 0;
  transcriptEl.textContent = "";
  interimEl.textContent = "";
}

startBtn.addEventListener("click", start);
stopBtn.addEventListener("click", stop);
saveBtn.addEventListener("click", download);
clearBtn.addEventListener("click", clear);
