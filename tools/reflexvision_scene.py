"""Local scene inference for private offline replay evaluation."""
import base64
import http.client
import json

VISUAL_SCENES = ("match", "console", "menu", "loading", "dead", "spectator", "unknown")
SCHEMA = {
    "type": "object",
    "properties": {"scene": {"type": "string", "enum": list(VISUAL_SCENES)}},
    "required": ["scene"],
    "additionalProperties": False,
}


def classic_console(cv, image):
    """Recognize the opaque stock VGUI console panel. Other skins abstain."""
    sample = image[::4, ::4]
    fill = cv.inRange(sample, (54, 69, 61), (56, 71, 63))
    header = cv.inRange(sample, (67, 87, 75), (69, 89, 77))
    if cv.countNonZero(fill) < fill.size * 0.15:
        return False
    x, y, w, h = cv.boundingRect(fill)
    if w < fill.shape[1] * 0.35 or h < fill.shape[0] * 0.25 or y < 1:
        return False
    band = header[max(0, y - max(3, h // 8)):y, x:x+w]
    return (cv.countNonZero(fill) >= w*h*0.45 and band.size > 0
            and max(cv.countNonZero(row) for row in band) >= w*0.5)


def observe_scene(cv, image, model):
    if classic_console(cv, image):
        return "console", "classic_console"
    ok, jpeg = cv.imencode(".jpg", image, [cv.IMWRITE_JPEG_QUALITY, 85])
    if not ok:
        return "unknown", "encoding_error"
    request = {
        "model": model,
        "stream": False,
        "keep_alive": "1m",
        "format": SCHEMA,
        "options": {"temperature": 0, "num_predict": 40, "num_ctx": 1024, "num_batch": 64},
        "prompt": (
            "Classify this Counter-Strike 1.6 client image. A developer console overlay "
            "takes priority over the game behind it. Match means active first-person play. "
            "Distinguish spectator, dead, menu and loading screens. If ambiguous, use unknown."
        ),
        "images": [base64.b64encode(jpeg).decode("ascii")],
    }
    conn = http.client.HTTPConnection("127.0.0.1", 11434, timeout=150)
    try:
        conn.request("POST", "/api/generate", json.dumps(request), {"Content-Type": "application/json"})
        response = conn.getresponse()
        if response.status != 200:
            return "unknown", "service_error"
        data = response.read(32769)
        if len(data) > 32768:
            return "unknown", "invalid_response"
        envelope = json.loads(data)
        if envelope["done"] is not True or envelope["model"] != model:
            return "unknown", "invalid_response"
        result = json.loads(envelope["response"])
        if set(result) != {"scene"} or result["scene"] not in VISUAL_SCENES:
            return "unknown", "invalid_response"
        return result["scene"], "observed"
    except (KeyError, ValueError, TypeError):
        return "unknown", "invalid_response"
    except TimeoutError:
        return "unknown", "timeout"
    except (OSError, http.client.HTTPException):
        return "unknown", "service_error"
    finally:
        conn.close()


def detect_in_scene(detector, image, scene):
    if scene != "match":
        return []
    height, width = image.shape[:2]
    image[:height * 24 // 100, :width * 18 // 100] = 0
    image[height * 92 // 100:] = 0
    return detector.detect(image)


def read_frame(cv, source):
    if not source.is_file() or source.stat().st_size > 16 * 1024 * 1024:
        raise ValueError("Expected a local frame of at most 16 MiB")
    image = cv.imread(str(source))
    if image is None:
        raise ValueError("Client frame cannot be decoded")
    height, width = image.shape[:2]
    if not (1 <= width <= 640 and 1 <= height <= 1536):
        raise ValueError("Use the live capture dimensions for replay")
    return image


if __name__ == "__main__":
    import argparse
    import os
    import time
    from pathlib import Path
    from reflexvision_players import Players

    parser = argparse.ArgumentParser(description="Observe one saved game frame without labels.")
    parser.add_argument("frame", type=Path)
    parser.add_argument("model_root", type=Path)
    parser.add_argument("--model", default="qwen3-vl:2b-instruct",
                        choices=["qwen3-vl:2b-instruct", "qwen3-vl:4b-instruct"])
    args = parser.parse_args()
    os.environ.setdefault("OPENCV_IO_MAX_IMAGE_PIXELS", str(4096 * 4096))
    detector = Players(args.model_root)
    image = read_frame(detector.cv, args.frame)
    start = time.perf_counter()
    scene, status = observe_scene(detector.cv, image, args.model)
    boxes = detect_in_scene(detector, image, scene)
    print(json.dumps({"schema": "reflexvision.observation.v1", "scene": scene,
                      "observer_status": status, "people_xywh_score": boxes,
                      "processing_ms": round(1000 * (time.perf_counter() - start), 2)}))
    raise SystemExit(0 if status in {"observed", "classic_console"} else 1)
