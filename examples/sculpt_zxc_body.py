"""Blender background authoring pass. Output a private, rig-indexed surface cache.

blender -b -P sculpt_zxc_body.py -- Original.vrm Lunar.vrm body.npz
The Blender scene uses Z-up. The cache uses the original VRM joint ordering.
"""
import json
import struct
import sys
from pathlib import Path

import bpy
import bmesh
import numpy as np
from mathutils.bvhtree import BVHTree


def body_data(path):
    data = Path(path).read_bytes()
    length = struct.unpack_from("<I", data, 12)[0]
    doc = json.loads(data[20:20 + length])
    start = 28 + length
    node = next(n for n in doc["nodes"] if n.get("name") == "Body")
    skin = doc["skins"][node["skin"]]
    names = [doc["nodes"][i]["name"] for i in skin["joints"]]

    def read(index):
        acc = doc["accessors"][index]
        view = doc["bufferViews"][acc["bufferView"]]
        dtype = np.dtype({5123: "<u2", 5125: "<u4", 5126: "<f4"}[acc["componentType"]])
        width = {"VEC2": 2, "VEC3": 3, "VEC4": 4, "SCALAR": 1}[acc["type"]]
        offset = start + view.get("byteOffset", 0) + acc.get("byteOffset", 0)
        return np.ndarray((acc["count"], width), dtype, data, offset,
                          (view.get("byteStride", width*dtype.itemsize), dtype.itemsize))

    bind = doc["accessors"][skin["inverseBindMatrices"]]
    view = doc["bufferViews"][bind["bufferView"]]
    offset = start + view.get("byteOffset", 0) + bind.get("byteOffset", 0)
    inverse = np.frombuffer(data, dtype="<f4", count=16*bind["count"], offset=offset)
    rest = np.linalg.inv(inverse.reshape(-1,4,4).transpose(0,2,1))[:,:3,3]
    return doc["meshes"][node["mesh"]]["primitives"], doc["materials"], names, read, dict(zip(names,rest))


def source_mesh(pr, read, names, target_names, foot):
    fields = pr["attributes"]
    points = read(fields["POSITION"])
    triangles = (read(pr["indices"]).ravel() if "indices" in pr else np.arange(len(points)))
    used, indices = np.unique(triangles, return_inverse=True)
    points = points[used].copy()
    if not foot:
        height = points[:, 1]
        height += np.interp(height, [.15,.43,.59,.97,1.14,1.31], [0,.015,.032,.067,.075,.080])
    # Set a little daylight between the medial arches. Keep the hip and knee pivots.
    x, y, z = points.T
    x += np.sign(x)*.009*np.clip((.55-y)/.35, 0, 1)
    # Soften the lateral ankle fullness above the heel, tapering to the leg seam.
    ankle = np.exp(-((y-.142)/.020)**2)
    x -= (x-np.sign(x)*.053)*.11*ankle
    coords = np.column_stack((x, -z, y))
    mesh = bpy.data.meshes.new("Anatomy")
    mesh.from_pydata(coords.tolist(), [], indices.reshape(-1, 3).tolist())
    obj = bpy.data.objects.new("Forefeet" if foot else "Humanoid surface", mesh)
    bpy.context.collection.objects.link(obj)
    weights = read(fields["WEIGHTS_0"])[used]
    joints = read(fields["JOINTS_0"])[used]
    groups = [obj.vertex_groups.new(name=name) for name in target_names]
    for vertex, (js, ws) in enumerate(zip(joints, weights)):
        for j, w in zip(js, ws):
            if w > 0:
                groups[target_names.index(names[j])].add([vertex], float(w), "REPLACE")
    # Sew UV/material duplicates before smoothing; their rig weights match.
    bm = bmesh.new()
    bm.from_mesh(mesh)
    bmesh.ops.remove_doubles(bm, verts=list(bm.verts), dist=.000008)
    bm.to_mesh(mesh)
    bm.free()
    mesh.update()
    return obj


def sculpt_forefoot(obj):
    # Fuse the donor toe lofts to the metatarsal pad. Preserve the ankle
    # silhouette with a millimetre-scale voxel grid and a lightly smoothed surface.
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    bmesh.ops.holes_fill(bm, edges=[e for e in bm.edges if e.is_boundary])
    bmesh.ops.recalc_face_normals(bm, faces=list(bm.faces))
    bm.to_mesh(obj.data)
    bm.free()
    bpy.context.view_layer.objects.active = obj
    original = obj.data.copy()
    source_weights = [[(g.group,g.weight) for g in v.groups] for v in original.vertices]
    original.calc_loop_triangles()
    tris = [tuple(t.vertices) for t in original.loop_triangles]
    coords = [v.co.copy() for v in original.vertices]
    tree = BVHTree.FromPolygons(coords, tris, all_triangles=True)
    obj.data.remesh_voxel_size = .0019
    bpy.ops.object.voxel_remesh()
    smooth = obj.modifiers.new("Soften joins", "SMOOTH")
    smooth.factor = .60
    smooth.iterations = 7
    bpy.ops.object.modifier_apply(modifier=smooth.name)
    reduce = obj.modifiers.new("Desktop detail", "DECIMATE")
    reduce.ratio = .082
    bpy.ops.object.modifier_apply(modifier=reduce.name)
    # Transfer weights barycentrically from the nearest original triangle.
    for v in obj.data.vertices:
        q, _, face, _ = tree.find_nearest(v.co)
        a,b,c = (coords[i] for i in tris[face])
        ab,ac,aq = b-a,c-a,q-a
        denom=ab.dot(ab)*ac.dot(ac)-ab.dot(ac)**2
        t=(ac.dot(ac)*aq.dot(ab)-ab.dot(ac)*aq.dot(ac))/denom if denom>1e-18 else 0
        u=(ab.dot(ab)*aq.dot(ac)-ab.dot(ac)*aq.dot(ab))/denom if denom>1e-18 else 0
        weights={}
        for orig,scale in zip(tris[face],(1-t-u,t,u)):
            for group,value in source_weights[orig]:
                weights[group]=weights.get(group,0)+max(0,scale)*value
        for g in list(v.groups):
            obj.vertex_groups[g.group].remove([v.index])
        for group,value in weights.items():
            if value>0:
                obj.vertex_groups[group].add([v.index],value,"REPLACE")
    bpy.data.meshes.remove(original)
    obj.data.update()


def join_ankles(torso, feet):
    # Bridge two clean cross sections. A voxel cap at the ankle would leave a
    # ring under the shin and a visible discontinuity in a bent pose.
    for obj, height, upper in ((torso,.236,True),(feet,.120,False)):
        bm=bmesh.new()
        bm.from_mesh(obj.data)
        bmesh.ops.bisect_plane(bm,geom=list(bm.verts)+list(bm.edges)+list(bm.faces),
                               plane_co=(0,0,height),plane_no=(0,0,1),
                               clear_inner=upper,clear_outer=not upper)
        bm.to_mesh(obj.data)
        bm.free()
    bpy.ops.object.select_all(action="DESELECT")
    torso.select_set(True)
    feet.select_set(True)
    bpy.context.view_layer.objects.active=torso
    bpy.ops.object.join()
    bm=bmesh.new()
    bm.from_mesh(torso.data)
    for sign in (-1,1):
        def loop(z):
            ring=[v for v in bm.verts if v.co.x*sign>0 and abs(v.co.z-z)<.00002 and v.is_boundary]
            if len(ring)<3:
                raise ValueError("Open ankle ring missing")
            center=sum((v.co for v in ring),ring[0].co*0)/len(ring)
            items=sorted(((float(np.arctan2(v.co.y-center.y,v.co.x-center.x))%(2*np.pi),v) for v in ring),key=lambda pair:pair[0])
            return items
        lo,hi=loop(.120),loop(.236)
        # The ankle's cross section tapers in two stages. The upper ring
        # follows the calf, the lower one sits on the malleoli near the pivot.
        layer=bm.verts.layers.deform.active
        high_center=sum((v.co for _,v in hi),hi[0][1].co*0)/len(hi)
        low_center=sum((v.co for _,v in lo),lo[0][1].co*0)/len(lo)
        prefix="J_Bip_"+("R_" if sign>0 else "L_")
        foot_group=torso.vertex_groups[prefix+"Foot"].index
        shin_group=torso.vertex_groups[prefix+"LowerLeg"].index
        rings=[lo]
        for height,width,depth,foot_weight in (
            (.151,1.055,1.055,.75),(.191,.975,.98,.18)
        ):
            center=low_center.lerp(high_center,(height-.120)/(.236-.120))
            ring=[]
            for angle,vertex in hi:
                point=vertex.co-high_center
                point.x=point.x*width+center.x
                point.y=point.y*depth+center.y
                point.z=height+.005*np.cos(angle)*sign
                fitted=bm.verts.new(point)
                fitted[layer][foot_group]=foot_weight
                fitted[layer][shin_group]=1-foot_weight
                ring.append((angle,fitted))
            rings.append(ring)
        rings.append(hi)
        for lower,higher in zip(rings,rings[1:]):
            i=j=0
            while i<len(lower) or j<len(higher):
                left=lower[i%len(lower)][1]
                right=higher[j%len(higher)][1]
                next_lo=lower[(i+1)%len(lower)][0]+(2*np.pi if i+1>=len(lower) else 0)
                next_hi=higher[(j+1)%len(higher)][0]+(2*np.pi if j+1>=len(higher) else 0)
                if j==len(higher) or (i<len(lower) and next_lo<=next_hi):
                    i+=1
                    bm.faces.new((left,lower[i%len(lower)][1],right))
                else:
                    j+=1
                    bm.faces.new((left,higher[j%len(higher)][1],right))
    # Keep the donor winding on open body islands. Propagate it across the
    # new bridge rather than letting an open neckline determine "outside".
    bm.normal_update()
    for f in bm.faces:
        c=f.calc_center_median()
        if .1199<c.z<.2361:
            outward=c.copy()
            outward.x-=.053*(1 if c.x>0 else -1)
            outward.y+=.032
            outward.z=0
            if f.normal.dot(outward)<0:
                f.normal_flip()
    bm.to_mesh(torso.data)
    bm.free()
    torso.data.update()


def refine_proportions(obj, rest):
    # Sculpt relative to the joints that actually drive each contour.
    # A rib cage deserves its own taper; the waist should not carry a child's
    # torso silhouette over long legs. Preserve the existing rest skeleton.
    mesh = obj.data
    hips = rest["J_Bip_C_Hips"][1]
    chest = rest["J_Bip_C_Chest"][1]
    neck = rest["J_Bip_C_Neck"][1]

    def falloff(value, center, radius):
        t = min(abs(value-center)/radius,1.0)
        return (1-t*t)**2

    for vertex in mesh.vertices:
        x, depth, height = vertex.co
        sign = 1 if x >= 0 else -1
        # Slightly relax the sharp corset taper. Carry the change into the
        # lower ribs and lumbar line, leaving the shoulders and neck seam alone.
        if hips < height < neck and abs(x) < .20:
            waist = falloff(height,chest-.042,.141)
            ribs = falloff(height,chest+.036,.132)
            vertex.co.x += x*(.105*waist+.022*ribs)
            vertex.co.y -= .010*max(0.0,-depth/.076)*waist
            vertex.co.y += .005*max(0.0,depth/.118)*ribs

        prefix = "J_Bip_" + ("R_" if sign > 0 else "L_")
        knee_x, knee, knee_z = rest[prefix+"LowerLeg"]
        ankle_x, ankle, ankle_z = rest[prefix+"Foot"]
        if height >= hips or height <= ankle-.025:
            continue
        # Put the knee's definition towards the cap and the calf's volume
        # towards the back. This keeps the silhouette slim from the front.
        patella = falloff(height,knee+.006,.083)
        quad = falloff(height,knee+.213,.195)
        calf = falloff(height,knee-.132,.152)
        tibia_x = np.interp(height,[ankle,knee],[ankle_x,knee_x])
        tibia_z = np.interp(height,[ankle,knee],[ankle_z,knee_z])
        if height <= knee:
            vertex.co.x -= (x-tibia_x)*.045*calf
        vertex.co.x += sign*.004*quad*max(0.0,(abs(x)-abs(knee_x))/.08)
        vertex.co.y += .010*patella*min(1.0,max(0.0,(depth+knee_z)/.045))
        vertex.co.y -= .013*calf*min(1.0,max(0.0,(-depth-tibia_z)/.064))

        # Widen the long blending zone around the pivot in the flexing knee.
        # Leave other influences (such as skirt and toe bones) untouched.
        blend_radius=.083
        if abs(height-knee)<blend_radius:
            lower=obj.vertex_groups[prefix+"LowerLeg"]
            upper=obj.vertex_groups[prefix+"UpperLeg"]
            influences={g.group:g.weight for g in vertex.groups}
            sum_leg=influences.get(lower.index,0)+influences.get(upper.index,0)
            if sum_leg>.99:
                t=(height-knee+blend_radius)/(2*blend_radius)
                t=t*t*(3-2*t)
                upper.add([vertex.index],sum_leg*t,"REPLACE")
                lower.add([vertex.index],sum_leg*(1-t),"REPLACE")
    mesh.update()


def cut_briefs(body):
    bm = bmesh.new()
    bm.from_mesh(body.data)
    # Cut the two leg openings on a continuous curved line over the hip.
    for v in bm.verts:
        v.co.z -= .56*abs(v.co.x)
    bmesh.ops.bisect_plane(bm, geom=list(bm.verts)+list(bm.edges)+list(bm.faces),
                                 plane_co=(0,0,.957), plane_no=(0,0,1), clear_inner=True)
    for v in bm.verts:
        v.co.z += .56*abs(v.co.x)
    bmesh.ops.bisect_plane(bm, geom=list(bm.verts)+list(bm.edges)+list(bm.faces),
                           plane_co=(0,0,1.084), plane_no=(0,0,1), clear_outer=True)
    bm.normal_update()
    for v in bm.verts:
        v.co += v.normal*.0028
    mesh = bpy.data.meshes.new("Velvet briefs")
    bm.to_mesh(mesh)
    bm.free()
    obj = bpy.data.objects.new("Velvet briefs", mesh)
    bpy.context.collection.objects.link(obj)
    for group in body.vertex_groups:
        obj.vertex_groups.new(name=group.name)
    mesh.update()
    return obj


def uv_for(co, normal, rear, part):
    x, depth, h = co
    side = -1 if x > 0 else 1
    if part in ("leg","foot"):
        # Unwrap each half separately so no triangle wraps over the entire atlas.
        turn = np.arcsin(np.clip(normal.x*(-1 if x<0 else 1),-1,1))/(2*np.pi)
        angle = .75-turn if rear else .25+turn
        return ((8+100*angle)/2048,(150+410*max(0,1-h))/1536)
    if part=="hands" or (abs(x)>.168 and h>1.33):
        u, v = 165 + normal.z*12, 45 + normal.y*12
    else:
        v = np.interp(h, [.956,1.015,1.09,1.18,1.29,1.38,1.44,1.49,1.56,1.60],
                      [727,685,604,524,448,375,321,286,256,235])
        radius = np.interp(h,[.956,1.02,1.09,1.18,1.29,1.38,1.44,1.49,1.56],
                           [.154,.152,.130,.103,.119,.14,.145,.12,.040])
        width = np.interp(v,[235,255,280,309,374,448,520,604,685,727],
                          [25,32,69,105,115,92,80,112,123,119])
        u = 512 - np.clip(x/radius,-1,1)*width
    if part=="hands":
        rear=False
    if part == "briefs":
        # Tile the woven fabric swatch in the unused top-left of the atlas.
        u = 62 + x*208
        v = 65 + (1.084-h)*310
        rear = False
    return ((2048-u if rear else u)/2048, v/1536)


def collect(obj, part, streams):
    mesh = obj.data
    mesh.calc_loop_triangles()
    local = {}
    for tri in mesh.loop_triangles:
        rear = tri.normal.y < 0
        height=sum(mesh.vertices[i].co.z for i in tri.vertices)/3
        chart="leg" if part=="body" and height<1.078 else part
        face = []
        for i in tri.vertices:
            key = (i, rear, chart)
            if key not in local:
                v = mesh.vertices[i]
                co, n = v.co, v.normal
                groups = sorted(((g.group,g.weight) for g in v.groups if g.weight>0),
                                key=lambda pair: -pair[1])[:4]
                total = sum(w for _, w in groups)
                if total <= 0:
                    raise ValueError(f"Unweighted {part} vertex {i}")
                js, ws = zip(*(groups+[(0,0)]*(4-len(groups))))
                local[key] = len(streams["pos"])
                streams["pos"].append((co.x,co.z,-co.y))
                streams["normal"].append((n.x,n.z,-n.y))
                streams["uv"].append(uv_for(co,n,rear,chart))
                streams["joints"].append(js)
                streams["weights"].append([w/total for w in ws])
            face.append(local[key])
        streams["tri"].append(face)


def main(original, lunar, output):
    source, _, names, read, _ = body_data(original)
    pieces, mats, target_names, rig_read, rest = body_data(lunar)
    foot = next(pr for pr in pieces if mats[pr["material"]]["name"]=="Midnight barefoot")
    torso = source_mesh(source[0], read, names, target_names, False)
    hands = source_mesh(source[2], read, names, target_names, False)
    feet = source_mesh(foot, rig_read, target_names, target_names, True)
    sculpt_forefoot(feet)
    join_ankles(torso,feet)
    refine_proportions(torso,rest)
    briefs = cut_briefs(torso)
    streams = {name: [] for name in ("pos","normal","uv","joints","weights","tri")}
    for obj, part in [(torso,"body"),(hands,"hands"),(briefs,"briefs")]:
        collect(obj, part, streams)
    with Path(output).open("xb") as dest:
        np.savez_compressed(dest, **streams, names=target_names)


if __name__=="__main__":
    main(*sys.argv[sys.argv.index("--")+1:])
