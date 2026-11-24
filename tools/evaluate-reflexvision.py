"""Replay privately annotated CS 1.6 client frames through the local YOLOX worker."""
import argparse
import json
import os
import time
from pathlib import Path

from reflexvision_players import Players

SCENES = {"menu", "console", "loading", "match", "dead", "spectator", "unknown", "stale"}


def evaluate(args):
    if args.manifest.stat().st_size > 1024 * 1024:
        raise ValueError("Frame manifest exceeds 1 MiB")
    records = json.loads(args.manifest.read_text(encoding="utf-8-sig"))
    if not isinstance(records, list) or not 0 < len(records) <= 1000:
        raise ValueError("Expected 1 to 1,000 local frame records")

    os.environ.setdefault("OPENCV_IO_MAX_IMAGE_PIXELS", str(4096 * 4096))
    detector = Players(args.model_root)
    with args.output.open("x", encoding="utf-8") as output:
        for frame, record in enumerate(records):
            scene = record["scene"]
            if scene not in SCENES:
                raise ValueError("Unexpected scene")
            source = args.manifest.parent / record["image"]
            if source.stat().st_size > 16 * 1024 * 1024:
                raise ValueError("Frame exceeds 16 MiB")
            started = time.perf_counter()
            image = detector.cv.imread(str(source))
            if image is None:
                raise ValueError("Client frame cannot be decoded")
            height, width = image.shape[:2]
            if not (1 <= width <= 640 and 1 <= height <= 1536):
                raise ValueError("Use the live capture dimensions for replay")
            image[:height * 24 // 100, :width * 18 // 100] = 0
            image[height * 92 // 100:] = 0
            boxes = detector.detect(image) if scene == "match" or args.raw else []
            sample = {
                "frame": frame,
                "source": "annotated_clip",
                "scene": scene,
                "tick": record.get("tick"),
                "truth": record.get("truth", []),
                "detections": [{"box": box[:4], "score": box[4]} for box in boxes],
                "observation_age_ms": round((time.perf_counter() - started) * 1000, 3),
            }
            output.write(json.dumps(sample, separators=(",", ":")) + "\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path)
    parser.add_argument("model_root", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--raw", action="store_true", help="Score the ungated detector")
    evaluate(parser.parse_args())
