#!/usr/bin/env python3
"""Tailor Midnight Nocturne from the verified Refined assets."""
from argparse import ArgumentParser
from collections import defaultdict
from hashlib import sha256
from pathlib import Path
import json
import struct

import numpy as np

from build_companion_avatar import decode_glb
from build_companion_midnight import accessor, append_accessor, split

SOURCES = {
    "95cb4c09a50125c084cf7925fff4548d4c41c1e34e307d1fc69a277cef0d6bc6",
    "6c7b981b3cfb7c26c8f1754cd78196b7689b9a5ce3f4ce40369b960f75b729f9",
}
FIELDS = ("POSITION","NORMAL","TEXCOORD_0","JOINTS_0","WEIGHTS_0")
SHAPES = ("VEC3","VEC3","VEC2","VEC4","VEC4")
COMPONENTS = (5126,5126,5126,5123,5126)
PALETTE = {
    "Nocturne ear silver": [.46,.42,.63,1],
    "Nocturne ear lining": [.45,.23,.40,1],
    "Nocturne ear rim": [.65,.57,.80,1],
    "Nocturne piping": [.23,.12,.43,1],
    "Nocturne satin": [.029,.021,.051,1],
    "Nocturne strap": [.065,.052,.10,1],
    "Nocturne nickel": [.43,.44,.60,1],
}


def add_material(doc,name):
    material={"name":name,"doubleSided":True,"pbrMetallicRoughness":{
        "baseColorFactor": PALETTE[name], "roughnessFactor":.65,
    }}
    doc["materials"].append(material)
    return len(doc["materials"])-1


def surface(doc,buffer,vertices,material):
    attributes={field:append_accessor(doc,buffer,column,shape,component)
        for field,column,shape,component in zip(FIELDS,zip(*vertices),SHAPES,COMPONENTS)}
    return {"mode":4,"material":material,"attributes":attributes}


def collect(groups,material,polygon):
    for i in range(1,len(polygon)-1):
        a,b,c=polygon[0],polygon[i],polygon[i+1]
        if np.linalg.norm(np.cross(b[0]-a[0],c[0]-a[0]))>1e-9:
            groups[material].extend((a,b,c))


def hem_and_panels(doc,source,buffer,body,materials):
    groups=defaultdict(list)
    untouched=[]
    skin=next(i for i,m in enumerate(doc["materials"]) if "_Body_00_SKIN" in m["name"])
    for primitive in body["primitives"]:
        material=primitive["material"]
        name=doc["materials"][material]["name"]
        if "indices" in primitive or name not in {
            "Violet piping","Tailored shorts","Shorts side panel","Harness piping","Fitted top",
        }:
            untouched.append(primitive)
            continue
        columns=[accessor(doc,source,primitive["attributes"][field]) for field in FIELDS]
        for offset in range(0,len(columns[0]),3):
            polygon=[tuple(col[i] for col in columns) for i in range(offset,offset+3)]
            if name=="Fitted top":
                bottom,top=split(polygon,lambda p:1.29-p[1])
                inner,outer=split(bottom,lambda p:.13-abs(p[0]+p[2]*.16))
                collect(groups,materials["Nocturne satin"],inner)
                collect(groups,material,outer)
                collect(groups,material,top)
                continue
            upper,lower=split(polygon,lambda p:p[1]-.933)
            trim,leg=split(lower,lambda p:p[1]-.919)
            strap,rest=split(leg,lambda p:p[1]-.898)
            strap,skin_low=split(strap,lambda p:p[0]-.025)
            collect(groups,material,upper)
            collect(groups,materials["Nocturne piping"],trim)
            collect(groups,materials["Nocturne strap"],strap)
            collect(groups,skin,rest)
            collect(groups,skin,skin_low)
    body["primitives"]=untouched+[surface(doc,buffer,rows,material) for material,rows in groups.items() if rows]


def triangle(groups,material,coords,joint):
    a,b,c=(np.array(p) for p in coords)
    normal=np.cross(b-a,c-a)
    normal/=max(np.linalg.norm(normal),1e-9)
    groups[material].extend((v,normal,(0,0),(joint,0,0,0),(1,0,0,0)) for v in (a,b,c))


def form_ears_and_hair(doc,source,buffer,hair,materials):
    hair_node=next(node for node in doc["nodes"] if node.get("name")=="Hair001")
    joints=doc["skins"][hair_node["skin"]]["joints"]
    head=next(i for i,node in enumerate(doc["nodes"]) if node.get("name")=="J_Bip_C_Head")
    parts=defaultdict(list)
    # Faceted tapered ear shells are separate head-weighted geometry.
    for side in (-1,1):
        points=np.array([
            (.036,1.766,-.047), (.157,1.756,-.022), (.165,1.794,-.010),
            (.145,1.885,.006), (.093,1.849,-.025), (.112,1.807,-.061), (.122,1.802,.016)
        ])
        points[:,0]*=side
        outer=materials["Nocturne ear silver"]
        rim=materials["Nocturne ear rim"]
        for i in range(5):
            j=(i+1)%5
            triangle(parts,rim if i in (2,3) else outer,(points[i],points[j],points[5]),joints.index(head))
            triangle(parts,outer,(points[j],points[i],points[6]),joints.index(head))
        liner=points[[0,1,3]]*.74+points[5]*.26
        liner[:,2]-=.021
        ridge=liner.mean(axis=0)+[0,0,-.012]
        for i in range(3):
            triangle(parts,materials["Nocturne ear lining"],(liner[i],liner[(i+1)%3],ridge),joints.index(head))

    transformed={}
    for primitive in hair["primitives"]:
        attributes=primitive["attributes"]
        index=attributes["POSITION"]
        if index not in transformed:
            points=accessor(doc,source,index).copy()
            x,y,z=points.T.copy()
            fall=np.clip((z-.085)/.12,0,1)*np.clip((1.65-y)/.39,0,1)
            points[:,1]-=.108*fall
            points[:,0]+=fall*(.022+.025*np.sin(y*9))
            points[:,2]+=.026*fall
            transformed[index]=append_accessor(doc,buffer,points,"VEC3",5126)
        attributes["POSITION"]=transformed[index]
    hair["primitives"].extend(surface(doc,buffer,rows,material) for material,rows in parts.items())


def add_belt_hardware(doc,source,buffer,body,materials):
    node=next(node for node in doc["nodes"] if node.get("name")=="Body")
    joints=doc["skins"][node["skin"]]["joints"]
    hips=next(i for i,item in enumerate(doc["nodes"]) if item.get("name")=="J_Bip_C_Hips")
    groups=defaultdict(list)
    # Two slender chamfered loops over the graphite waist belt.
    for x in (-.046,.058):
        for y in (1.106,1.132):
            a,b,c,d=[(x+dx,y+dy,-.112+.65*abs(x)*abs(dx)) for dx,dy in
                     ((-.011,-.003),(.011,-.003),(.011,.003),(-.011,.003))]
            triangle(groups,materials["Nocturne nickel"],(a,c,b),joints.index(hips))
            triangle(groups,materials["Nocturne nickel"],(a,d,c),joints.index(hips))
        for dx in (-.011,.011):
            a,b,c,d=[(x+dx+sx,y,-.111) for sx,y in
                     ((-.003,1.106),(.003,1.106),(.003,1.132),(-.003,1.132))]
            triangle(groups,materials["Nocturne nickel"],(a,c,b),joints.index(hips))
            triangle(groups,materials["Nocturne nickel"],(a,d,c),joints.index(hips))
    body["primitives"].extend(surface(doc,buffer,rows,material) for material,rows in groups.items())


def build(data):
    if sha256(data).hexdigest() not in SOURCES:
        raise ValueError("Expected a verified Midnight Atelier Refined export.")
    doc,source=decode_glb(data)
    buffer=bytearray(source)
    materials={name:add_material(doc,name) for name in PALETTE}
    body=next(mesh for mesh in doc["meshes"] if mesh["name"]=="Body.baked")
    hair=next(mesh for mesh in doc["meshes"] if mesh["name"]=="Hair001.baked")
    hem_and_panels(doc,source,buffer,body,materials)
    form_ears_and_hair(doc,source,buffer,hair,materials)
    add_belt_hardware(doc,source,buffer,body,materials)
    doc["extensions"]["VRM"]["meta"]["title"]="Lumen - ReflexCompanion Midnight Nocturne"
    doc["buffers"][0]["byteLength"]=len(buffer)
    tree=json.dumps(doc,separators=(",",":"),ensure_ascii=True).encode()
    tree+=b" "*(-len(tree)%4)
    buffer.extend(b"\0"*(-len(buffer)%4))
    return b"".join((struct.pack("<4sII",b"glTF",2,28+len(tree)+len(buffer)),
        struct.pack("<I4s",len(tree),b"JSON"),tree,
        struct.pack("<I4s",len(buffer),b"BIN\0"),buffer))


if __name__=="__main__":
    parser=ArgumentParser(description=__doc__)
    parser.add_argument("source",type=Path)
    parser.add_argument("output",type=Path)
    args=parser.parse_args()
    export=build(args.source.read_bytes())
    with args.output.open("xb") as output:
        output.write(export)
    print(f"Nocturne VRM SHA-256 {sha256(export).hexdigest()}")
