# Media Grab

A native iOS app that lets you open any web page (logging in if it's
password-protected), scan it for every image and video, pick the ones you want,
and save them to a **Photos album** or a **Files folder** you name.

## How it works

1. **Browse** to a page in the built-in web browser. If the content is behind a
   login, sign in right there in the app — the app keeps your session.
2. Tap **Scan media**. The app reads the *rendered* page (including content
   loaded by JavaScript or revealed after login) and lists every image and
   video it finds.
3. **Select** the items you want in a thumbnail grid (or "Select all").
4. Tap **Download**, choose **Photos album** or **Files folder**, type a name,
   and **Save**. Your login cookies are reused so protected media downloads
   correctly.

| Destination | Where it lands |
|-------------|----------------|
| Photos album | Photos app › album with the name you typed (created if missing) |
| Files folder | Files app › On My iPhone › Media Grab › the folder you named |

## Project layout

```
MediaGrab.xcodeproj         Xcode project (open this)
Info.plist                  App permissions & settings
MediaGrab/
  MediaGrabApp.swift        App entry point
  ContentView.swift         Root view
  BrowserView.swift         Address bar + web view + "Scan media"
  WebViewModel.swift        WKWebView wrapper, cookie sync, page scan
  MediaScanner.swift        JavaScript that finds images/videos on the page
  MediaItem.swift           Model for a found image/video
  MediaSelectionView.swift  Thumbnail grid with selection
  DownloadDestinationView.swift  Pick Photos vs Files + name, with progress
  DownloadManager.swift     Downloads files and saves to Photos/Files
```

## Building & running it (you need a Mac)

> iOS apps can only be compiled with **Xcode on macOS**. They cannot be built on
> Linux, so this repo holds the source; you build it on a Mac.

1. Install **Xcode** (16 or newer) from the Mac App Store.
2. Open `MediaGrab.xcodeproj`.
3. In the **MediaGrab** target → **Signing & Capabilities**, pick your Apple ID
   under *Team*. A free Apple ID works for installing on your own iPhone.
   - Change the **Bundle Identifier** from `com.example.MediaGrab` to something
     unique (e.g. `com.yourname.MediaGrab`) if Xcode complains.
4. Plug in your iPhone (or use a Simulator), select it as the run destination,
   and press **⌘R**.
5. On a physical device the first launch needs you to trust the developer
   profile: *Settings › General › VPN & Device Management › (your Apple ID) ›
   Trust*.

The app targets **iOS 17+**.

## Notes & limits

- **Streaming video** (HLS `.m3u8`, DRM-protected players like YouTube/Netflix)
  is not downloadable — those aren't plain files. The app grabs direct
  image/video file URLs (`.jpg`, `.png`, `.mp4`, `.mov`, etc.).
- Photos only accepts formats it understands (e.g. `.webm` video may fail to
  import — use the **Files** destination for those).
- Some sites load images lazily as you scroll. If you don't see everything,
  scroll the page, then **Scan media** again.
- `NSAllowsArbitraryLoads` is enabled so the in-app browser can reach any site.

## Please download responsibly

Only download content you own or have the right to save. Respect each site's
terms of service and applicable copyright law.
