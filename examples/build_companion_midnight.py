#!/usr/bin/env python3
"""Tailor a separate Midnight VRM from the supported Lumen exports."""
from argparse import ArgumentParser
from collections import defaultdict
from hashlib import sha256
from io import BytesIO
import json
from pathlib import Path
import struct

import numpy as np
from PIL import Image

from build_companion_avatar import decode_glb


SOURCE_HASHES = {
    "c4d9f59ca5feb038711132a2bb7940ab208c0425171171ddf5e14b977e25b291",
    "4c0d3a3f869b5b7c554a1ca133fe7bc34361246bb8bb7700e099517d038e82e4",
}
# Linear glTF colors. The trim and waistband are actual sections of the mesh.
FABRICS = {
    "Tailored shorts": ([.023, .025, .044, 1], .82, .0),
    "Violet piping": ([.115, .053, .235, 1], .64, .0),
    "Graphite belt": ([.044, .033, .068, 1], .51, .12),
    "Fitted top": ([.034, .027, .055, 1], .75, .0),
    "Brushed nickel clasp": ([.43, .49, .62, 1], .34, .24),
}
FORMATS = {5126: "<f4", 5123: "<u2", 5125: "<u4"}
COMPONENTS = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4}


def accessor(doc, buffer, index):
    info = doc["accessors"][index]
    view = doc["bufferViews"][info["bufferView"]]
    dtype = np.dtype(FORMATS[info["componentType"]])
    width = COMPONENTS[info["type"]]
    return np.ndarray(
        (info["count"], width), dtype, buffer,
        view.get("byteOffset", 0) + info.get("byteOffset", 0),
        (view.get("byteStride", width * dtype.itemsize), dtype.itemsize),
    )


def append_accessor(doc, buffer, rows, shape, component):
    array = np.asarray(rows, dtype=FORMATS[component])
    while len(buffer) % 4:
        buffer.append(0)
    view = len(doc["bufferViews"])
    doc["bufferViews"].append({
        "buffer": 0, "byteOffset": len(buffer), "byteLength": array.nbytes,
    })
    buffer.extend(array.tobytes())
    info = {"bufferView": view, "componentType": component, "count": len(rows), "type": shape}
    if shape == "VEC3":
        info.update(min=array.min(axis=0).tolist(), max=array.max(axis=0).tolist())
    doc["accessors"].append(info)
    return len(doc["accessors"]) - 1


def interpolate(a, b, weight):
    position, normal, uv = (x + (y - x) * weight for x, y in zip(a[:3], b[:3]))
    influences = defaultdict(float)
    for vertex, scale in ((a, 1 - weight), (b, weight)):
        for joint, influence in zip(vertex[3], vertex[4]):
            influences[int(joint)] += float(influence) * scale
    pairs = sorted(influences.items(), key=lambda pair: -pair[1])[:4]
    pairs += [(0, 0)] * (4 - len(pairs))
    joints, weights = zip(*pairs)
    return position, normal, uv, joints, np.asarray(weights) / sum(weights)


def split(polygon, plane):
    positive, negative = [], []
    for a, b in zip(polygon, polygon[1:] + polygon[:1]):
        start, end = plane(a[0]), plane(b[0])
        if start >= 0:
            positive.append(a)
        else:
            negative.append(a)
        if (start >= 0) != (end >= 0) and abs(start - end) > 1e-9:
            edge = interpolate(a, b, start / (start - end))
            positive.append(edge)
            negative.append(edge)
    return positive, negative


def pattern(triangle):
    """Cut the skinned surface at the leg hems, waist, neckline and armholes."""
    remainder = triangle
    bands = [
        (.805, None), (.822, "Violet piping"), (1.013, "Tailored shorts"),
        (1.023, "Violet piping"), (1.063, "Graphite belt"), (1.073, "Violet piping"),
    ]
    for height, fabric in bands:
        if not remainder:
            return
        below, remainder = split(remainder, lambda vertex: height - vertex[1])
        if fabric == "Graphite belt":
            clasp = below
            for plane in (lambda v: v[0]+.021, lambda v: .021-v[0], lambda v: -.069-v[2]):
                clasp, belt = split(clasp, plane)
                yield fabric, belt
            yield "Brushed nickel clasp", clasp
        else:
            yield fabric, below
    for plane in (lambda v: 1.403-v[1], lambda v: .143-v[0], lambda v: v[0]+.143):
        remainder, skin = split(remainder, plane)
        yield None, skin
    yield "Fitted top", remainder


def tailored_surfaces(doc, source, buffer, primitive):
    fields = primitive["attributes"]
    names = ["POSITION", "NORMAL", "TEXCOORD_0", "JOINTS_0", "WEIGHTS_0"]
    attributes = [accessor(doc, source, fields[name]) for name in names]
    triangles = accessor(doc, source, primitive["indices"]).reshape(-1, 3)
    groups = defaultdict(list)
    for triangle in triangles:
        vertices = [tuple(field[index] for field in attributes) for index in triangle]
        for fabric, polygon in pattern(vertices):
            for corner in range(1, len(polygon)-1):
                a, b, c = polygon[0], polygon[corner], polygon[corner+1]
                if np.linalg.norm(np.cross(b[0]-a[0], c[0]-a[0])) > 1e-9:
                    groups[fabric].extend((a, b, c))
    result = []
    for fabric, vertices in groups.items():
        if fabric is None:
            material = primitive["material"]
        else:
            color, roughness, metalness = FABRICS[fabric]
            material = len(doc["materials"])
            doc["materials"].append({"name": fabric, "doubleSided": True, "pbrMetallicRoughness": {
                "baseColorFactor": color, "roughnessFactor": roughness, "metallicFactor": metalness,
            }})
        rows = list(zip(*vertices))
        result.append({"mode": 4, "material": material, "attributes": {
            name: append_accessor(doc, buffer, column, shape, component)
            for name, column, shape, component in zip(
                names, rows, ["VEC3", "VEC3", "VEC2", "VEC4", "VEC4"], [5126, 5126, 5126, 5123, 5126],
            )
        }})
    return result


def barefoot_surface(doc, source, buffer, primitive, stockings):
    source_material = doc["materials"][primitive["material"]]
    original_texture = source_material["pbrMetallicRoughness"]["baseColorTexture"]["index"]
    image_info = doc["images"][doc["textures"][original_texture]["source"]]
    view = doc["bufferViews"][image_info["bufferView"]]
    offset = view["byteOffset"]
    with Image.open(BytesIO(source[offset:offset+view["byteLength"]])) as image:
        pixels = np.asarray(image.convert("RGB"), dtype=np.float32)
    height, width = pixels.shape[:2]
    ankle = np.median(
        pixels[int(height*.966):int(height*.986), int(width*.05):int(width*.15)], axis=(0, 1),
    )
    # A separate foot material keeps the face, hands, and body atlas unchanged.
    crop = pixels[int(height*.58):int(height*.79), int(width*.23):int(width*.77)]
    tone = np.clip((crop.mean(axis=2) - 220) * .17, -14, 5)
    y = np.linspace(0, 1, len(crop))[:, None]
    tone *= np.clip(y * 3, 0, 1)
    if stockings:
        tone *= .37
    adjusted = np.clip(ankle + tone[:, :, None], 0, 255).astype(np.uint8)
    png = BytesIO()
    Image.fromarray(adjusted).save(png, format="PNG")
    while len(buffer) % 4:
        buffer.append(0)
    doc["bufferViews"].append({"buffer": 0, "byteOffset": len(buffer), "byteLength": png.tell()})
    buffer.extend(png.getvalue())
    doc["images"].append({"bufferView": len(doc["bufferViews"])-1, "mimeType": "image/png"})
    doc["textures"].append({"source": len(doc["images"])-1})
    doc["materials"].append({
        "name": "Midnight stocking feet" if stockings else "Midnight barefoot",
        "pbrMetallicRoughness": {"baseColorTexture": {"index": len(doc["textures"])-1}},
        "extensions": {"KHR_materials_unlit": {}},
    })
    indices = accessor(doc, source, primitive["indices"]).ravel()
    attrs = primitive["attributes"]
    uv = accessor(doc, source, attrs["TEXCOORD_0"])[indices]
    uv = (uv - [.23, .58]) / [.54, .21]
    fields = {
        name: append_accessor(doc, buffer, accessor(doc, source, index)[indices],
                              doc["accessors"][index]["type"], doc["accessors"][index]["componentType"])
        for name, index in attrs.items() if name != "TEXCOORD_0"
    }
    fields["TEXCOORD_0"] = append_accessor(doc, buffer, uv, "VEC2", 5126)
    return {"mode": 4, "material": len(doc["materials"])-1, "attributes": fields}


def build(data):
    if sha256(data).hexdigest() not in SOURCE_HASHES:
        raise ValueError("Unsupported source. Use an unmodified Lumen Original VRM.")
    doc, source = decode_glb(data)
    buffer = bytearray(source)
    body = next(mesh for mesh in doc["meshes"] if mesh["name"] == "Body.baked")
    tailored = tailored_surfaces(doc, source, buffer, body["primitives"][0])
    stockings = sha256(data).hexdigest().startswith("c4d9f59c")
    feet = barefoot_surface(doc, source, buffer, body["primitives"][1], stockings)
    body["primitives"] = tailored + [feet] + [
        p for p in body["primitives"][2:]
        if not any(part in doc["materials"][p["material"]]["name"] for part in ("_Tops_", "_Shoes_"))
    ]
    doc["extensions"]["VRM"]["meta"]["title"] = "Lumen - ReflexCompanion Midnight Edition"
    doc["buffers"][0]["byteLength"] = len(buffer)
    tree = json.dumps(doc, separators=(",", ":"), ensure_ascii=True).encode()
    tree += b" " * (-len(tree) % 4)
    buffer.extend(b"\0" * (-len(buffer) % 4))
    return b"".join((
        struct.pack("<4sII", b"glTF", 2, 28+len(tree)+len(buffer)),
        struct.pack("<I4s", len(tree), b"JSON"), tree,
        struct.pack("<I4s", len(buffer), b"BIN\0"), buffer,
    ))


if __name__ == "__main__":
    parser = ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    options = parser.parse_args()
    model = build(options.source.read_bytes())
    with options.output.open("xb") as output:
        output.write(model)
    print(f"Midnight VRM written. SHA-256 {sha256(model).hexdigest()}")
