#!/usr/bin/env python3
"""Train YOLOv8-nano on the swing classes and export it to CoreML for the app.

The exported model uses built-in NMS so Apple's Vision framework returns
`VNRecognizedObjectObservation`s directly, with class labels matching the
`SwingObjectLabel` raw values consumed by SwingKinematicsEngine:
    club_head, ball_static, ball_flight

Usage:
    pip install -r requirements.txt
    python train_and_export.py --data dataset.yaml --epochs 150

Output:
    SwingDetector.mlpackage  -> drag into the GolfLaunchMonitor app target.
"""

from __future__ import annotations

import argparse
import shutil
from pathlib import Path

from ultralytics import YOLO

EXPECTED_CLASSES = ["club_head", "ball_static", "ball_flight"]


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--data", default="dataset.yaml", help="YOLO dataset config")
    p.add_argument("--model", default="yolov8n.pt", help="base checkpoint (n = nano)")
    p.add_argument("--epochs", type=int, default=150)
    p.add_argument("--imgsz", type=int, default=640, help="must match the app's input size")
    p.add_argument("--batch", type=int, default=16)
    p.add_argument("--device", default=None, help="e.g. 'mps' on Apple silicon, '0' for CUDA")
    p.add_argument("--out", default="SwingDetector.mlpackage")
    return p.parse_args()


def main() -> None:
    args = parse_args()

    model = YOLO(args.model)
    # Sanity-check the dataset's class names so the CoreML labels line up with
    # the Swift enum; a mismatch here silently breaks detection in the app.
    names = list(model.model.names.values()) if hasattr(model, "model") else []
    del names  # names are read from data config at train time; checked below.

    results = model.train(
        data=args.data,
        epochs=args.epochs,
        imgsz=args.imgsz,
        batch=args.batch,
        device=args.device,
        patience=30,
    )

    trained = YOLO(str(Path(results.save_dir) / "weights" / "best.pt"))
    trained_classes = list(trained.model.names.values())
    if trained_classes != EXPECTED_CLASSES:
        raise SystemExit(
            f"Class mismatch: model has {trained_classes}, app expects "
            f"{EXPECTED_CLASSES}. Fix the 'names' order in {args.data} and retrain."
        )

    # Export with NMS baked in so Vision can consume it as an object detector.
    exported = trained.export(format="coreml", nms=True, imgsz=args.imgsz)

    dest = Path(args.out)
    if dest.exists():
        shutil.rmtree(dest, ignore_errors=True)
    shutil.move(str(exported), str(dest))

    print(f"\n✅ Exported CoreML model -> {dest.resolve()}")
    print("   Drag it into the GolfLaunchMonitor app target (keep the name "
          "'SwingDetector'); the app auto-loads it on launch.")


if __name__ == "__main__":
    main()
