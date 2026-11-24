"""Local YOLOX worker. Read bounded BGRA frames from stdin, return person boxes."""
import hashlib
import json
import struct
import sys
from pathlib import Path


class Players:
    def __init__(self, root):
        sys.path.insert(0, str(root / "python"))
        import cv2
        import numpy as np
        self.cv = cv2
        self.np = np
        weights = root / "yolox_tiny.onnx"
        if hashlib.sha256(weights.read_bytes()).hexdigest() != "427cc366d34e27ff7a03e2899b5e3671425c262ea2291f88bb942bc1cc70b0f7":
            raise ValueError("Unexpected YOLOX weights")
        cv2.setNumThreads(2)
        self.net = cv2.dnn.readNetFromONNX(str(weights))
        self.canvas = np.empty((416, 416, 3), np.uint8)
        grids, strides = [], []
        for stride in (8, 16, 32):
            x, y = np.meshgrid(np.arange(416 // stride), np.arange(416 // stride))
            grids.append(np.stack((x, y), axis=-1).reshape(-1, 2))
            strides.extend([stride] * x.size)
        self.grid = np.concatenate(grids)
        self.strides = np.array(strides)[:, None]

    def detect(self, bgr):
        np, cv = self.np, self.cv
        height, width = bgr.shape[:2]
        scale = min(416 / width, 416 / height)
        w, h = int(width * scale), int(height * scale)
        self.canvas.fill(114)
        self.canvas[:h, :w] = cv.resize(bgr, (w, h), interpolation=cv.INTER_LINEAR)
        self.net.setInput(cv.dnn.blobFromImage(self.canvas))
        raw = self.net.forward()[0]
        scores = raw[:, 4] * raw[:, 5]  # COCO class 0 = person.
        selected = np.flatnonzero(scores >= .27)
        values = raw[selected]
        centers = (values[:, :2] + self.grid[selected]) * self.strides[selected] / scale
        sizes = np.exp(np.clip(values[:, 2:4], -10, 10)) * self.strides[selected] / scale
        boxes = np.concatenate((centers - sizes / 2, sizes), axis=1)
        confidence = scores[selected].tolist()
        kept = cv.dnn.NMSBoxes(boxes.tolist(), confidence, .27, .45)
        results = []
        for i in list(kept)[:16]:
            x, y, bw, bh = boxes[i]
            left, top = max(0, round(x)), max(0, round(y))
            right, bottom = min(width, round(x + bw)), min(height, round(y + bh))
            if right > left and bottom > top:
                results.append([left, top, right-left, bottom-top, round(confidence[i], 3)])
        return results


def main(root):
    model = Players(root)
    pipe = sys.stdin.buffer
    print("READY", flush=True)
    while header := pipe.read(8):
        if len(header) != 8:
            return
        width, height = struct.unpack("<II", header)
        if not (1 <= width <= 640 and 1 <= height <= 1536):
            return
        payload = pipe.read(width * height * 4)
        if len(payload) != width * height * 4:
            return
        pixels = model.np.frombuffer(payload, dtype=model.np.uint8).reshape(height, width, 4)
        print(json.dumps(model.detect(pixels[:, :, :3]), separators=(",", ":")), flush=True)


if __name__ == "__main__":
    main(Path(sys.argv[1]))
