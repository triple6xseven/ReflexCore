"""Replay privately annotated CS 1.6 client frames through the local YOLOX worker."""
import argparse
import json
import os
import time
from pathlib import Path

from reflexvision_players import Players
from reflexvision_scene import detect_in_scene, observe_scene, read_frame

SCENES = {"menu", "console", "loading", "match", "dead", "spectator", "unknown", "stale"}


def evaluate(args):
    if args.manifest.stat().st_size > 1024 * 1024:
        raise ValueError("Frame manifest exceeds 1 MiB")
    records = json.loads(args.manifest.read_text(encoding="utf-8-sig"))
    if not isinstance(records, list) or not 0 < len(records) <= 1000:
        raise ValueError("Expected 1 to 1,000 local frame records")

    os.environ.setdefault("OPENCV_IO_MAX_IMAGE_PIXELS", str(4096 * 4096))
    detector = Players(args.model_root)
    root = args.manifest.resolve().parent
    with args.output.open("x", encoding="utf-8") as output:
        for frame, record in enumerate(records):
            scene = record["scene"]
            if scene not in SCENES:
                raise ValueError("Unexpected scene")
            relative = Path(record["image"])
            if relative.anchor or ".." in relative.parts:
                raise ValueError("Use images relative to the manifest folder")
            source = (root / relative).resolve(strict=True)
            if not source.is_relative_to(root):
                raise ValueError("Image is outside the manifest folder")
            started = time.perf_counter()
            image = read_frame(detector.cv, source)
            predicted = scene
            observation = {}
            if args.scene_model:
                inference_start = time.perf_counter()
                predicted, status = observe_scene(detector.cv, image, args.scene_model)
                observation = {
                    "predicted_scene": predicted,
                    "observer_status": status,
                    "scene_model": args.scene_model,
                    "scene_inference_ms": round((time.perf_counter() - inference_start) * 1000, 3),
                }
            boxes = detect_in_scene(detector, image, "match" if args.raw else predicted)
            sample = {
                **observation,
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
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--scene-model", choices=["qwen3-vl:2b-instruct", "qwen3-vl:4b-instruct"],
                      help="Predict the scene from pixels using local Ollama before detecting people")
    mode.add_argument("--raw", action="store_true", help="Score the ungated detector")
    evaluate(parser.parse_args())
