"""Create a private Velvet Enchantress VRM from its matching Lunar legwear variant."""
import argparse
from collections import defaultdict
import json
from math import cos, pi, sin
from pathlib import Path
import struct

import numpy as np

from build_companion_nocturne import decode_glb, surface, triangle
from build_companion_lunar import rings_to_mesh


def overskirt(groups, hips, joints):
    for side, label in ((-1, "L"), (1, "R")):
        side_panel = joints.index(f"J_Sec_{label}_SkirtSide1")
        train = joints.index(f"J_Sec_{label}_SkirtBack1")
        rows = []
        for j in range(19):
            t = j / 18
            row = []
            for i in range(33):
                u = i / 32
                angle = .87 + (2.17-.33*t)*u+.33*t
                pleat = 1 + (.02+.07*t)*cos(8*pi*u + .7*t)
                drop = (.28 + .36*sin(pi*u)**.8 + .025*cos(8*pi*u))*t
                x = side*sin(angle)*(.135+.147*t)*pleat
                z = -cos(angle)*(.108+.104*t)*pleat + .11*t
                normal = (side*sin(angle),.16,-cos(angle))
                follow = min(.96,1.6*t)
                back = u*u
                row.append((np.array((x,1.11-drop,z)),normal,(u,t),(hips,side_panel,train,0),
                            (1-follow,follow*(1-back),follow*back,0)))
            rows.append(row if side>0 else row[::-1])
        rings_to_mesh(groups,rows,lambda j,i: "embroidery" if j in [15,17] or i in [0,31]
                      else "silk fold" if i%8 in [0,1,2] else "velvet")


def butterfly(groups, joint, center, width):
    origin = np.array(center)
    for side in (-1,1):
        rim = [(0,0),(.34,.50),(.96,.68),(.86,.25),(.54,.02),(.80,-.19),(.47,-.50),(.13,-.30)]
        ridge = origin + np.array((side*.29,-.17,.06))*width
        for i,(x,y) in enumerate(rim):
            xx,yy = rim[(i+1)%len(rim)]
            def tip(a,b):
                return origin + width*np.array((side*a,b,-.32*a))
            triangle(groups,"embroidery" if i%3==0 else "silk fold",
                     (ridge,tip(x,y),tip(xx,yy)),joint)


def rosette(groups, joint, center, radius):
    center=np.asarray(center)
    for petal in range(5):
        angle=2*pi*petal/5
        axis=np.array((cos(angle),sin(angle),0))*radius
        across=np.array((-sin(angle),cos(angle),0))*radius*.34
        tip=center+axis+(0,0,-.003)
        left=center+.66*axis+across
        right=center+.66*axis-across
        triangle(groups,"embroidery",(center,left,tip),joint)
        triangle(groups,"silk fold",(center,tip,right),joint)


def build(source):
    doc,binary = decode_glb(source)
    meta = doc["extensions"]["VRM"]["meta"]
    if meta["title"]!="Lumen - ReflexCompanion Lunar Temptation":
        raise ValueError("Expected a Lunar Temptation VRM")
    meta["title"]="Lumen - ReflexCompanion Velvet Enchantress"
    buffer=bytearray(binary)
    materials={}
    for name,color in {"velvet":(.17,.054,.235),"silk fold":(.29,.115,.37),
                       "embroidery":(.68,.39,.70)}.items():
        materials[name]=len(doc["materials"])
        doc["materials"].append({"name":"Velvet "+name,"doubleSided":True,"pbrMetallicRoughness":{
            "baseColorFactor":[*color,1],"metallicFactor":.12,"roughnessFactor":.72}})
    for mat in doc["materials"]:
        color={"Lunar silk":(.15,.063,.19),"Lunar seam":(.53,.27,.54),
               "Lunar panel":(.22,.10,.28),"Lunar pearlescent hair":(.74,.59,.81)}.get(mat["name"])
        if color:
            mat["pbrMetallicRoughness"]["baseColorFactor"]=[*color,1]
    for name in ("Body","Hair001"):
        node=next(n for n in doc["nodes"] if n.get("name")==name)
        joints=[doc["nodes"][i]["name"] for i in doc["skins"][node["skin"]]["joints"]]
        groups=defaultdict(list)
        if name=="Body":
            hips=joints.index("J_Bip_C_Hips")
            overskirt(groups,hips,joints)
            butterfly(groups,hips,(0,1.106,-.118),.052)
            for sign,side in [(-1,"L"),(1,"R")]:
                wrist=joints.index("J_Bip_"+side+"_LowerArm")
                rosette(groups,wrist,(sign*.492,1.451,-.061),.021)
            butterfly(groups,joints.index("J_Bip_C_Chest"),(0,1.355,-.128),.048)
        else:
            butterfly(groups,joints.index("J_Bip_C_Head"),(-.112,1.769,-.096),.061)
            rosette(groups,joints.index("J_Bip_C_Head"),(-.116,1.766,-.118),.024)
        primitives=doc["meshes"][node["mesh"]]["primitives"]
        primitives.extend(surface(doc,buffer,vertices,materials[key]) for key,vertices in groups.items())
    buffer.extend(bytes(-len(buffer)%4))
    doc["buffers"][0]["byteLength"]=len(buffer)
    tree=json.dumps(doc,separators=(",",":")).encode()
    tree+=b" "*(-len(tree)%4)
    return struct.pack("<4sIII4s",b"glTF",2,28+len(tree)+len(buffer),len(tree),b"JSON")+tree+struct.pack("<I4s",len(buffer),b"BIN\0")+buffer


if __name__=="__main__":
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source",type=Path)
    parser.add_argument("output",type=Path)
    args=parser.parse_args()
    data=build(args.source.read_bytes())
    with args.output.open("xb") as output:
        output.write(data)
