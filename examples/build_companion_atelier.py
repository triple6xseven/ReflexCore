#!/usr/bin/env python3
"""Build the private Atelier variants from the two verified Midnight VRMs."""
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
from build_companion_midnight import accessor, append_accessor, split

SOURCES = {
    "d120785d9a9ff82d7e683fb87c8a5530ce11d56e7853596378e1c1f50f4ae0b7": False,
    "033f9d7b1c2a8574e96969b320cef2321fdec9df2a35327956cc7bffbf98a2e2": True,
}
TEXTURES = {
    5: "liner", 7: "liner", 9: "iris", 10: "catchlight", 11: "face",
    19: "hair_cap", 22: "hair", 25: "hair", 26: "hair",
}
COLORS = {
    "Corset panel": [.047, .037, .080, 1],
    "Woven harness": [.115, .082, .174, 1],
    "Harness piping": [.245, .137, .384, 1],
    "High collar": [.024, .018, .039, 1],
    "Nickel crest": [.50, .51, .65, 1],
    "Amethyst inset": [.32, .094, .57, 1],
    "Shorts side panel": [.060, .039, .103, 1],
    "Stocking cuff": [.102, .069, .155, 1],
    "Stocking knit": [.023, .022, .037, 1],
}


def gaussian(x, y, cx, cy, sx, sy):
    return np.exp(-.5 * (((x-cx)/sx)**2 + ((y-cy)/sy)**2))


def paint(image, style):
    rgba = np.asarray(image.convert("RGBA")).copy()
    rgb = rgba[:, :, :3].astype(float)
    height, width = rgb.shape[:2]
    y, x = np.mgrid[0:height, 0:width].astype(float)
    x /= width
    y /= height
    brightness = rgb.mean(axis=2)
    if style == "iris":
        for left, right in ((0, width//2), (width//2, width)):
            yy, xx = np.where(rgba[:, left:right, 3] > 100)
            if len(xx) == 0:
                continue
            xx += left
            cx = (xx.min()+xx.max()) / (2*width)
            cy = (yy.min()+yy.max()) / (2*height)
            xx = (x-cx) / max((xx.max()-xx.min())/(2*width), .01)
            yy = (y-cy) / max((yy.max()-yy.min())/(2*height), .01)
            radius = np.hypot(xx, yy)
            angle = np.arctan2(yy, xx)
            fibers = (np.sin(angle*39 + radius*13) + np.sin(angle*63-radius*22)) * 6
            ring = np.exp(-((radius-.82)/.18)**2)
            light = np.clip(.48+yy*.41 + .16*ring, 0, 1)
            pupil = np.exp(-(radius/.43)**4)
            limbal = np.clip((radius-.82)/.25, 0, 1)
            blue = np.array([30,55,131]) + light[..., None]*[43,121,116]
            blue += (fibers*ring)[..., None]*[.7,1,1]
            blue *= (1-.67*pupil-.48*limbal)[..., None]
            rgb[:, left:right] = blue[:, left:right]
    elif style == "catchlight":
        rgb = rgb*.25 + [185,191,190]
    elif style == "liner":
        rgb = 0.43*rgb + [17,10,33]
    elif style == "face":
        blush = gaussian(x,y,.28,.646,.063,.043)+gaussian(x,y,.72,.646,.063,.043)
        light = gaussian(x,y,.50,.566,.071,.089)
        rgb += blush[..., None]*[2,-13,-8]+light[..., None]*[2,3,4]
    elif style in ("hair", "hair_cap"):
        detail = (brightness-np.median(brightness))*.55
        if style == "hair":
            sheen = 18*np.exp(-((y-.35-.035*np.sin(x*22))/.15)**2)
            micro = 2.2*np.sin(x*176)+1.2*np.sin(x*337)
            depth = 19*y**1.8 + 11*np.exp(-y*8)
        else:
            sheen = 13*np.exp(-((y-.25)/.21)**2)
            micro = 0
            depth = 0
        light = detail+sheen+micro-depth
        rgb = np.array([205,202,222])+light[..., None]*[1,1,1.12]
    rgba[:, :, :3] = np.clip(rgb, 0, 255).astype(np.uint8)
    return Image.fromarray(rgba)


def replace_textures(doc, source, buffer):
    for index, style in TEXTURES.items():
        image = doc["images"][index]
        view = doc["bufferViews"][image["bufferView"]]
        begin = view["byteOffset"]
        with Image.open(BytesIO(source[begin:begin+view["byteLength"]])) as original:
            updated = paint(original, style)
        png = BytesIO()
        updated.save(png, format="PNG", optimize=True)
        buffer.extend(b"\0" * (-len(buffer)%4))
        image["bufferView"] = len(doc["bufferViews"])
        doc["bufferViews"].append({"buffer": 0, "byteOffset": len(buffer), "byteLength": png.tell()})
        image["mimeType"] = "image/png"
        buffer.extend(png.getvalue())


def shape_hair(doc, source, buffer):
    hair = next(mesh for mesh in doc["meshes"] if mesh["name"] == "Hair001.baked")
    points = accessor(doc, source, hair["primitives"][0]["attributes"]["POSITION"]).copy()
    x, y, z = points.T.copy()
    # The ponytail sits behind the head on positive Z in this VRM.
    tail = np.clip((z-.041)/.13, 0, 1) * np.clip((1.64-y)/.28, 0, 1)
    points[:, 1] -= .22*tail
    points[:, 0] = x*(1.03+.11*tail)-.047*tail
    points[:, 2] = z*(1.03+.17*tail)+.032*tail
    index = append_accessor(doc, buffer, points, "VEC3", 5126)
    for primitive in hair["primitives"]:
        primitive["attributes"]["POSITION"] = index


def take(polygon, planes):
    outside = []
    for plane in planes:
        polygon, remainder = split(polygon, plane)
        outside.append(remainder)
    return polygon, outside


def band(axis, low, high):
    return (lambda p: axis(p)-low, lambda p: high-axis(p))


def diamond(cx, cy, width, height):
    return tuple(
        lambda p, x=x, y=y: 1-x*(p[0]-cx)/width-y*(p[1]-cy)/height
        for x, y in ((1,1),(1,-1),(-1,1),(-1,-1))
    )


def crest(columns):
    """A bevelled chest crest and raised amethyst, with inherited chest weights."""
    for sides, depth, inner, fabric in (
        ((.026,.033),.132,.68,"Nickel crest"),
        ((.017,.023),.139,.16,"Amethyst inset"),
    ):
        bound_x,bound_y = sides
        center = np.array([0,1.265,-depth])
        positions = columns[0]
        mask = positions[:,2]<-.08
        nearest = np.argmin(np.sum((positions-center)**2,axis=1)+np.where(mask,0,10))
        joints, weights = columns[3][nearest], columns[4][nearest]
        outer = [(0,bound_y),(-bound_x,0),(0,-bound_y),(bound_x,0)]
        outer = [center+[x,y,0] for x,y in outer]
        lifted = [center+(vertex-center)*inner+[0,0,-.006] for vertex in outer]
        for i in range(4):
            a,b,c,d = outer[i],outer[(i+1)%4],lifted[(i+1)%4],lifted[i]
            for face in ((a,c,b),(a,d,c),(d,lifted[(i+1)%4],center+[0,0,-.008])):
                a,b,c = face
                normal = np.cross(b-a,c-a)
                normal = normal/max(np.linalg.norm(normal),1e-8)
                if normal[2]>0:
                    normal = -normal
                yield fabric, [(p,normal,(0,0),joints,weights) for p in face]


def cut_panels(primitive_name, stocking):
    x = lambda p: p[0]
    y = lambda p: p[1]
    face = lambda p: -.025-p[2]
    if primitive_name == "Fitted top":
        front = [face]
        zipper = [*front, *band(y,1.064,1.235), *band(x,-.005,.005)]
        left = lambda p: p[0]-.48*(p[1]-1.26)
        right = lambda p: p[0]+.48*(p[1]-1.26)
        return [
            ("High collar", [lambda p: p[1]-1.378]),
            ("Nickel crest",zipper),
            ("Harness piping", [*front, *band(y,1.255,1.391), *band(left,-.021,-.012)]),
            ("Woven harness", [*front, *band(y,1.246,1.391), *band(left,-.043,-.012)]),
            ("Woven harness", [*front, *band(y,1.246,1.391), *band(right,.012,.043)]),
            ("Corset panel", [*band(y,1.065,1.193),
                *diamond(0,1.106,.114,.15)]),
        ]
    if primitive_name == "Tailored shorts":
        return [
            ("Nickel crest", [*front_planes(.031,.062), *band(y,.936,.962)]),
            ("Harness piping", [*band(y,.854,.995), lambda p: p[0]+.27*p[2]-.123]),
            ("Shorts side panel", [lambda p: p[0]-.098]),
            ("Shorts side panel", [lambda p: -.098-p[0]]),
        ]
    if stocking and "_Body_00_SKIN" in primitive_name:
        return [
            ("Stocking cuff", list(band(y,.672,.693))),
            ("Stocking knit", [lambda p: .672-p[1]]),
        ]
    return []


def front_planes(left, right):
    return [lambda p: -.033-p[2], *band(lambda p: p[0], left, right)]


def outfit(doc, source, buffer, stockings):
    body = next(mesh for mesh in doc["meshes"] if mesh["name"] == "Body.baked")
    fields = ("POSITION","NORMAL","TEXCOORD_0","JOINTS_0","WEIGHTS_0")
    groups = defaultdict(list)
    unchanged = []
    materials = {m["name"]: i for i,m in enumerate(doc["materials"])}
    for primitive in body["primitives"]:
        name = doc["materials"][primitive["material"]]["name"]
        pattern = cut_panels(name, stockings)
        if not pattern or "indices" in primitive:
            unchanged.append(primitive)
            continue
        columns = [accessor(doc,source,primitive["attributes"][field]) for field in fields]
        if name == "Fitted top":
            for fabric, face in crest(columns):
                groups[fabric].append(face)
        for triangle in range(0,len(columns[0]),3):
            pending = [[tuple(col[vertex] for col in columns) for vertex in range(triangle,triangle+3)]]
            for fabric, planes in pattern:
                remainder = []
                for polygon in pending:
                    patch, outside = take(polygon, planes)
                    if len(patch)>=3:
                        groups[fabric].append(patch)
                    remainder.extend(piece for piece in outside if len(piece)>=3)
                pending = remainder
            groups[name].extend(pending)

    for name, polygons in groups.items():
        if name not in materials:
            materials[name] = len(doc["materials"])
            doc["materials"].append({"name":name,"doubleSided":True,"pbrMetallicRoughness":{
                "baseColorFactor":COLORS[name],"roughnessFactor":.47 if name.startswith("Nickel") else .85,
            }})
        vertices = []
        for polygon in polygons:
            for i in range(1,len(polygon)-1):
                a,b,c = polygon[0],polygon[i],polygon[i+1]
                if np.linalg.norm(np.cross(b[0]-a[0],c[0]-a[0])) > 1e-9:
                    vertices.extend((a,b,c))
        if not vertices:
            continue
        attributes = {
            field:append_accessor(doc,buffer,column,shape,kind)
            for field,column,shape,kind in zip(fields,zip(*vertices),
                ("VEC3","VEC3","VEC2","VEC4","VEC4"),(5126,5126,5126,5123,5126))
        }
        unchanged.append({"mode":4,"material":materials[name],"attributes":attributes})
    body["primitives"] = unchanged


def build(data):
    digest = sha256(data).hexdigest()
    if digest not in SOURCES:
        raise ValueError("Expected one of the verified Midnight VRMs.")
    doc, source = decode_glb(data)
    buffer = bytearray(source)
    replace_textures(doc, source, buffer)
    shape_hair(doc, source, buffer)
    outfit(doc, source, buffer, SOURCES[digest])
    doc["extensions"]["VRM"]["meta"]["title"] = "Lumen - ReflexCompanion Midnight Atelier"
    doc["buffers"][0]["byteLength"] = len(buffer)
    tree = json.dumps(doc,separators=(",",":"),ensure_ascii=True).encode()
    tree += b" " * (-len(tree)%4)
    buffer.extend(b"\0" * (-len(buffer)%4))
    return b"".join((
        struct.pack("<4sII",b"glTF",2,28+len(tree)+len(buffer)),
        struct.pack("<I4s",len(tree),b"JSON"),tree,
        struct.pack("<I4s",len(buffer),b"BIN\0"),buffer,
    ))


if __name__ == "__main__":
    parser = ArgumentParser(description=__doc__)
    parser.add_argument("source",type=Path)
    parser.add_argument("output",type=Path)
    args = parser.parse_args()
    model = build(args.source.read_bytes())
    with args.output.open("xb") as output:
        output.write(model)
    print(f"Atelier VRM written. SHA-256 {sha256(model).hexdigest()}")
