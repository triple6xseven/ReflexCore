"""Build ZXC locally from its 1024x1536 A-pose illustration and a VRM skeleton.

Each profile row is (image y, horizontal center, half-width, depth in metres).
The anatomical cache is authored against the same humanoid skeleton and bind matrices.
"""
import argparse
from copy import deepcopy
from io import BytesIO
import json
from math import sin, cos, pi, exp
from pathlib import Path
import struct

import numpy as np
from PIL import Image, ImageDraw
from build_companion_avatar import decode_glb
from build_companion_midnight import append_accessor


def build(source, illustration, back, stockings, anatomy=None):
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
    if anatomy is not None:
        # An opaque satin panel with an embroidered repeat and a scalloped waistband.
        paint=ImageDraw.Draw(im)
        paint.rectangle((0,0,122,124), fill=(54,29,66))
        for y in range(48,125,8):
            for x in range(0,124,8):
                cx=x+4*(y%16==0)
                paint.line([(cx-3,y),(cx,y-3),(cx+3,y),(cx,y+3),(cx-3,y)],fill=(68,41,81))
                paint.ellipse((cx-1,y-1,cx+1,y+1),fill=(101,72,117))
        paint.line([(x,67+int(2*cos(x*pi/7))) for x in range(124)],fill=(195,143,197),width=2)
        paint.rectangle((140,24,188,68),fill=(248,215,214))
        # A cylindrical leg chart avoids projecting straps, dress panels or rear
        # artwork onto the calf when a seated leg turns towards the camera.
        for v in range(144,575):
            h=1.0-(v-150)/410
            blush=.54*exp(-((h-.62)/.083)**2)+.30*exp(-((h-.14)/.045)**2)
            for u in range(5,115):
                angle=(u-8)/100*2*pi
                shade=(1-cos(angle))*.5
                color=(248-10*shade,216-12*shade-8*blush,216-10*shade-4*blush)
                if stockings and h<.875:
                    color=(83-13*shade,58-10*shade,85-12*shade)
                trim=.867<h<.883 or .883<=h and (abs(angle-2.20)<.11 or abs(angle-4.18)<.11)
                if trim:
                    color=(84,56,91) if .870<h<.878 or h>=.883 else (137,104,144)
                paint.point((u,v),fill=tuple(int(c) for c in color))
    stream=BytesIO()
    im.save(stream,"JPEG",quality=96,subsampling=0)
    doc["images"].append({"bufferView":view(stream.getvalue()),"mimeType":"image/jpeg"})
    doc["textures"].append({"source":0})
    doc["materials"].append({"name":"ZXC painted satin","doubleSided":True,
        "pbrMetallicRoughness":{"baseColorTexture":{"index":0},"metallicFactor":0,"roughnessFactor":.9}})
    pieces=[]
    panel_indices=[]
    def joint(name):
        return names.index(name if name.startswith("J_Sec_") else "J_Bip_"+name)
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
                if kind=="panel":
                    # Thin folded silk hangs behind the outside of the thigh.
                    # Its hem is shorter at the front corner of the opening.
                    t=np.clip((y-559)/771,0,1)
                    across=sin(angle)
                    wx=-side*((cx-512)*.00112+rx*.00091*across+.014*t)
                    wz=.011+.125*t+.042*t*across+.009*sin(across*pi*1.7+t*3)-.004*cos(angle)
                    wy+=t*(.125+.055*(1-across))
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
                    # Retain the original thigh-to-ankle silhouette. Vary depth
                    # locally for the kneecap and the back of the calf.
                    kneecap=exp(-((y-997)/48)**2)
                    calf=exp(-((y-1130)/100)**2)
                    wz-=.006*kneecap*max(0,cos(angle))
                    wz+=.006*calf*max(0,-cos(angle))
                    if y>=1420:
                        depth=np.interp(y,[1420,1455,1485,1504,1511],[.031,.047,.069,.078,.042])
                        center=np.interp(y,[1420,1455,1485,1504,1511],[.018,.010,-.023,-.039,-.04])
                        wz=center-depth*cos(angle)
                        wy=np.interp(y,[1420,1455,1490,1505,1511],[.14,.100,.069,.058,.055])
                        arch=max(0,-sin(angle))*max(0,1-abs(cos(angle)))
                        wy+=.009*arch*sin(pi*(y-1420)/91)
                if kind.startswith("digit"):
                    finger=int(kind[-1])
                    length=(.046,.058,.062,.055,.043)[finger]
                    t=(y-727)/58
                    wx=-side*(.591+length*t-(.023 if finger==0 else 0))
                    wy=1.446+(finger-2)*.011*(1+.26*t)+rx*sin(angle)*.001
                    wz=-.015-rz*cos(angle)-.010*t*t
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
        if kind=="panel":
            panel_indices.append(len(pieces))
        pieces.append((points,norms,tex,joints,weights,tris,blink,smile))
    head=[(0,"C_Head"),(1550,"C_Head")]
    trunk=[(235,"C_Neck"),(300,"C_UpperChest"),(410,"C_Chest"),(525,"C_Spine"),(615,"C_Hips"),(750,"C_Hips")]
    shell([(28,512,2,.01),(43,512,60,.063),(80,512,95,.10),(129,512,101,.113),(175,512,89,.111),(201,512,78,.092),(224,512,49,.076),(243,512,8,.024)],head,kind="face",depth_offset=-.018)
    if anatomy is None:
        shell([(226,512,26,.032),(258,512,38,.04),(282,512,81,.061),(306,512,115,.073),(350,512,112,.101),(397,512,116,.132),(449,512,93,.09),(500,512,80,.072),(547,512,91,.082),(603,512,117,.102),(653,512,120,.099),(693,512,88,.074),(725,512,20,.032)],trunk)
    for side,letter in [(1,"L"),(-1,"R")]:
        def limb(parts):
            return [(y,letter+"_"+bone) for y,bone in parts]
        leg=limb([(630,"UpperLeg"),(927,"UpperLeg"),(1040,"LowerLeg"),(1380,"LowerLeg"),(1445,"Foot"),(1510,"Foot")])
        if anatomy is None:
            shell([(650,582,47,.07),(711,586,73,.081),(791,585,70,.079),(887,580,57,.065),(1007,573,44,.051),(1053,576,43,.049),(1124,578,51,.057),(1212,579,48,.052),(1320,579,33,.037),(1420,579,24,.031),(1450,580,26,.032),(1492,580,34,.04),(1507,580,26,.028),(1511,580,1,.008)],leg,side,"foot")
        arm=limb([(276,"UpperArm"),(428,"UpperArm"),(492,"LowerArm"),(664,"LowerArm"),(711,"Hand"),(790,"Hand")])
        sleeve=[(277,612,8,.015),(292,620,31,.041),(351,651,30,.037),(405,677,33,.041),(454,696,36,.042),(520,721,43,.05),(608,776,67,.062),(633,804,53,.053),(651,820,27,.036),(687,847,21,.023),(727,876,20,.014),(739,882,17,.012),(744,884,3,.008)]
        shell(sleeve if anatomy is None else sleeve[1:10],arm,side,"arm")
        for finger in range(5 if anatomy is None else 0):
            # Rounded independent digit tips overlap the skinned palm at the base.
            x=877+finger*2
            shell([(727,x,5,.007),(746,x+5,5,.006),(766,x+10,4,.005),
                   (780,x+13,3,.004),(785,x+14,.7,.001)],
                  limb([(727,"Hand"),(785,"Hand")]),side,"digit"+str(finger))
        shell([(10,611,1,.003),(43,604,17,.022),(76,595,28,.029),(84,593,19,.023)],head,side,depth_offset=.012)
        for i in range(5):
            x=572+7*i
            shell([(53+i*2,x-25,2,.006),(93,x,21,.033),(166,x+16,26,.044),(243,x+17,22,.038),(353,x+40+i*5,24,.035),(466,x+65+i*6,22,.029),(565,x+48+i*5,19,.022),(657+i*12,x+36+i*4,11,.018),(696+i*13,x+19+i*3,1,.003)],head,side,"lock",.041+i*.011)
        # Independent fabric panels blend from the pelvis onto skirt joints.
        shell([(559,614,5,.016),(612,636,21,.032),(665,659,36,.055),(745,674,36,.058),(844,681,29,.052),(972,698,38,.05),(1084,711,29,.043),(1177,730,37,.044),(1250,729,21,.032),(1330,736,3,.008)],[(550,"C_Hips"),(700,"C_Hips"),(925,"J_Sec_"+letter+"_SkirtSide1"),(1200,"J_Sec_"+letter+"_SkirtSide2"),(1350,"J_Sec_"+letter+"_SkirtSide2")],side,"panel")
    if anatomy is not None:
        with np.load(anatomy,allow_pickle=False) as body_mesh:
            if body_mesh["names"].tolist()!=names:
                raise ValueError("Body cache belongs to another skeleton")
            points=body_mesh["pos"]
            morph=np.zeros_like(points)
            pieces.append((points,body_mesh["normal"],body_mesh["uv"],body_mesh["joints"],
                           body_mesh["weights"],body_mesh["tri"],morph,morph))
    attributes={}
    for index,(name,shape,typ) in enumerate([("POSITION","VEC3",5126),("NORMAL","VEC3",5126),("TEXCOORD_0","VEC2",5126),("JOINTS_0","VEC4",5123),("WEIGHTS_0","VEC4",5126)]):
        attributes[name]=append_accessor(doc,data,np.concatenate([p[index] for p in pieces]),shape,typ)
    indices=[];offset=0
    for piece in pieces:
        indices.extend((piece[5]+offset).flatten());offset+=len(piece[0])
    primitive={"attributes":attributes,"indices":append_accessor(doc,data,np.reshape(indices,(-1,1)),"SCALAR",5125),"material":0}
    primitive["targets"]=[{"POSITION":append_accessor(doc,data,np.concatenate([p[col] for p in pieces]),"VEC3",5126)} for col in (6,7)]
    shape_names=["blink","happy"]
    if anatomy is not None:
        drape=[]
        for i,piece in enumerate(pieces):
            points=piece[0]
            delta=np.zeros_like(points)
            if i in panel_indices:
                # Roll the side opening over the ledge as the hips settle. The
                # upper fastening stays put; the lower silk clears the seat lip.
                drop=np.clip((1.108-points[:,1])/.19,0,1)
                roll=drop*drop*(3-2*drop)
                delta[:,2]=-roll*(.14+.09*np.clip(1.05-points[:,1],0,.7))
                delta[:,1]=.025*roll
            drape.append(delta)
        primitive["targets"].append({"POSITION":append_accessor(doc,data,np.concatenate(drape),"VEC3",5126)})
        shape_names.append("WindowDrape")
    doc["meshes"]=[{"name":"ZXC","weights":[0]*len(shape_names),"extras":{"targetNames":shape_names},"primitives":[primitive]}]
    data.extend(bytes(-len(data)%4))
    doc["buffers"]=[{"byteLength":len(data)}]
    tree=json.dumps(doc,separators=(",",":")).encode();tree+=b" "*(-len(tree)%4)
    return struct.pack("<4sIII4s",b"glTF",2,28+len(tree)+len(data),len(tree),b"JSON")+tree+struct.pack("<I4s",len(data),b"BIN\0")+data


if __name__=="__main__":
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ("skeleton","front","back","output"):
        parser.add_argument(name,type=Path)
    parser.add_argument("--stockings",action="store_true")
    parser.add_argument("--anatomy",type=Path,help="Surface cache authored in Blender by sculpt_zxc_body.py")
    args=parser.parse_args()
    content=build(args.skeleton.read_bytes(),args.front,args.back,args.stockings,args.anatomy)
    with args.output.open("xb") as target:
        target.write(content)
