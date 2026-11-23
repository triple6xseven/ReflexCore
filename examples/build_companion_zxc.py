"""Build ZXC locally from its 1024x1536 A-pose illustration and a VRM skeleton.

Each profile row is (image y, horizontal center, half-width, depth in metres).
Only skeleton nodes, humanoid mapping and inverse bind data come from the rig.
"""
import argparse
from copy import deepcopy
from io import BytesIO
import json
from math import sin, cos, pi, exp
from pathlib import Path
import struct

import numpy as np
from PIL import Image
from build_companion_avatar import decode_glb
from build_companion_midnight import append_accessor


def build(source, illustration, back, stockings):
    template, raw = decode_glb(source)
    body = next(n for n in template["nodes"] if n.get("name")=="Body")
    skin = deepcopy(template["skins"][body["skin"]])
    nodes = deepcopy(template["nodes"])
    for node in nodes:
        for key in ("skin","mesh","weights"):
            node.pop(key,None)
    nodes[nodes.index(next(n for n in nodes if n.get("name")=="Body"))].update(mesh=0,skin=0)
    vrm = deepcopy(template["extensions"]["VRM"])
    vrm.pop("materialProperties",None)
    vrm.pop("firstPerson",None)
    vrm["blendShapeMaster"]={"blendShapeGroups":[]}
    vrm["meta"].update(title="ZXC",texture=-1)
    doc=dict(asset={"version":"2.0","generator":"ReflexCore ZXC"},nodes=nodes,skins=[skin],
             scenes=template["scenes"],scene=0,meshes=[],materials=[],images=[],textures=[],
             accessors=[],bufferViews=[],extensionsUsed=["VRM"],extensions={"VRM":vrm})
    data=bytearray()
    def view(payload):
        data.extend(bytes(-len(data)%4))
        doc["bufferViews"].append({"buffer":0,"byteOffset":len(data),"byteLength":len(payload)})
        data.extend(payload)
        return len(doc["bufferViews"])-1
    bind=deepcopy(template["accessors"][skin["inverseBindMatrices"]])
    old=template["bufferViews"][bind["bufferView"]]
    offset=old.get("byteOffset",0)
    bind["bufferView"]=view(raw[offset:offset+old["byteLength"]])
    doc["accessors"].append(bind)
    skin["inverseBindMatrices"]=0
    names=[nodes[n]["name"] for n in skin["joints"]]
    im=Image.open(illustration).convert("RGB")
    if im.size!=(1024,1536):
        raise ValueError("Use the ZXC front reference in its original resolution")
    rear=Image.open(back).convert("RGB")
    if rear.size!=im.size:
        raise ValueError("Front and back illustrations must be aligned")
    atlas=Image.new("RGB",(2048,1536))
    atlas.paste(im,(0,0))
    atlas.paste(rear,(1024,0))
    im=atlas
    if stockings:
        rgb=np.asarray(im).copy()
        for y in range(805,1510):
            # Only the leg surfaces sample this area below the cuff.
            for base in (0,1024):
                strip=rgb[y,base+375:base+661]
                strip[:]=(strip*[.37,.27,.42]).astype(np.uint8)
        im=Image.fromarray(rgb)
    stream=BytesIO()
    im.save(stream,"JPEG",quality=96,subsampling=0)
    doc["images"].append({"bufferView":view(stream.getvalue()),"mimeType":"image/jpeg"})
    doc["textures"].append({"source":0})
    doc["materials"].append({"name":"ZXC painted satin","doubleSided":True,
        "pbrMetallicRoughness":{"baseColorTexture":{"index":0},"metallicFactor":0,"roughnessFactor":.9}})
    pieces=[]
    def joint(name):
        return names.index("J_Bip_"+name)
    def influences(y, chain):
        heights,roles=zip(*chain)
        high=min(max(1,np.searchsorted(heights,y)),len(roles)-1)
        t=np.clip((y-heights[high-1])/(heights[high]-heights[high-1]),0,1)
        return (joint(roles[high-1]),joint(roles[high]),0,0),(1-t,t,0,0)
    def altitude(y):
        return np.interp(y,[0,240,285,400,530,665,1000,1420,1510],
                           [1.91,1.55,1.46,1.34,1.18,1.04,.62,.14,.053])
    def shell(profile,chain,side=1,kind="body",depth_offset=0):
        pos=[]; tex=[]; joints=[]; weights=[]; faces=[]; blink=[]; smile=[]
        profile=np.asarray(profile)
        ys=sorted(set(profile[:,0]).union(np.arange(profile[0,0],profile[-1,0],5 if kind=="face" else 22)))
        segments=40 if kind=="face" else 12 if kind=="lock" else 24
        # Duplicate side meridians: each half has its own projection and UV island.
        meridians=[(i*2*pi/segments-pi/2,False) for i in range(segments//2+1)]
        meridians += [(i*2*pi/segments+pi/2,True) for i in range(segments//2+1)]
        stride=len(meridians)
        for row,y in enumerate(ys):
            cx,rx,rz=[np.interp(y,profile[:,0],profile[:,k]) for k in [1,2,3]]
            for i,(angle,rear_half) in enumerate(meridians):
                x=cx+rx*sin(angle)
                wx=(512-x)*.00112*side
                wy=altitude(y)
                wz=depth_offset-rz*cos(angle)
                if kind=="face":
                    wz-=.019*exp(-((x-512)/12)**2-((y-192)/11)**2)*max(0,cos(angle))
                if kind=="arm":
                    # The authored arm is diagonal in the image but horizontal in bind pose.
                    # Cross-section width belongs across the humerus, not along it.
                    wx=-side*np.interp(y,[277,292,465,695,785],[.088,.127,.335,.542,.677])
                    wy=1.459-(x-cx)*.00122-(y-280)*.000025
                    wz*=1.12
                if kind=="foot":
                    # Shape in anatomical space without moving the UV landmarks.
                    width=np.interp(y,[650,755,900,1005,1124,1280,1420,1495,1511],
                                      [1.10,1.18,1.20,1.15,1.26,1.20,1.18,1.27,1.18])
                    wx=-side*((cx-512)*.00124+(x-cx)*.00112*width)
                    depth=np.interp(y,[650,740,895,1005,1080,1160,1300,1415,1455,1485,1504,1511],
                                      [.080,.109,.089,.068,.073,.089,.058,.039,.056,.078,.085,.018])
                    center=np.interp(y,[650,890,1005,1140,1300,1420,1455,1495,1511],
                                       [0,.003,-.014,.018,.023,.027,.012,-.023,-.038])
                    wz=center-depth*cos(angle)
                    if y>1420:
                        wy=np.interp(y,[1420,1455,1490,1505,1511],[.14,.104,.072,.059,.056])
                        wy+=.017*max(0,-cos(angle))*sin(pi*(y-1420)/91)
                u,v=x,y
                if side==-1:
                    u=1024-u
                if kind=="lock":
                    # The inner part of the crown provides continuous fine hair fibres.
                    u=522+25*sin(angle)+8*sin(y*.012)
                    v=76+(y%720)*.115
                    rear_half=True
                if rear_half:
                    u=2048-u
                js,ws=influences(y,chain)
                pos.append([wx,wy,wz]);tex.append([u/2048,v/1536]);joints.append(js);weights.append(ws)
                front=max(0,cos(angle))
                eye=exp(-((abs(x-512)-40)/22)**4-((y-173)/15)**4)*front if kind=="face" else 0
                blink.append([0,(y-174)*.00135*eye,0])
                mouth=exp(-((abs(x-512)-12)/9)**2-((y-213)/9)**2)*front if kind=="face" else 0
                smile.append([0,.006*mouth,0])
                if row and i not in (0,segments//2+1):
                    d=len(pos)-1;b=d-stride
                    faces.extend([(b-1,d-1,b),(b,d-1,d)])
        points=np.array(pos)
        tris=np.array(faces)
        if side==-1:
            tris=tris[:,::-1]
        norms=np.zeros_like(points)
        a,b,c=points[tris[:,0]],points[tris[:,1]],points[tris[:,2]]
        n=np.cross(b-a,c-a)
        for col in range(3):
            np.add.at(norms,tris[:,col],n)
        # Share normals on the duplicated front/back UV seam.
        strips=norms.reshape(-1,stride,3)
        for left,right in ((0,stride-1),(segments//2,segments//2+1)):
            shared=strips[:,left]+strips[:,right]
            strips[:,left]=shared
            strips[:,right]=shared
        norms/=np.maximum(np.linalg.norm(norms,axis=1,keepdims=True),1e-8)
        pieces.append((points,norms,tex,joints,weights,tris,blink,smile))
    head=[(0,"C_Head"),(1550,"C_Head")]
    trunk=[(235,"C_Neck"),(300,"C_UpperChest"),(410,"C_Chest"),(525,"C_Spine"),(615,"C_Hips"),(750,"C_Hips")]
    shell([(28,512,2,.01),(43,512,60,.063),(80,512,95,.10),(129,512,101,.113),(175,512,89,.111),(201,512,78,.092),(224,512,49,.076),(243,512,8,.024)],head,kind="face",depth_offset=-.018)
    shell([(226,512,26,.032),(258,512,38,.04),(282,512,81,.061),(306,512,115,.073),(350,512,112,.101),(397,512,116,.132),(449,512,93,.09),(500,512,80,.072),(547,512,91,.082),(603,512,117,.102),(653,512,120,.099),(693,512,88,.074),(725,512,20,.032)],trunk)
    for side,letter in [(1,"L"),(-1,"R")]:
        def limb(parts):
            return [(y,letter+"_"+bone) for y,bone in parts]
        leg=limb([(630,"UpperLeg"),(927,"UpperLeg"),(1040,"LowerLeg"),(1380,"LowerLeg"),(1445,"Foot"),(1510,"Foot")])
        shell([(650,582,47,.07),(711,586,73,.081),(791,585,70,.079),(887,580,57,.065),(1007,573,44,.051),(1053,576,43,.049),(1124,578,51,.057),(1212,579,48,.052),(1320,579,33,.037),(1420,579,24,.031),(1450,580,26,.032),(1492,580,34,.04),(1507,580,26,.028),(1511,580,1,.008)],leg,side,"foot")
        arm=limb([(276,"UpperArm"),(428,"UpperArm"),(492,"LowerArm"),(664,"LowerArm"),(711,"Hand"),(790,"Hand")])
        shell([(277,612,8,.015),(292,620,31,.041),(351,651,30,.037),(405,677,33,.041),(454,696,36,.042),(520,721,43,.05),(608,776,67,.062),(633,804,53,.053),(651,820,27,.036),(687,847,21,.023),(727,876,21,.017),(775,909,8,.008),(784,915,1,.003)],arm,side,"arm")
        shell([(10,611,1,.003),(43,604,17,.022),(76,595,28,.029),(84,593,19,.023)],head,side,depth_offset=.012)
        for i in range(5):
            x=572+7*i
            shell([(53+i*2,x-25,2,.006),(93,x,21,.033),(166,x+16,26,.044),(243,x+17,22,.038),(353,x+40+i*5,24,.035),(466,x+65+i*6,22,.029),(565,x+48+i*5,19,.022),(657+i*12,x+36+i*4,11,.018),(696+i*13,x+19+i*3,1,.003)],head,side,"lock",.041+i*.011)
        # Distinct left and right cascades, with hip/thigh blending for seated poses.
        shell([(559,614,5,.016),(612,636,21,.032),(665,659,36,.055),(745,674,36,.058),(844,681,29,.052),(972,698,38,.05),(1084,711,29,.043),(1177,730,37,.044),(1250,729,21,.032),(1330,736,3,.008)],[(550,"C_Hips"),(780,letter+"_UpperLeg"),(1000,letter+"_LowerLeg"),(1350,letter+"_LowerLeg")],side,depth_offset=.018)
    attributes={}
    for index,(name,shape,typ) in enumerate([("POSITION","VEC3",5126),("NORMAL","VEC3",5126),("TEXCOORD_0","VEC2",5126),("JOINTS_0","VEC4",5123),("WEIGHTS_0","VEC4",5126)]):
        attributes[name]=append_accessor(doc,data,np.concatenate([p[index] for p in pieces]),shape,typ)
    indices=[];offset=0
    for piece in pieces:
        indices.extend((piece[5]+offset).flatten());offset+=len(piece[0])
    primitive={"attributes":attributes,"indices":append_accessor(doc,data,np.reshape(indices,(-1,1)),"SCALAR",5125),"material":0}
    primitive["targets"]=[{"POSITION":append_accessor(doc,data,np.concatenate([p[col] for p in pieces]),"VEC3",5126)} for col in (6,7)]
    doc["meshes"]=[{"name":"ZXC","weights":[0,0],"extras":{"targetNames":["blink","happy"]},"primitives":[primitive]}]
    data.extend(bytes(-len(data)%4))
    doc["buffers"]=[{"byteLength":len(data)}]
    tree=json.dumps(doc,separators=(",",":")).encode();tree+=b" "*(-len(tree)%4)
    return struct.pack("<4sIII4s",b"glTF",2,28+len(tree)+len(data),len(tree),b"JSON")+tree+struct.pack("<I4s",len(data),b"BIN\0")+data


if __name__=="__main__":
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ("skeleton","front","back","output"):
        parser.add_argument(name,type=Path)
    parser.add_argument("--stockings",action="store_true")
    args=parser.parse_args()
    content=build(args.skeleton.read_bytes(),args.front,args.back,args.stockings)
    with args.output.open("xb") as target:
        target.write(content)
