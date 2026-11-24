#!/usr/bin/env python3
"""Refine the verified Atelier VRMs without changing their skin weights."""
from argparse import ArgumentParser
from hashlib import sha256
from io import BytesIO
from pathlib import Path
import json
import struct

import numpy as np
from PIL import Image

from build_companion_avatar import decode_glb
from build_companion_midnight import accessor, append_accessor


SOURCES = {
    "e7d9af829c3ad2cc6f8f7ae3c2260fc30c2dfa0ba90947192d4c2ab97038d3a6",
    "32013733e3ea4d3f337535fbe1c52fd828af0ca77e8360346c3dedc1db04e1d3",
}


def lift(y):
    # Flat offset above the shoulders preserves the head and facial morphs.
    return np.interp(y, [.15,.43,.59,.97,1.14,1.31], [0,.015,.032,.067,.075,.080])


def reshape_skeleton(doc, source, buffer):
    nodes = doc["nodes"]
    world_y = {}
    offsets = {}
    parents = {child:i for i,node in enumerate(nodes) for child in node.get("children", [])}
    for i,node in enumerate(nodes):
        if ("matrix" in node or node.get("rotation",[0,0,0,1])!=[0,0,0,1]
                or node.get("scale",[1,1,1])!=[1,1,1]):
            raise ValueError("Expected the Atelier translation-only rest skeleton.")
        parent = parents.get(i)
        if parent is not None and parent not in world_y:
            raise ValueError("Expected parent-first bone order.")
        local = list(node.get("translation", [0,0,0]))
        world_y[i] = world_y.get(parent,0)+local[1]
        offsets[i] = float(lift(world_y[i]))
        local[1] += offsets[i]-offsets.get(parent,0)
        node["translation"] = local

    for skin in doc["skins"]:
        old = doc["accessors"][skin["inverseBindMatrices"]]
        view = doc["bufferViews"][old["bufferView"]]
        start = view.get("byteOffset",0)+old.get("byteOffset",0)
        matrices = np.frombuffer(source,dtype="<f4",count=old["count"]*16,offset=start).reshape(-1,16).copy()
        # Matrices are column-major. Apply inverse world-space bone displacement.
        displacement = np.array([offsets[j] for j in skin["joints"]])
        matrices[:,12:15] -= matrices[:,4:7]*displacement[:,None]
        skin["inverseBindMatrices"] = append_accessor(doc,buffer,matrices,"MAT4",5126)


def reshape_surfaces(doc, source, buffer):
    for mesh in doc["meshes"]:
        transformed = {}
        normals = {}
        hair = mesh["name"] == "Hair001.baked"
        for primitive in mesh["primitives"]:
            attributes = primitive["attributes"]
            pos_id, normal_id = attributes["POSITION"], attributes["NORMAL"]
            points = accessor(doc,source,pos_id)
            y = points[:,1]
            if pos_id not in transformed:
                changes = points.copy()
                changes[:,1] += lift(y)
                if mesh["name"] == "Body.baked":
                    waist = np.exp(-((y-1.109)/.095)**2)
                    changes[:,0] *= 1-.041*waist
                if hair:
                    x,z = points[:,0],points[:,2]
                    tail = np.clip((z-.08)/.115,0,1)*np.clip((1.61-y)/.30,0,1)
                    fringe = np.clip((-z-.067)/.035,0,1)*np.exp(-((y-1.62)/.072)**2)
                    changes[:,0] += .031*tail + .011*fringe
                    changes[:,1] -= .058*tail + .012*fringe*np.sin(x*43)
                    changes[:,2] += .014*tail
                transformed[pos_id] = append_accessor(doc,buffer,changes,"VEC3",5126)
            key = (pos_id,normal_id)
            if key not in normals:
                normal = accessor(doc,source,normal_id).copy()
                slope = 1+(lift(y+.002)-lift(y-.002))/.004
                normal[:,1] /= slope
                normal /= np.maximum(np.linalg.norm(normal,axis=1,keepdims=True),1e-8)
                normals[key] = append_accessor(doc,buffer,normal,"VEC3",5126)
            attributes["POSITION"] = transformed[pos_id]
            attributes["NORMAL"] = normals[key]


def finish_textures(doc,source,buffer):
    for index in (5,7,9,10,11,19,22,25,26):
        image=doc["images"][index]
        view=doc["bufferViews"][image["bufferView"]]
        offset=view["byteOffset"]
        with Image.open(BytesIO(source[offset:offset+view["byteLength"]])) as loaded:
            rgba=np.asarray(loaded.convert("RGBA")).copy()
        rgb=rgba[:,:,:3].astype(float)
        h,w=rgb.shape[:2]
        y,x=np.mgrid[0:h,0:w].astype(float)
        x/=w
        y/=h
        if index in (5,7):
            rgb=rgb*.84+[6,3,9]
        elif index==9:
            sparkle=np.exp(-((y-.64)/.13)**2)
            rgb+=sparkle[...,None]*[2,7,11]
        elif index==10:
            rgb=rgb*.93+[15,12,11]
        elif index==11:
            blush=np.exp(-((x-.29)/.091)**2-((y-.642)/.038)**2)
            blush+=np.exp(-((x-.71)/.091)**2-((y-.642)/.038)**2)
            mouth=np.exp(-((x-.50)/.075)**2-((y-.755)/.04)**2)
            rgb+=blush[...,None]*[-1,5,7]+mouth[...,None]*[-1,-3,0]
        else:
            shade=8*np.exp(-((y-.32-.036*np.sin(x*14))/.24)**2)-5*y
            rgb+=shade[...,None]*[.72,.9,1]+[2,2,-4]
        rgba[:,:,:3]=np.clip(rgb,0,255).astype(np.uint8)
        png=BytesIO()
        Image.fromarray(rgba).save(png,format="PNG",optimize=True)
        buffer.extend(b"\0"*(-len(buffer)%4))
        image["bufferView"]=len(doc["bufferViews"])
        image["mimeType"]="image/png"
        doc["bufferViews"].append({"buffer":0,"byteOffset":len(buffer),"byteLength":png.tell()})
        buffer.extend(png.getvalue())


def build(data):
    if sha256(data).hexdigest() not in SOURCES:
        raise ValueError("Use the preserved, verified Midnight Atelier VRMs.")
    doc,source=decode_glb(data)
    buffer=bytearray(source)
    reshape_skeleton(doc,source,buffer)
    reshape_surfaces(doc,source,buffer)
    finish_textures(doc,source,buffer)
    # Shift garment accents toward cooler violet.
    accents = {"Harness piping":[.145,.076,.280,1],"Woven harness":[.077,.059,.142,1],
               "Shorts side panel":[.035,.028,.068,1],"Amethyst inset":[.29,.113,.50,1]}
    for material in doc["materials"]:
        if material["name"] in accents:
            material["pbrMetallicRoughness"]["baseColorFactor"] = accents[material["name"]]
    doc["extensions"]["VRM"]["meta"]["title"]="Lumen - ReflexCompanion Midnight Atelier Refined"
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
    options=parser.parse_args()
    model=build(options.source.read_bytes())
    with options.output.open("xb") as output:
        output.write(model)
    print(f"Refined VRM SHA-256 {sha256(model).hexdigest()}")
