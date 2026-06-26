# SwingCapture (iOS)

The on-phone capture app — your **Phase-1 / data-collection** tool. It records a
240 FPS clip centered on impact and saves the raw MP4 for analysis and for
building the training set.

## How it works

- **High-speed camera** (`HighSpeedCamera`): picks the best back-camera format
  supporting 240 FPS (preferring 1080p) and pins min/max frame duration to lock
  the rate.
- **Loop recording** (`ClipRecorder`): while *armed*, it continuously encodes to
  a temp H.264 file on disk. On impact it marks the trigger, records `postRoll`
  more seconds, then passthrough-trims the file to exactly **1.0 s before + 1.5 s
  after** impact — the Phase-1 window — at native 240 FPS. (Buffering compressed
  video on disk avoids the multi-GB RAM cost of holding a second of raw frames.)
- **Impact trigger** (`ImpactDetector`): listens to the mic and fires on the
  amplitude spike of the strike. A **Manual** button and a sensitivity slider are
  provided for loud ranges where audio triggering is unreliable.
- Saved clips land in **Documents** (file sharing is enabled), so you can pull
  them off the device via the Files app, AirDrop, or the in-app share sheet.

## Run it

```bash
brew install xcodegen
cd SwingCaptureApp
xcodegen generate
open SwingCapture.xcodeproj   # set your Team, run on a real device
```

Must run on a **physical iPhone** — the simulator has no 240 FPS camera.

## Field protocol for good training data

- **Light:** 240 FPS needs short exposures → lots of light. Shoot in bright
  daylight or add lighting; dim bays produce dark, blurry, useless frames.
- **Rig:** phone on a tripod, **side-on**, framing the ball and the bottom of the
  swing arc. Keep it fixed for a session.
- **Ball:** use a colored/marked ball so `autolabel.py` can pre-label it. Also
  capture some plain-ball swings if the product must support plain balls.
- **Variety beats volume:** vary lighting, backgrounds, clubs, and ball position
  across sessions. Aim for a few hundred labeled swings to start.

## Needs on-device tuning

This is untested scaffolding (it can't be built/run off-device). Expect to
iterate on:
- the audio **impact threshold** (`ImpactDetector.threshold`) against real strike
  vs. ambient noise,
- the 240 FPS **format selection** across specific iPhone models,
- the `ClipRecorder` finish/flush edge cases under sustained 240 FPS load.
