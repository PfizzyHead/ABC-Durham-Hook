# SwingDetector — model training & export

The one production input the app can't ship without: a **YOLOv8-nano** object
detector for `[club_head, ball_static, ball_flight]`, exported to **CoreML** and
bundled in the app target. This folder is the toolchain to produce it.

```
Phase-1 captures ─► extract_frames.py ─► autolabel.py (draft ball boxes)
                                              │
                                              ▼
                         review + add club_head (Roboflow/CVAT) ─► train_and_export.py ─► SwingDetector.mlpackage
```

Capture the clips with the **SwingCapture** iOS app (`../SwingCaptureApp`).

## 0. Setup

```bash
cd MLModels
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
pip install opencv-python          # only for extract_frames.py
```

## 1. Collect frames

Run several real swings through Phase 1, then sample frames for labeling. The
sampler densifies around impact, where the data matters most:

```bash
python extract_frames.py swing1.mp4 --out data/raw --step 4 --impact-sec 1.0
```

Aim for **300–1000+ labeled images** across varied lighting, backgrounds, clubs,
and ball positions. More variety beats more frames from one clip.

## 2. Label

Use Roboflow, CVAT, or Label Studio. Draw tight boxes for three classes:

- **`club_head`** — the head only (not the shaft). Expect heavy motion blur at
  240 FPS through impact; label the blurred blob — that's what the app sees.
- **`ball_static`** — the ball at rest, pre-impact. This class drives spatial
  calibration, so boxes must be tight and accurate (the ball's pixel diameter
  becomes mm/pixel).
- **`ball_flight`** — the ball once moving, post-impact.

### Auto-label the ball first (saves most of the work)

If you captured with a colored or marked ball, draft the ball boxes
automatically, then only *review* them and add `club_head`:

```bash
python autolabel.py --images data/raw --impact-index 240 --color yellow
```

`--impact-index` is the frame number of impact (Phase 1 = 1.0 s pre-impact, so
~240 at 240 FPS). It assigns `ball_static` before impact and `ball_flight`
after, and flags every frame for manual `club_head` boxes. Import the frames +
generated labels into Roboflow/CVAT to finish.

Export in **YOLO format**. Place it as:

```
data/
  images/train/…  labels/train/…
  images/val/…    labels/val/…
```

Keep the class order in `dataset.yaml` (`0 club_head, 1 ball_static, 2 ball_flight`)
identical to your annotations — the export script hard-checks this, because a
mismatch silently breaks detection in the app.

## 3. Train + export

```bash
python train_and_export.py --data dataset.yaml --epochs 150 --device mps
```

`--device mps` uses the Apple-silicon GPU; use `--device 0` for CUDA, or omit for
CPU. Output: **`SwingDetector.mlpackage`**.

## 4. Bundle in the app

1. Drag `SwingDetector.mlpackage` into the `GolfLaunchMonitor` target in Xcode.
2. Confirm **Target Membership** is checked for the app.
3. Build & run. `SwingAnalysisViewModel` auto-loads it — no code change needed.

Xcode compiles the `.mlpackage` to `SwingDetector.mlmodelc` in the app bundle,
which the app loads by name.

## Notes

- **Input size** must match between training and the app. Both default to 640;
  if you change `--imgsz`, keep them in sync.
- **NMS is baked into the export** (`nms=True`) so Vision returns
  `VNRecognizedObjectObservation`s directly.
- Validate accuracy on held-out swings before trusting the metrics; calibration
  error scales linearly into every downstream number.
