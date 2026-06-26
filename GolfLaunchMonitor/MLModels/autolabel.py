#!/usr/bin/env python3
"""Auto-label the ball in extracted frames to bootstrap the training set.

This exploits the "optional marker" decision: a colored/marked ball is trivially
found by classical CV, so we can machine-generate draft YOLO labels for the
high-volume ball classes and let a human just *review* them — instead of drawing
thousands of boxes by hand.

What it labels:
  * ball_static  — frames BEFORE impact   (class 1)
  * ball_flight  — frames AT/AFTER impact  (class 2)
Class is assigned by each frame's index relative to --impact-index.

What it does NOT label:
  * club_head (class 0) — motion-blurred and ambiguous; flagged for manual boxes.

Frames are expected to be named like `<stem>_<frameindex>.jpg` (the convention
emitted by extract_frames.py), so the frame index can be parsed for the
static/flight split.

Usage:
    python autolabel.py --images data/raw --impact-index 240 --color yellow
    # then import data/raw + the generated labels into Roboflow/CVAT to review
    # and add club_head boxes.
"""

from __future__ import annotations

import argparse
import re
from pathlib import Path

import cv2
import numpy as np

CLASS_BALL_STATIC = 1
CLASS_BALL_FLIGHT = 2

# HSV ranges (OpenCV H is 0..179) for common ball / marker colors.
HSV_RANGES = {
    "yellow": [((20, 80, 80), (35, 255, 255))],
    "orange": [((8, 100, 100), (20, 255, 255))],
    "green":  [((40, 70, 70), (85, 255, 255))],
    # White wraps poorly in HSV; use low saturation + high value.
    "white":  [((0, 0, 200), (179, 40, 255))],
}

FRAME_INDEX_RE = re.compile(r"_(\d+)\.(?:jpg|jpeg|png)$", re.IGNORECASE)


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--images", required=True, help="folder of extracted frames")
    p.add_argument("--labels", default=None, help="output labels dir (default: <images>/../labels)")
    p.add_argument("--impact-index", type=int, required=True,
                   help="frame index of impact (e.g. 240 for 1.0s pre @ 240fps)")
    p.add_argument("--color", choices=sorted(HSV_RANGES), default="yellow")
    p.add_argument("--min-radius", type=int, default=4)
    p.add_argument("--max-radius", type=int, default=120)
    return p.parse_args()


def detect_ball_by_color(bgr, color, min_r, max_r):
    """Return (cx, cy, r) in pixels for the best ball blob, or None."""
    hsv = cv2.cvtColor(bgr, cv2.COLOR_BGR2HSV)
    mask = None
    for lo, hi in HSV_RANGES[color]:
        m = cv2.inRange(hsv, np.array(lo), np.array(hi))
        mask = m if mask is None else cv2.bitwise_or(mask, m)
    mask = cv2.morphologyEx(mask, cv2.MORPH_OPEN, np.ones((3, 3), np.uint8))

    contours, _ = cv2.findContours(mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    best = None
    best_area = 0.0
    for c in contours:
        (x, y), r = cv2.minEnclosingCircle(c)
        if r < min_r or r > max_r:
            continue
        area = cv2.contourArea(c)
        # Reject non-round blobs (circularity guard).
        if area <= 0 or area / (np.pi * r * r) < 0.55:
            continue
        if area > best_area:
            best_area = area
            best = (x, y, r)
    return best


def frame_index(name: str) -> int | None:
    m = FRAME_INDEX_RE.search(name)
    return int(m.group(1)) if m else None


def main() -> None:
    args = parse_args()
    images_dir = Path(args.images)
    labels_dir = Path(args.labels) if args.labels else images_dir.parent / "labels"
    labels_dir.mkdir(parents=True, exist_ok=True)

    paths = sorted(p for p in images_dir.iterdir()
                   if p.suffix.lower() in {".jpg", ".jpeg", ".png"})
    labeled = no_ball = no_index = 0
    needs_manual = []

    for path in paths:
        idx = frame_index(path.name)
        if idx is None:
            no_index += 1
            continue

        bgr = cv2.imread(str(path))
        if bgr is None:
            continue
        h, w = bgr.shape[:2]

        ball = detect_ball_by_color(bgr, args.color, args.min_radius, args.max_radius)
        cls = CLASS_BALL_STATIC if idx < args.impact_index else CLASS_BALL_FLIGHT

        lines = []
        if ball is not None:
            cx, cy, r = ball
            bw, bh = (2 * r) / w, (2 * r) / h
            lines.append(f"{cls} {cx / w:.6f} {cy / h:.6f} {bw:.6f} {bh:.6f}")
            labeled += 1
        else:
            no_ball += 1

        # Always create the label file (possibly empty) and flag for club_head.
        (labels_dir / f"{path.stem}.txt").write_text("\n".join(lines))
        needs_manual.append(path.name)

    print(f"✅ Auto-labeled ball in {labeled} frames -> {labels_dir}")
    print(f"   {no_ball} frames had no confident ball; {no_index} had no parseable index.")
    print(f"\n⚠️  club_head (class 0) is NOT auto-labeled. Review all {len(needs_manual)} "
          f"frames in Roboflow/CVAT and add club_head boxes near impact.")
    print("   Tip: verify the static/flight split lines up with the real impact frame.")


if __name__ == "__main__":
    main()
