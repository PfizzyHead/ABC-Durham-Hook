const { contextBridge, ipcRenderer } = require('electron');

// Minimal, safe surface exposed to the renderer.
contextBridge.exposeInMainWorld('appInfo', {
  platform: process.platform,
  versions: {
    electron: process.versions.electron,
    chrome: process.versions.chrome,
  },
});

contextBridge.exposeInMainWorld('transcripts', {
  // Persist the current transcript to disk; resolves to the file path.
  write: (sessionId, content) =>
    ipcRenderer.invoke('transcript:write', { sessionId, content }),
});
