"""Tailor a separate Velvet Bloom VRM from a fitted Velvet Enchantress export."""
import argparse
from collections import defaultdict
from io import BytesIO
from math import cos, pi, sin
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

from build_companion_lunar import ring, rings_to_mesh
from build_companion_midnight import accessor, append_accessor
from build_companion_nocturne import decode_glb, surface, triangle
from build_companion_wardrobe import encode


TITLE = "Lumen - ReflexCompanion Velvet Bloom"
FABRICS = {
    "velvet": ((.067, .026, .102), .82, 0.0),
    "chiffon": ((.57, .34, .71), .81, 0.0),
    "piping": ((.21, .080, .32), .63, .05),
    "petal": ((.66, .35, .59), .61, .10),
    "nickel": ((.81, .59, .74), .37, .34),
    "hair": ((.58, .48, .71), .65, .0),
    "hair highlight": ((.78, .65, .85), .53, .0),
}


def lace_map():
    """A repeating floral border on lavender cloth, expressed in the skirt UVs."""
    image = Image.new("RGB", (384, 512), (245, 220, 251))
    draw = ImageDraw.Draw(image)
    for y in range(image.height):
        t = y / (image.height - 1)
        draw.line((0, y, image.width, y),
                  fill=(int(189 + 61*t), int(138 + 76*t), int(213 + 39*t)))
    for y in (22, 38, 447, 488):
        draw.line((0, y, image.width, y), fill=(152, 94, 161), width=3)
    for x in range(-12, image.width+30, 48):
        points = [(x+dx,470+3*sin(dx*pi/24)) for dx in range(49)]
        draw.line(points, fill=(126, 87, 141), width=2)
        for cx,cy,radius in ((x+13,462,6),(x+34,481,4),(x+2,29,4)):
            for petal in range(5):
                angle = petal * 2 * pi / 5
                dx,dy = cos(angle)*radius*.76,sin(angle)*radius*.76
                r = radius*.62
                draw.ellipse((cx+dx-r,cy+dy-r,cx+dx+r,cy+dy+r),fill=(255,229,253))
            draw.ellipse((cx-1.6,cy-1.6,cx+1.6,cy+1.6),fill=(113,62,132))
    buffer = BytesIO()
    image.save(buffer, "PNG", optimize=True)
    return buffer.getvalue()


def add_texture(doc, data, payload):
    data.extend(b"\0" * (-len(data) % 4))
    view = len(doc["bufferViews"])
    doc["bufferViews"].append({"buffer":0, "byteOffset":len(data), "byteLength":len(payload)})
    data.extend(payload)
    index = len(doc["images"])
    doc["images"].append({"name":"Bloom embroidered hem", "bufferView":view, "mimeType":"image/png"})
    doc["textures"].append({"source":index})
    return len(doc["textures"])-1


def drape_position(sign, u, t, tier):
    angle = .89 + (2.19-.29*t)*u+.29*t
    fold = 1.0 + .077*sin(6*pi*u+1.15*t)*(t+.35)
    asymmetric = 1.0 if sign < 0 else .92
    if tier == 0:
        length = (.29+.35*max(0,sin(pi*u))**.9+.034*cos(6*pi*u))*asymmetric
        radius_x = .151+.142*t
        radius_z = .105+.099*t
    else:
        length = (.090+.135*max(0,sin(pi*u))**.67+.025*cos(9*pi*u))*asymmetric
        radius_x = .155+.093*t
        radius_z = .110+.058*t
    return np.array((sign * sin(angle)*radius_x*fold,
                     1.106-length*t-.013*t*sin(9*pi*u),
                     -cos(angle)*radius_z*fold+(.113 if tier == 0 else .076)*t))


def layered_drapes(groups, joints):
    hips = joints.index("J_Bip_C_Hips")
    for sign, side in ((-1,"L"),(1,"R")):
        side_panel = joints.index(f"J_Sec_{side}_SkirtSide1")
        train = joints.index(f"J_Sec_{side}_SkirtBack1")
        for tier, rings, sides in ((0,18,40),(1,9,38)):
            rows = []
            for row in range(rings+1):
                t = row/rings
                vertices = []
                for i in range(sides+1):
                    u = i/sides
                    p = drape_position(sign,u,t,tier)
                    du = drape_position(sign,u+.0005,t,tier)-drape_position(sign,u-.0005,t,tier)
                    dt = drape_position(sign,u,t+.0005,tier)-drape_position(sign,u,t-.0005,tier)
                    normal = np.cross(dt,du)*sign
                    normal /= np.linalg.norm(normal)
                    # Let the panels hang from the waist when the legs lift.
                    follow = min(.96,1.6*t)
                    back = u*u
                    vertices.append((p,normal,(u,t),(hips,side_panel,train,0),
                                     (1-follow,follow*(1-back),follow*back,0)))
                rows.append(vertices if sign>0 else list(reversed(vertices)))
            rings_to_mesh(groups,rows, lambda row,edge:
                          "piping" if edge in (0,sides-1) or row==rings-1
                          else "chiffon" if tier==0 or row>=rings-3 else "velvet")


def bow(groups, joint, center, size):
    center = np.array(center)
    for sign in (-1,1):
        a,b,c,d,e = [center + size*np.array((sign*x,y,z)) for x,y,z in
                     ((0,0,0),(.66,.36,-.03),(1.0,.22,-.12),(.85,-.41,-.09),(.67,-.05,-.27))]
        triangle(groups,"velvet",(a,b,e),joint)
        triangle(groups,"chiffon",(b,c,e),joint)
        triangle(groups,"piping",(c,d,e),joint)
        triangle(groups,"velvet",(d,a,e),joint)
        tail = [center + size*np.array((sign*x,y,z)) for x,y,z in
                ((.08,-.09,0),(.33,-.15,-.06),(.57,-1.34,.16),(.38,-1.21,.17),(.21,-1.34,.15))]
        triangle(groups,"velvet",(tail[0],tail[1],tail[3]),joint)
        triangle(groups,"piping",(tail[1],tail[2],tail[3]),joint)
        triangle(groups,"chiffon",(tail[0],tail[3],tail[4]),joint)
    r = size*.20
    gem = center + (0,0,-r*.55)
    outline = [center + (0,r,0), center + (r,0,0), center + (0,-r,0), center + (-r,0,0)]
    for i in range(4):
        triangle(groups,"nickel" if i%2 else "petal",(gem,outline[i],outline[(i+1)%4]),joint)


def rosette(groups, joint, center, radius):
    center = np.asarray(center)
    core = center + (0,0,-radius*.28)
    for index in range(5):
        angle = index * 2 * pi / 5
        axis = np.array((cos(angle),sin(angle),0))*radius
        width = np.array((-sin(angle),cos(angle),0))*radius
        near = center + axis*.13
        ridge = center + axis*.62 + (0,0,-radius*.24)
        left = center + axis*.60 + width*.34
        right = center + axis*.60 - width*.34
        tip = center + axis
        for fabric,a,b in (("chiffon",near,left),("petal",left,tip),("chiffon",tip,right),("petal",right,near)):
            triangle(groups,fabric,(ridge,a,b),joint)
        triangle(groups,"nickel",(core,near,center+.14*axis+.14*width),joint)


def sleeves(groups, joints):
    # Garment rings follow the upper-arm, elbow and wrist axes in bind pose.
    # The ruffle sits over the gathered cuff and stays weighted to the wrist.
    profile = (
        (.208,.038),(.217,.041),(.229,.039),(.254,.039),
        (.288,.040),(.324,.042),(.354,.045),(.382,.053),
        (.425,.057),(.457,.050),(.474,.042),(.483,.036),
        (.493,.037),(.507,.041),(.519,.043),(.528,.040),(.535,.034),
    )
    for sign, side in ((-1,"L"),(1,"R")):
        upper = joints.index(f"J_Bip_{side}_UpperArm")
        lower = joints.index(f"J_Bip_{side}_LowerArm")
        rows = []
        for axial,radius in profile:
            local = (axial-.208)/.327
            center_y = 1.455-.010*local
            center_z = .002-.018*local
            blend = float(np.clip((axial-.280)/.089,0,1))
            blend = blend*blend*(3-2*blend)
            row = []
            for i in range(25):
                u = i/24
                angle = u*2*pi
                flare = max(0,(axial-.489)/.046)
                pleat = 1 + (.055+.11*flare)*cos(8*angle+local)
                axial_hem = axial + .009*flare*cos(8*angle)
                normal = (0,cos(angle),sin(angle))
                pos = (sign*axial_hem,center_y+normal[1]*radius*pleat,center_z+normal[2]*radius*.92*pleat)
                row.append((np.array(pos),normal,(u,local),(upper,lower,0,0),(1-blend,blend,0,0)))
            rows.append(row if sign>0 else list(reversed(row)))
        rings_to_mesh(groups,rows,lambda row,edge:
                      "chiffon" if row in (12,13,14)
                      else "piping" if row in (0,2,11,15)
                      else "velvet")


def keep_legacy_trim(doc, binary, data, primitives):
    fabrics = {"Lunar cuff","Lunar seam","Lunar silk","Lunar panel"}
    for primitive in primitives:
        if doc["materials"][primitive["material"]]["name"] not in fabrics:
            yield primitive
            continue
        attributes = primitive["attributes"]
        coords = accessor(doc,binary,attributes["POSITION"])
        # These fitted surfaces are already triangulated. Keep their draped hip
        # and corset portions while removing the old sleeves from the arm rings.
        points = coords.reshape((-1,3,3))
        arm = (np.abs(points[:,:,0])>.20).all(axis=1) & (points[:,:,1]>1.37).all(axis=1)
        if not arm.any():
            yield primitive
            continue
        selection = np.repeat(~arm,3)
        if selection.any():
            cropped = {}
            for name,index in attributes.items():
                values = accessor(doc,binary,index)
                layout = doc["accessors"][index]
                cropped[name] = append_accessor(doc,data,values[selection],layout["type"],layout["componentType"])
            yield {**primitive,"attributes":cropped}


def add_accessories(groups, joints, node):
    if node == "Body":
        hips = joints.index("J_Bip_C_Hips")
        chest = joints.index("J_Bip_C_Chest")
        bow(groups,chest,(0,1.30,-.138),.049)
        bow(groups,hips,(0,1.102,-.118),.055)
        for sign, side in ((-1,"L"),(1,"R")):
            arm = joints.index(f"J_Bip_{side}_LowerArm")
            rosette(groups,arm,(sign*.507,1.458,-.060),.019)
            bow(groups,hips,(sign*.135,1.10,-.060),.038)
    else:
        head = joints.index("J_Bip_C_Head")
        for center, size in (((-.108,1.761,-.103),.043),((.125,1.744,-.085),.036)):
            bow(groups,head,center,size)
            c = np.array(center)+(0,-.006,-.009)
            rosette(groups,head,c,size*.42)
            rosette(groups,head,c+(-.015,.009,.002),size*.25)


def curled_locks(groups, joints):
    head = joints.index("J_Bip_C_Head")
    for side, sign, root in (("L",-1,"HairJoint-b85bb5b7"),("R",1,"HairJoint-c6b7b433")):
        spring = next((i for i,name in enumerate(joints) if name.startswith(root)),head)
        for strand in range(4):
            rows = []
            for t in np.linspace(0,1,25):
                spread = .098 + (.046+.025*strand)*sin(t*pi*.82) + .037*t*sin(t*9.2+strand*.35)
                y = 1.754-.006*strand-(.65+.033*strand)*t + .016*sin(2*pi*t+strand)*t
                z = .050+.010*strand + .139*t + .056*sin(t*pi*2.35+strand*.66)*t
                width = .002+.019*sin(pi*t)**.72
                blend = min(.82,t*1.25)
                rows.append(ring((sign*spread,y,z),((1,0,0),(0,0,-1)),
                                 (width,width*.53),(head,spring,0,0),(1-blend,blend,0,0),10))
            rings_to_mesh(groups,rows,lambda row,edge:
                          "hair highlight" if edge in (1,2,7) else "hair")


def retint_base(doc):
    colors = {
        "Nocturne satin": (.075,.034,.105),
        "Corset panel": (.117,.048,.155),
        "Graphite belt": (.080,.025,.104),
        "Lunar silk": (.095,.034,.125),
        "Lunar seam": (.38,.175,.44),
        "Lunar panel": (.19,.075,.255),
        "Lunar cuff": (.147,.039,.19),
        "Lunar stocking welt": (.147,.039,.19),
        "Lunar pearlescent hair": (.68,.55,.80),
        "Lunar lilac hair": (.48,.35,.64),
    }
    for material in doc["materials"]:
        color = colors.get(material["name"])
        if color is not None:
            material["pbrMetallicRoughness"]["baseColorFactor"] = [*color,1]


def batch_hair(doc, source, data, primitives):
    groups = defaultdict(list)
    for primitive in primitives:
        groups[primitive["material"]].append(primitive)
    for material, sources in groups.items():
        fields = sources[0]["attributes"]
        if any(set(p["attributes"])!=set(fields) or p.get("targets") or p.get("mode",4)!=4 for p in sources):
            raise ValueError("Unexpected hair vertex layout")
        rows = {name: [] for name in fields}
        indices = []
        offset = 0
        for primitive in sources:
            columns = {name: accessor(doc,source,index) for name,index in primitive["attributes"].items()}
            selected = (accessor(doc,source,primitive["indices"]).ravel()
                        if "indices" in primitive else np.arange(len(columns["POSITION"])))
            used, mapped = np.unique(selected,return_inverse=True)
            indices.append(mapped+offset)
            offset += len(used)
            for name in fields:
                rows[name].append(columns[name][used])
        attributes = {}
        for name, chunks in rows.items():
            layout = doc["accessors"][fields[name]]
            attributes[name]=append_accessor(doc,data,np.concatenate(chunks),layout["type"],layout["componentType"])
        yield {"mode":4,"material":material,"attributes":attributes,
               "indices":append_accessor(doc,data,np.concatenate(indices)[:,None],"SCALAR",5125)}


def build(source):
    doc, binary = decode_glb(source)
    meta = doc["extensions"]["VRM"]["meta"]
    if meta["title"] != "Lumen - ReflexCompanion Velvet Enchantress":
        raise ValueError("Expected a Velvet Enchantress VRM. Select the corresponding legwear source.")
    meta["title"] = TITLE
    data = bytearray(binary)
    embroidery = add_texture(doc,data,lace_map())
    materials = {}
    for key,(color,roughness,metallic) in FABRICS.items():
        pbr = {"baseColorFactor":[*color,1],"roughnessFactor":roughness,"metallicFactor":metallic}
        if key == "chiffon":
            pbr["baseColorTexture"] = {"index":embroidery}
        materials[key] = len(doc["materials"])
        doc["materials"].append({"name":f"Bloom {key}","doubleSided":True,"pbrMetallicRoughness":pbr})
    retint_base(doc)
    for name in ("Body","Hair001"):
        node = next(n for n in doc["nodes"] if n.get("name")==name)
        joints = [doc["nodes"][i]["name"] for i in doc["skins"][node["skin"]]["joints"]]
        groups = defaultdict(list)
        add_accessories(groups,joints,name)
        if name == "Body":
            layered_drapes(groups,joints)
            sleeves(groups,joints)
        else:
            curled_locks(groups,joints)
        mesh = doc["meshes"][node["mesh"]]
        mesh["primitives"] = [p for p in mesh["primitives"]
                              if not doc["materials"][p["material"]]["name"].startswith("Velvet ")]
        if name == "Hair001":
            mesh["primitives"] = list(batch_hair(doc,binary,data,mesh["primitives"]))
        else:
            mesh["primitives"] = list(keep_legacy_trim(doc,binary,data,mesh["primitives"]))
        mesh["primitives"].extend(surface(doc,data,vertices,materials[key]) for key,vertices in groups.items())
    return encode(doc,data)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source",type=Path)
    parser.add_argument("output",type=Path)
    args = parser.parse_args()
    generated = build(args.source.read_bytes())
    with args.output.open("xb") as file:
        file.write(generated)
