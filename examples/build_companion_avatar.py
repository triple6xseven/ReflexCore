#!/usr/bin/env python3
"""Reproduce the local ReflexCompanion adaptation of pixiv Victoria Rubin (CC0)."""
from argparse import ArgumentParser
from copy import deepcopy
from hashlib import sha256
from io import BytesIO
import json
from pathlib import Path
import struct
import urllib.request

import numpy as np
from PIL import Image


SOURCE = "https://raw.githubusercontent.com/madjin/vrm-samples/e16eb187100149a315ad92c3c9968f1d5baa6c7d/vroid/beta/Victoria_Rubin.vrm"
SHA256 = "b1372131bdbf233f46320146d565f342a7e4f6f4b8f2aefb301f1a283ec07e1e"
RIGHTS = "https://vroid.pixiv.help/hc/en-us/articles/360014900233"
MAX_TEXTURE_EDGE = 1024


def decode_glb(data):
    magic, version, file_size, json_size, json_tag = struct.unpack_from("<4sIII4s", data)
    if (magic, version, file_size, json_tag) != (b"glTF", 2, len(data), b"JSON"):
        raise ValueError("Expected complete glTF 2 binary")
    document = json.loads(data[20:20 + json_size])
    start = json_size + 20
    bin_size, bin_tag = struct.unpack_from("<I4s", data, start)
    if bin_tag != b"BIN\0" or start + 8 + bin_size != len(data):
        raise ValueError("Expected one embedded binary chunk")
    return document, memoryview(data)[start + 8:]


def luma(rgb):
    return np.sum(rgb * (0.2126, 0.7152, 0.0722), axis=-1)


def mix(low, high, amount):
    return np.asarray(low) + (np.asarray(high) - np.asarray(low)) * amount[..., None]


def graphite(rgb, shoe=False):
    """Re-dye existing cloth while preserving shading and braided UV details."""
    red, green, blue = np.moveaxis(rgb, -1, 0)
    intensity = luma(rgb)
    weave = mix((15, 17, 26), (62, 64, 83), np.clip((intensity - 65) / 190, 0, 1))
    # Original golden hardware and embroidery become muted nickel.
    hardware = ((red - blue > 36) & (red - green > 8) & (green - blue > 22)) if not shoe else (
        (red - blue > 40) & (green - blue > 23) & (red - green < 92)
    )
    nickel = mix((44, 49, 64), (171, 177, 191), np.clip(intensity / 245, 0, 1))
    trim = (red - green > 24) & (blue - green > 9)
    violet = mix((24, 21, 44), (94, 86, 142), np.clip((intensity - 75) / 175, 0, 1))
    weave[trim] = violet[trim]
    weave[hardware] = nickel[hardware]
    return weave


def leg_surface(rgb, variant):
    """Replace the stocking islands in the known Victoria body atlas."""
    height, width = rgb.shape[:2]
    y = np.linspace(0, 1, height)[:, None]
    x = np.linspace(0, 1, width)[None, :]
    outside = (x <= 0.2405) | (x >= 0.7595)
    red, green, blue = np.moveaxis(rgb, -1, 0)
    cloth = outside & (y >= .648) & ((green >= blue - 21) & (green - blue <= 12))
    # The gold motifs sit on the stocking seam above the main textile.
    trim = outside & (y >= .649) & (y <= .682) & (green - blue > 22) & (red - green < 26)
    # Each outer atlas island has compatible skin above the stocking seam.
    if variant == "bare-legs":
        upper = np.median(rgb[int(.58 * height):int(.625 * height), :, :], axis=0)
        longitudinal = 5 * np.sin(y * np.pi * 3.2) - 5 * np.clip((y - .86) / .14, 0, 1)
        skin = upper[None, :, :] + longitudinal[:, :, None]
        blend = np.clip((y - .629) / .015, 0, 1) * outside
        rgb = rgb * (1 - blend[:, :, None]) + skin * blend[:, :, None]
    else:
        shade = np.clip((luma(rgb) - 125) / 130, 0, 1)
        nylon = mix((18, 19, 26), (43, 45, 59), shade)
        rgb[cloth] = nylon[cloth]
        rgb[trim] = (114, 110, 142)
    return rgb


def recolor(index, image, variant):
    if index == 27:
        return Image.new("RGBA", (1, 1), (0, 0, 0, 0))
    if index in (15, 17, 18, 19, 22, 25):
        values = np.asarray(image.convert("RGBA")).copy()
        rgb = values[:, :, :3].astype(float)
        if index == 15:
            rgb = leg_surface(rgb, variant)
        elif index in (17, 18):
            rgb = graphite(rgb, shoe=index == 18)
        else:
            rgb = mix((98, 109, 133), (233, 239, 251), np.clip((luma(rgb)-55)/200, 0, 1))
        values[:, :, :3] = np.clip(rgb, 0, 255).astype(np.uint8)
        image = Image.fromarray(values)
    if max(image.size) > MAX_TEXTURE_EDGE:
        image.thumbnail((MAX_TEXTURE_EDGE, MAX_TEXTURE_EDGE), Image.Resampling.LANCZOS)
    return image


def modified_asset(source_doc, source_bin, variant):
    doc = deepcopy(source_doc)
    vrm = doc["extensions"]["VRM"]
    if vrm["meta"]["title"] != "Victoria Rubin" or vrm["meta"]["licenseName"] != "CC0":
        raise ValueError("Unexpected source metadata")
    vrm["meta"].update(title="Lumen — ReflexCompanion", version="1.0",
                       author="pixiv Inc. (CC0 base); ReflexCore adaptation", reference=RIGHTS,
                       contactInformation="", otherLicenseUrl="")
    vrm["meta"].pop("texture", None)
    properties = vrm["materialProperties"]
    for i, factors in {
        4: ([0.79, 0.82, 0.91, 1], [0.48, 0.51, 0.65, 1]),
        12: ([0.97, 0.99, 1, 1], [0.64, 0.68, 0.8, 1]),
        13: ([0.97, 0.99, 1, 1], [0.64, 0.68, 0.8, 1]),
        14: ([0.91, 0.94, 1, 1], [0.62, 0.66, 0.78, 1]),
        15: ([0.52, 0.47, 0.77, 1], [0.24, 0.2, 0.47, 1]),
    }.items():
        color, shade = factors
        doc["materials"][i]["pbrMetallicRoughness"]["baseColorFactor"] = color
        props = properties[i]["vectorProperties"]
        props["_Color"], props["_ShadeColor"] = color, shade
        if i >= 12:
            props["_EmissionColor"] = [0, 0, 0, 1]
    for i in (10, 11):
        props = properties[i]["vectorProperties"]
        props["_ShadeColor"] = [0.6, 0.61, 0.77, 1]
        props["_OutlineColor"] = [0.08, 0.08, 0.12, 1]

    textures_by_view = {im["bufferView"]: i for i, im in enumerate(doc["images"])}
    dst = bytearray()
    for index, view in enumerate(doc["bufferViews"]):
        start = view.get("byteOffset", 0)
        data = source_bin[start:start + view["byteLength"]]
        if index in textures_by_view:
            image_index = textures_by_view[index]
            with Image.open(BytesIO(data)) as image:
                # Leave untouched full-size source PNGs byte-identical.
                if image_index in (15, 17, 18, 19, 22, 25, 27) or max(image.size) > MAX_TEXTURE_EDGE:
                    replacement = BytesIO()
                    recolor(image_index, image, variant).save(replacement, format="PNG", optimize=True)
                    data = replacement.getvalue()
        dst += b"\0" * ((-len(dst)) % 4)
        view["byteOffset"], view["byteLength"] = len(dst), len(data)
        dst.extend(data)
    dst += b"\0" * ((-len(dst)) % 4)
    doc["buffers"][0]["byteLength"] = len(dst)
    header = json.dumps(doc, separators=(",", ":"), ensure_ascii=False).encode()
    header += b" " * ((-len(header)) % 4)
    return (
        struct.pack("<4sIII4s", b"glTF", 2, 28 + len(header) + len(dst), len(header), b"JSON")
        + header + struct.pack("<I4s", len(dst), b"BIN\0") + dst
    )


def main():
    parser = ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=Path("Victoria_Rubin.vrm"))
    parser.add_argument("--output", type=Path, default=Path("export"))
    parser.add_argument("--download", action="store_true", help="Download the pinned CC0 source if absent")
    args = parser.parse_args()
    if args.download and not args.source.exists():
        with urllib.request.urlopen(SOURCE, timeout=30) as reply:
            received = reply.read(20 * 1024 * 1024 + 1)
        if sha256(received).hexdigest() != SHA256:
            raise SystemExit("Source SHA-256 mismatch")
        args.source.write_bytes(received)
    data = args.source.read_bytes()
    if sha256(data).hexdigest() != SHA256:
        raise SystemExit("Source SHA-256 mismatch")
    doc, buffer = decode_glb(data)
    args.output.mkdir(parents=True, exist_ok=True)
    for variant in ("stockings", "bare-legs"):
        model = modified_asset(doc, buffer, variant)
        path = args.output / ("Lumen-" + variant + ".vrm")
        path.write_bytes(model)
        print(f"{sha256(model).hexdigest()}  {len(model):,}  {path.name}")


if __name__ == "__main__":
    main()
