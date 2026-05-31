const { contextBridge } = require('electron');

// Minimal, safe surface exposed to the renderer.
contextBridge.exposeInMainWorld('appInfo', {
  platform: process.platform,
  versions: {
    electron: process.versions.electron,
    chrome: process.versions.chrome,
  },
});
