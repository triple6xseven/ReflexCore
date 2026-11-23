"""Build a Lunar VRM from a private Midnight Nocturne export."""
from argparse import ArgumentParser
from collections import defaultdict
from math import sin, cos, pi
from pathlib import Path
import json
import struct
import numpy as np
from build_companion_nocturne import decode_glb, triangle, surface


def build(source):
    doc, binary = decode_glb(source)
    if doc["extensions"]["VRM"]["meta"]["title"] != "Lumen - ReflexCompanion Midnight Nocturne":
        raise ValueError("Expected Midnight Nocturne")
    buf = bytearray(binary)
    colors = {}
    for name, color in {"pearl": [.67,.52,.79], "lilac": [.43,.29,.58], "silk": [.062,.037,.103], "trim": [.35,.17,.54]}.items():
        colors[name] = len(doc["materials"])
        doc["materials"].append({"name":"Lunar "+name,"doubleSided":True,"pbrMetallicRoughness":{"baseColorFactor":color+[1],"roughnessFactor":.58,"metallicFactor":0}})
    for part in ["Hair001", "Body"]:
        node = next(n for n in doc["nodes"] if n.get("name")==part)
        mesh = doc["meshes"][node["mesh"]]
        joints = [doc["nodes"][i].get("name","") for i in doc["skins"][node["skin"]]["joints"]]
        groups = defaultdict(list)

        def loft(rings, bone, hair=False, open_panel=False):
            count = 12
            rows=[]
            for x,y,z,rx,rz in rings:
                sweep = 1.55*pi if open_panel else 2*pi
                rows.append([(x+rx*sin((i/count-.5)*sweep),y,z+rz*cos((i/count-.5)*sweep)) for i in range(count+1)])
            for k,(a,b) in enumerate(zip(rows,rows[1:])):
                for i in range(count):
                    mat = colors[("pearl" if i%6<4 else "lilac") if hair else ("trim" if k==len(rows)-2 else "silk")]
                    for face in [(a[i],a[i+1],b[i]),(a[i+1],b[i+1],b[i])]:
                        triangle(groups,mat,face,joints.index(bone))
        if part=="Hair001":
            for i in range(9):
                angle=i*2*pi/9
                rings=[]
                for j in range(13):
                    t=j/12
                    width=.012+.037*sin(pi*t)**.7 if j<12 else .002
                    rings.append((.053*cos(angle)+(.052+.057*t)*sin(angle+t*2)+.045*sin(t*5),1.735-.73*t+.025*cos(angle)*t,.085+.11*sin(t*2.5)+.048*cos(angle),width,width*.62))
                loft(rings,"J_Bip_C_Head",True)
            for sign in [-1,1]:
                loft([(sign*(.103+.038*sin(t*pi)),1.65-.39*t,-.048-.057*t,.023*(1-t)+.002,.014*(1-t)+.001) for t in np.linspace(0,1,10)],"J_Bip_C_Head",True)
        else:
            loft([(0,1.12,0,.132,.109),(0,1.04,.005,.175,.138),(0,.91,.02,.214,.157),(0,.897,.021,.218,.159)],"J_Bip_C_Hips",open_panel=True)
            for sign,side in [(-1,"L"),(1,"R")]:
                # VRoid arms extend along the X axis in bind pose.
                rings=[[(sign*x,1.449+rad*cos(i*pi/6),rad*sin(i*pi/6)) for i in range(13)] for x,rad in [(.18,.046),(.22,.052),(.29,.062),(.30,.063)]]
                for k,(a,b) in enumerate(zip(rings,rings[1:])):
                    for i in range(12):
                        for face in [(a[i],b[i],a[i+1]),(a[i+1],b[i],b[i+1])]:
                            triangle(groups,colors["trim" if k==2 else "silk"],face,joints.index("J_Bip_"+side+"_UpperArm"))
        mesh["primitives"].extend(surface(doc,buf,v,m) for m,v in groups.items())
    doc["extensions"]["VRM"]["meta"]["title"]="Lumen - ReflexCompanion Lunar Temptation"
    doc["buffers"][0]["byteLength"]=len(buf)
    tree=json.dumps(doc,separators=(",",":")).encode()
    tree+=b" "*(-len(tree)%4)
    buf.extend(b"\0"*(-len(buf)%4))
    return struct.pack("<4sII",b"glTF",2,28+len(tree)+len(buf))+struct.pack("<I4s",len(tree),b"JSON")+tree+struct.pack("<I4s",len(buf),b"BIN\0")+buf


if __name__=="__main__":
    parser=ArgumentParser(description=__doc__)
    parser.add_argument("source",type=Path)
    parser.add_argument("output",type=Path)
    args=parser.parse_args()
    with args.output.open("xb") as f:
        f.write(build(args.source.read_bytes()))
