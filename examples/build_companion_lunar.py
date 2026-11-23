"""Tailor Lunar Temptation on the private Midnight Nocturne rig."""
from argparse import ArgumentParser
from collections import defaultdict
from math import cos, pi, sin
from pathlib import Path
import json
import struct

import numpy as np

from build_companion_midnight import accessor, split
from build_companion_nocturne import FIELDS, collect, decode_glb, surface, triangle


PALETTE = {
    "pearlescent hair": (.67, .56, .78),
    "lilac hair": (.52, .40, .67),
    "silk": (.073, .045, .119),
    "panel": (.103, .061, .157),
    "seam": (.34, .21, .50),
    "cuff": (.16, .091, .23),
    "liner": (.59, .45, .66),
    "stocking": (.086, .060, .110),
    "nickel": (.59, .51, .69),
}


def rings_to_mesh(groups, rows, fabric):
    """Stitch consecutive rings with smooth vertex normals and per-ring skinning."""
    for ring, (first, second) in enumerate(zip(rows, rows[1:])):
        for index in range(len(first) - 1):
            key = fabric(ring, index)
            collect(groups, key, [first[index], first[index + 1], second[index]])
            collect(groups, key, [first[index + 1], second[index + 1], second[index]])


def ring(center, axes, radii, joints, weights, samples=20):
    origin = np.asarray(center)
    axis_a, axis_b = np.asarray(axes)
    radius_a, radius_b = radii
    vertices = []
    for side in range(samples + 1):
        angle = side * 2 * pi / samples
        offset = axis_a * cos(angle) * radius_a + axis_b * sin(angle) * radius_b
        normal = axis_a * cos(angle) / radius_a + axis_b * sin(angle) / radius_b
        vertices.append((origin + offset, normal / np.linalg.norm(normal), (0, 0), joints, weights))
    return vertices


def tailor_body(doc, source, mesh, groups):
    materials = doc["materials"]
    retained = []
    skin = next(i for i, item in enumerate(materials) if "_Body_00_SKIN" in item["name"])
    for primitive in mesh["primitives"]:
        material = primitive["material"]
        name = materials[material]["name"]
        points = accessor(doc, source, primitive["attributes"]["POSITION"])
        leg_skin = material == skin and points[:, 1].min() < .86
        if name not in {"Fitted top", "Harness piping", "Midnight barefoot", "Midnight stocking feet",
                        "Stocking knit", "Stocking cuff", "Nocturne strap", "Nocturne piping"} and not leg_skin:
            retained.append(primitive)
            continue
        columns = [accessor(doc, source, primitive["attributes"][field]) for field in FIELDS]
        indices = (accessor(doc, source, primitive["indices"]).ravel() if "indices" in primitive
                   else range(len(points)))
        for offset in range(0, len(indices), 3):
            vertices = [tuple(column[index] for column in columns) for index in indices[offset:offset+3]]
            if name in {"Fitted top", "Harness piping"}:
                front, back = split(vertices, lambda p: -.015-p[2])
                for polygon, front_side in ((front, True), (back, False)):
                    if front_side:
                        def neckline(p):
                            return 1.345 + .51 * abs(p[0]) - p[1]
                    else:
                        def neckline(p):
                            return 1.348 + .02 * abs(p[0]) - p[1]
                    # Keep the harness over the open neckline. The sleeve geometry covers the upper arm.
                    if name == "Harness piping":
                        collect(groups, material, polygon)
                        continue
                    top, exposed = split(polygon, neckline)
                    cloth, lip = split(top, lambda p: neckline(p)-.010)
                    collect(groups, skin, exposed)
                    collect(groups, "seam", lip)
                    collect(groups, "silk", cloth)
            elif name == "Nocturne piping":
                upper, lining = split(vertices, lambda p: p[1]-.929)
                outer, inner = split(lining, lambda p: abs(p[0])-.047)
                collect(groups, "liner", outer)
                collect(groups, "panel", inner)
                collect(groups, "silk", upper)
            elif name in {"Stocking knit", "Stocking cuff", "Midnight stocking feet"}:
                collect(groups, "stocking", vertices)
            elif name == "Midnight barefoot":
                # Leave the forefoot as a bridge between the individually modeled toes.
                trimmed = []
                for point, normal, uv, joints, weights in vertices:
                    point = point.copy()
                    if point[2] < -.087:
                        point[2] = -.087 + (point[2]+.087)*.31
                    trimmed.append((point, normal, uv, joints, weights))
                collect(groups, material, trimmed)
            elif name == "Nocturne strap" or (leg_skin and points[:, 1].max() < .93):
                liner, lower = split(vertices, lambda p:p[1]-.915)
                skin_above, band = split(lower, lambda p:p[1]-.881)
                cuff, exposed = split(band, lambda p:p[1]-.868)
                collect(groups, "liner", liner)
                collect(groups, skin, skin_above)
                collect(groups, "cuff", cuff)
                collect(groups, skin, exposed)
            else:
                collect(groups, material, vertices)
    mesh["primitives"] = retained


def add_armwear(groups, joints):
    for side, sign in (("L", -1), ("R", 1)):
        upper = joints.index(f"J_Bip_{side}_UpperArm")
        lower = joints.index(f"J_Bip_{side}_LowerArm")
        pair = (upper, lower, 0, 0)
        rows = []
        for x, radius, blend in ((.205,.043,0),(.215,.046,0),(.238,.045,0),
                                 (.275,.044,.02),(.310,.042,.20),(.340,.044,.78),
                                 (.382,.047,1),(.443,.051,1),(.512,.043,1),(.530,.037,1)):
            rows.append(ring((sign*x, 1.453, -.017*(x-.205)/.325),
                             ((0,1,0),(0,0,-sign)), (radius,radius*.92),
                             pair, (1-blend,blend,0,0)))
        rings_to_mesh(groups, rows, lambda row, edge: "cuff" if row in {0, 7, 8}
                      else "seam" if edge in {2,13} else "panel" if edge in {3,4,5} else "silk")


def add_panels(groups, joints):
    hips = joints.index("J_Bip_C_Hips")
    # Two pleated side panels. The front opening stays clear of the knees.
    for sign in (-1, 1):
        rows = []
        for y, radius_x, radius_z, angle_start, angle_end in (
            (1.111,.118,.089,.51,2.75),(1.051,.146,.101,.71,2.73),
            (.990,.169,.108,.87,2.69),(.968,.176,.112,.96,2.63),
        ):
            row = []
            for index in range(13):
                t = index/12
                angle = angle_start + (angle_end-angle_start)*t
                pleat = 1+.045*cos(index*pi/2)
                point = (sign*sin(angle)*radius_x*pleat,y,-cos(angle)*radius_z*pleat)
                normal = (sign*sin(angle),0,-cos(angle))
                row.append((np.asarray(point),normal,(0,0),(hips,0,0,0),(1,0,0,0)))
            rows.append(row if sign>0 else list(reversed(row)))
        rings_to_mesh(groups, rows, lambda row, edge: "seam" if row == 2 or edge == 0
                      else "panel" if edge%4 in {0,1} else "silk")
    for x in (-.075, .078):
        triangle(groups, "nickel", ((x-.01,1.128,-.100),(x,1.117,-.107),(x+.01,1.128,-.100)), hips)
        triangle(groups, "nickel", ((x+.01,1.128,-.100),(x,1.139,-.107),(x-.01,1.128,-.100)), hips)


def add_toes(groups, doc, source, mesh, joints):
    foot_material = next(i for i, item in enumerate(doc["materials"]) if item["name"] == "Midnight barefoot")
    material_mesh = next(p for p in mesh if p["material"] == foot_material)
    coords = accessor(doc, source, material_mesh["attributes"]["POSITION"])
    texcoords = accessor(doc, source, material_mesh["attributes"]["TEXCOORD_0"])
    for side, sign in (("L",-1),("R",1)):
        bone = joints.index(f"J_Bip_{side}_Foot")
        uv = texcoords[np.argmin(np.linalg.norm(coords-(sign*.045,.049,-.087),axis=1))]
        for x, tip, width, height in (
            (.025,-.116,.0105,.011),(.042,-.117,.008,.0095),(.055,-.112,.007,.0085),
            (.066,-.105,.006,.0075),(.075,-.096,.0055,.0068),
        ):
            rows = []
            for t, scale in ((0,.88),(.39,1),(.74,.90),(.94,.56),(1,.08)):
                z = -.078 + (tip + .078)*t
                center = (sign*(x+.002*t), .047-.001*t, z)
                vertices = ring(center, ((1,0,0),(0,-1,0)), (width*scale,height*scale),
                                (bone,0,0,0),(1,0,0,0),12)
                rows.append([(point,normal,uv,indices,weights) for point,normal,_,indices,weights in vertices])
            rings_to_mesh(groups, rows, lambda row, index: foot_material)


def add_hair(groups, joints):
    head = joints.index("J_Bip_C_Head")
    # The Nocturne back locks remain in the source. Skin the new locks to their upper spring joint.
    back_spring = next((i for i,n in enumerate(joints) if n.startswith("HairJoint-67552399")), head)
    for strand in range(8):
        angle = strand*2*pi/8
        rows = []
        for segment in range(18):
            t = segment/17
            width = .002+.023*sin(pi*t)**.72
            center = (.047*cos(angle)+.11*t*sin(angle)+.07*sin(t*pi/1.35),
                      1.753-(.62+.075*cos(angle))*t+.039*sin(t*pi*2),
                      .117+.155*sin(t*pi*.78)+.044*cos(angle)*(1-.4*t))
            blend = min(.75,t*1.3)
            rows.append(ring(center, ((1,0,0),(0,0,-1)), (width,width*.57),
                             (head,back_spring,0,0),(1-blend,blend,0,0),12))
        rings_to_mesh(groups, rows, lambda row, edge: "lilac hair" if edge in {2,3,8,9} else "pearlescent hair")
    for side, sign in (("L",-1),("R",1)):
        root = "HairJoint-b85bb5b7" if side == "L" else "HairJoint-c6b7b433"
        spring = next((i for i,n in enumerate(joints) if n.startswith(root)), head)
        rows = []
        for t in np.linspace(0,1,15):
            width = .0015+.015*sin(pi*t)**.65
            center = (sign*(.101+.028*sin(pi*t)+.013*t),1.70-.34*t,-.054-.033*sin(pi*t))
            rows.append(ring(center, ((1,0,0),(0,0,-1)), (width,width*.52),
                             (head,spring,0,0),(1-t,t,0,0),12))
        rings_to_mesh(groups, rows, lambda row, edge: "pearlescent hair" if edge<7 else "lilac hair")
    # A small amethyst clip above the face-framing lock.
    center = np.array((-.073,1.748,-.110))
    tips = [center+offset for offset in ((-.019,0,0),(0,.029,0),(.016,0,0),(0,-.027,0))]
    for index in range(4):
        triangle(groups, "seam" if index%2 else "nickel",
                 (tips[index],tips[(index+1)%4],center+(0,0,-.012)),head)


def build(source, stockings):
    doc, binary = decode_glb(source)
    if doc["extensions"]["VRM"]["meta"]["title"] != "Lumen - ReflexCompanion Midnight Nocturne":
        raise ValueError("Expected Midnight Nocturne")
    buffer = bytearray(binary)
    colors = {}
    for name, color in PALETTE.items():
        colors[name] = len(doc["materials"])
        doc["materials"].append({"name":f"Lunar {name}", "doubleSided":True, "pbrMetallicRoughness":{
            "baseColorFactor":[*color,1], "roughnessFactor":.58, "metallicFactor":0}})
    for part in ("Body","Hair001"):
        node = next(n for n in doc["nodes"] if n.get("name") == part)
        mesh = doc["meshes"][node["mesh"]]
        joints = [doc["nodes"][i].get("name","") for i in doc["skins"][node["skin"]]["joints"]]
        groups = defaultdict(list)
        if part == "Body":
            old_primitives = mesh["primitives"]
            has_stockings = any(doc["materials"][p["material"]]["name"] == "Stocking knit" for p in old_primitives)
            if stockings != has_stockings:
                raise ValueError("Pass the matching Nocturne source for the requested legwear")
            tailor_body(doc, binary, mesh, groups)
            if stockings:
                # Extend the existing opaque knit through the upper thigh with a scalloped top.
                for key, vertices in list(groups.items()):
                    if isinstance(key,str) or "_Body_00_SKIN" not in doc["materials"][key]["name"]:
                        continue
                    groups[key] = []
                    for offset in range(0,len(vertices),3):
                        polygon = vertices[offset:offset+3]
                        skin, lower = split(polygon, lambda p:p[1]-(.805+.007*cos(p[2]*170)))
                        cuff, knit = split(lower, lambda p:p[1]-.781)
                        collect(groups,key,skin)
                        collect(groups,"cuff",cuff)
                        collect(groups,"stocking",knit)
            else:
                add_toes(groups, doc, binary, old_primitives, joints)
            add_armwear(groups,joints)
            add_panels(groups,joints)
        else:
            add_hair(groups,joints)
        mesh["primitives"].extend(surface(doc,buffer,vertices,colors[key] if isinstance(key,str) else key)
                                  for key,vertices in groups.items() if vertices)
    doc["extensions"]["VRM"]["meta"]["title"] = "Lumen - ReflexCompanion Lunar Temptation"
    buffer.extend(b"\0"*(-len(buffer)%4))
    doc["buffers"][0]["byteLength"] = len(buffer)
    tree = json.dumps(doc,separators=(",",":")).encode()
    tree += b" "*(-len(tree)%4)
    return b"".join((struct.pack("<4sII",b"glTF",2,28+len(tree)+len(buffer)),
        struct.pack("<I4s",len(tree),b"JSON"),tree,struct.pack("<I4s",len(buffer),b"BIN\0"),buffer))


if __name__ == "__main__":
    parser = ArgumentParser(description=__doc__)
    parser.add_argument("source",type=Path)
    parser.add_argument("output",type=Path)
    parser.add_argument("--stockings",action="store_true")
    args = parser.parse_args()
    export = build(args.source.read_bytes(),args.stockings)
    with args.output.open("xb") as output:
        output.write(export)
