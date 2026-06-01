// AudioWorklet processor: runs on the audio render thread, buffers incoming
// mono samples into ~4096-sample frames, and posts them to the main thread.
// Buffering keeps message traffic low (vs. posting every 128-sample block).
class CaptureProcessor extends AudioWorkletProcessor {
  constructor() {
    super();
    this._buf = new Float32Array(4096);
    this._n = 0;
  }

  process(inputs) {
    const channel = inputs[0] && inputs[0][0];
    if (channel) {
      for (let i = 0; i < channel.length; i++) {
        this._buf[this._n++] = channel[i];
        if (this._n === this._buf.length) {
          // Transfer a copy so the buffer can be reused immediately.
          this.port.postMessage(this._buf.slice(0));
          this._n = 0;
        }
      }
    }
    return true; // keep the processor alive
  }
}

registerProcessor("capture-processor", CaptureProcessor);
