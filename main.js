// Electron main process.
//
// Key job: when the renderer calls navigator.mediaDevices.getDisplayMedia(),
// hand it the *system audio loopback* on Windows. This is a non-destructive
// tap on whatever is being played to the default output device, so the meeting
// keeps playing to your earbuds normally ("passthrough" is automatic) while we
// also receive a copy of the audio to transcribe locally.

const { app, BrowserWindow, session, desktopCapturer } = require('electron');
const path = require('path');

function createWindow() {
  const win = new BrowserWindow({
    width: 980,
    height: 760,
    backgroundColor: '#0e1116',
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
    },
  });

  win.loadFile(path.join(__dirname, 'renderer', 'index.html'));
}

app.whenReady().then(() => {
  // Grant loopback (system) audio to getDisplayMedia requests.
  // getDisplayMedia requires a video source to be present, so we attach the
  // first screen for video and immediately drop the video track in the
  // renderer — only the loopback audio track is used.
  session.defaultSession.setDisplayMediaRequestHandler(
    (request, callback) => {
      desktopCapturer
        .getSources({ types: ['screen'] })
        .then((sources) => {
          callback({ video: sources[0], audio: 'loopback' });
        })
        .catch(() => callback({}));
    },
    // Use Electron's own handler rather than the OS picker so loopback audio
    // can be granted programmatically.
    { useSystemPicker: false }
  );

  createWindow();

  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') app.quit();
});
