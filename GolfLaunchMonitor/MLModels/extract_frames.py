#!/usr/bin/env python3
"""Extract frames from a Phase-1 capture for labeling.

A 240 FPS clip has ~600 near-duplicate frames; labeling all of them wastes
effort. This samples every Nth frame, with the option to densely sample a window
around impact (where ball_static -> ball_flight transition and fast club motion
make the most valuable training data).

Usage:
    python extract_frames.py swing.mp4 --out data/raw --step 4 \
        --impact-sec 1.0 --dense-window 0.15 --dense-step 1
"""

from __future__ import annotations

import argparse
from pathlib import Path

import cv2  # opencv-python


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("video")
    p.add_argument("--out", default="data/raw")
    p.add_argument("--step", type=int, default=4, help="keep 1 of every N frames")
    p.add_argument("--impact-sec", type=float, default=1.0,
                   help="approx impact time (Phase 1 = 1.0s pre-impact)")
    p.add_argument("--dense-window", type=float, default=0.15,
                   help="seconds around impact to sample densely")
    p.add_argument("--dense-step", type=int, default=1)
    return p.parse_args()


def main() -> None:
    args = parse_args()
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)

    cap = cv2.VideoCapture(args.video)
    if not cap.isOpened():
        raise SystemExit(f"Could not open {args.video}")
    fps = cap.get(cv2.CAP_PROP_FPS) or 240.0
    stem = Path(args.video).stem

    lo = (args.impact_sec - args.dense_window) * fps
    hi = (args.impact_sec + args.dense_window) * fps

    idx = kept = 0
    while True:
        ok, frame = cap.read()
        if not ok:
            break
        step = args.dense_step if lo <= idx <= hi else args.step
        if idx % step == 0:
            cv2.imwrite(str(out / f"{stem}_{idx:05d}.jpg"), frame)
            kept += 1
        idx += 1

    cap.release()
    print(f"✅ {kept} frames -> {out} (from {idx} total @ {fps:.0f} fps)")


if __name__ == "__main__":
    main()
