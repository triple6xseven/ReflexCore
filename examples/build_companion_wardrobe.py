"""Extract reusable privately installed Companion assets into the Wardrobe kit."""
import argparse
from copy import deepcopy
from hashlib import sha256
import json
from pathlib import Path
import struct
from tempfile import NamedTemporaryFile

import numpy as np

from build_companion_avatar import decode_glb
from build_companion_midnight import accessor, append_accessor

LABELS = {
    "nocturne": "Midnight Nocturne",
    "lunar": "Lunar Temptation",
    "velvet": "Velvet Enchantress",
    "velvet_bloom": "Velvet Bloom",
    "zxc": "ZXC",
}
TABLES = ("accessors", "bufferViews", "materials", "textures", "images", "samplers")
FACE_TARGETS = {"blink": "blink", "joy": "happy", "sorrow": "warning",
                "angry": "warning", "surprised": "surprised"}


def encode(doc, binary):
    binary.extend(b"\0" * (-len(binary) % 4))
    doc["buffers"] = [{"byteLength": len(binary)}]
    tree = json.dumps(doc, separators=(",", ":"), ensure_ascii=True).encode()
    tree += b" " * (-len(tree) % 4)
    return (struct.pack("<4sII", b"glTF", 2, 28 + len(tree) + len(binary))
            + struct.pack("<I4s", len(tree), b"JSON") + tree
            + struct.pack("<I4s", len(binary), b"BIN\0") + binary)


class Extractor:
    def __init__(self, doc, binary):
        self.source = doc
        self.binary = binary
        self.out = {table: [] for table in TABLES}
        self.data = bytearray()
        self.copies = {table: {} for table in TABLES}

    def copy(self, table, i):
        if i in self.copies[table]:
            return self.copies[table][i]
        entry = deepcopy(self.source[table][i])
        if table == "bufferViews":
            offset = entry.get("byteOffset", 0)
            self.data.extend(b"\0" * (-len(self.data) % 4))
            entry["byteOffset"] = len(self.data)
            self.data.extend(self.binary[offset:offset+entry["byteLength"]])
        elif table in ("images", "accessors"):
            entry["bufferView"] = self.copy("bufferViews", entry["bufferView"])
        elif table == "materials":
            for section in (entry, entry.get("pbrMetallicRoughness", {})):
                for key, binding in section.items():
                    if key.endswith("Texture"):
                        binding["index"] = self.copy("textures", binding["index"])
        elif table == "textures":
            entry["source"] = self.copy("images", entry["source"])
            if "sampler" in entry:
                entry["sampler"] = self.copy("samplers", entry["sampler"])
        target = len(self.out[table])
        self.out[table].append(entry)
        self.copies[table][i] = target
        return target

    def primitive(self, source, targets, indices=None):
        outputs = {"material": self.copy("materials", source["material"])}
        if indices is not None:
            selection, indices = np.unique(indices, return_inverse=True)
            outputs["indices"] = append_accessor(self.out, self.data,
                                                 indices[:, None], "SCALAR", 5125)
        elif "indices" in source:
            outputs["indices"] = self.copy("accessors", source["indices"])

        def attributes(fields):
            if indices is None:
                return {name: self.copy("accessors", i) for name, i in fields.items()}
            return {name: append_accessor(self.out, self.data,
                         accessor(self.source, self.binary, i)[selection],
                         self.source["accessors"][i]["type"], self.source["accessors"][i]["componentType"])
                    for name, i in fields.items()}

        outputs["attributes"] = attributes(source["attributes"])
        if targets:
            outputs["targets"] = [attributes(source["targets"][target]) for target in targets]
        return outputs

    def collect_hair(self, sources):
        # Each batch shares its material and vertex format, giving hair a small
        # number of draw calls instead of a separate surface for each lock.
        groups = {}
        for source in sources:
            key = (source["material"], tuple(sorted(source["attributes"])))
            groups.setdefault(key, []).append(source)
        for (material, fields), primitives in groups.items():
            if len(primitives) == 1:
                yield self.primitive(primitives[0], [])
                continue
            rows = {name: [] for name in fields}
            indices = []
            offset = 0
            for source in primitives:
                attributes = source["attributes"]
                points = accessor(self.source, self.binary, attributes["POSITION"])
                refs = (accessor(self.source,self.binary,source["indices"]).ravel()
                        if "indices" in source else np.arange(len(points)))
                used, remapped = np.unique(refs, return_inverse=True)
                indices.append(remapped + offset)
                offset += len(used)
                for name in fields:
                    rows[name].append(accessor(self.source,self.binary,attributes[name])[used])
            yield {
                "material": self.copy("materials", material),
                "indices": append_accessor(self.out, self.data, np.concatenate(indices)[:, None], "SCALAR", 5125),
                "attributes": {name: append_accessor(self.out, self.data, np.concatenate(values),
                    self.source["accessors"][primitives[0]["attributes"][name]]["type"],
                    self.source["accessors"][primitives[0]["attributes"][name]]["componentType"])
                    for name, values in rows.items()},
            }


def outfit_sources(doc, binary, mesh):
    for primitive in mesh["primitives"]:
        material = doc["materials"][primitive["material"]]["name"]
        if "HairBack" in material:
            continue
        if "_Body_00_SKIN" in material:
            attrs = primitive["attributes"]
            coords = accessor(doc, binary, attrs["POSITION"])
            uses = (accessor(doc, binary, primitive["indices"]).ravel()
                    if "indices" in primitive else np.arange(len(coords)))
            # The donor body also contains a scalp island. It belongs with
            # the Lumen head, so a ZXC face can use its own silhouette.
            triangles = uses.reshape(-1, 3)
            scalp = (coords[triangles, 1] > 1.56).all(axis=1)
            if scalp.all():
                continue
            if scalp.any():
                yield primitive, triangles[~scalp].ravel()
                continue
        yield primitive, None


def extract(doc, binary, slot, edition):
    ex = Extractor(doc, binary)
    body = doc["meshes"][doc["nodes"][1]["mesh"]]
    if edition == "zxc":
        role = "body" if slot == "outfit" else slot
        desired = {"outfit": ["WindowDrape"], "hair": [],
                   "head": ["blink", "happy", "warning", "surprised"]}[slot]
        selected = None
        primitives = []
        for mesh in doc["meshes"]:
            names = mesh.get("extras", {}).get("targetNames", [])
            for primitive in mesh["primitives"]:
                spans = [part for part in primitive.get("extras", {}).get("reflexParts", [])
                         if part["slot"] == role]
                if not spans:
                    continue
                targets = [name for name in desired if name in names]
                if selected is not None and targets != selected:
                    raise ValueError(f"ZXC {role} surfaces need the same ordered morph targets")
                selected = targets
                source_indices = primitive.get("indices")
                source_points = doc["accessors"][primitive["attributes"]["POSITION"]]["count"]
                refs = (accessor(doc, binary, source_indices).ravel()
                        if source_indices is not None else np.arange(source_points))
                if len(spans) == 1 and spans[0]["start"] == 0 and spans[0]["count"] == len(refs):
                    indices = None
                else:
                    indices = refs[np.concatenate([np.arange(p["start"], p["start"]+p["count"])
                                                   for p in spans])]
                primitives.append(ex.primitive(primitive, [names.index(k) for k in targets], indices))
        if not primitives:
            raise ValueError(f"ZXC is missing {role} parts. Rebuild the VRM with the current builder.")
    elif slot == "outfit":
        selected = []
        primitives = [ex.primitive(p, [], ix) for p, ix in outfit_sources(doc, binary, body)]
    elif slot == "hair":
        selected = []
        hair = doc["meshes"][doc["nodes"][165]["mesh"]]
        scalp = [p for p in body["primitives"] if "HairBack" in doc["materials"][p["material"]]["name"]]
        primitives = list(ex.collect_hair(hair["primitives"] + scalp))
    else:
        face = doc["meshes"][doc["nodes"][0]["mesh"]]
        groups = doc["extensions"]["VRM"]["blendShapeMaster"]["blendShapeGroups"]
        chosen = {}
        for g in groups:
            key = FACE_TARGETS.get(g["presetName"].lower())
            if key is None and g["name"].lower() in ("surprised", "surprise"):
                key = "surprised"
            if key and g["binds"]:
                chosen.setdefault(key, g["binds"][0]["index"])
                if g["presetName"] == "sorrow":
                    chosen[key] = g["binds"][0]["index"]
        selected = list(chosen)
        primitives = [ex.primitive(p, list(chosen.values())) for p in face["primitives"]]
    mesh = {"name": {"outfit": "WardrobeBody", "hair": "WardrobeHair", "head": "WardrobeFace"}[slot],
            "primitives": primitives}
    if selected:
        mesh["extras"] = {"targetNames": selected}
        mesh["weights"] = [0] * len(selected)
    ex.out["meshes"] = [mesh]
    return encode(ex.out, ex.data)


def neutral_rig(doc, binary):
    nodes = [{k: v for k, v in n.items() if k not in ("mesh", "skin", "weights")}
             for n in doc["nodes"]]
    skin = deepcopy(doc["skins"][doc["nodes"][1]["skin"]])
    inverse = skin.pop("inverseBindMatrices")
    ex = Extractor(doc, binary)
    skin["inverseBindMatrices"] = ex.copy("accessors", inverse)
    ex.out["nodes"] = nodes
    ex.out["skins"] = [skin]
    ex.out["scenes"] = doc["scenes"]
    ex.out["scene"] = doc["scene"]
    vrm = doc["extensions"]["VRM"]
    ex.out["asset"] = {"version": "2.0", "generator": "ReflexCore Wardrobe"}
    ex.out["extensionsUsed"] = ["VRM", "KHR_materials_unlit"]
    ex.out["extensions"] = {"VRM": {k: vrm[k] for k in ("humanoid", "secondaryAnimation")}}
    ex.out["extensions"]["VRM"]["meta"] = {"title": vrm["meta"]["title"]}
    return encode(ex.out, ex.data)


def build(models, output, zxc, velvet_bloom=None):
    reference = None
    files = {}
    manifest = {"schema": "reflexcore.wardrobe.v1", "parts": {"outfit": {}, "hair": {}, "head": {}}}
    for edition, label in LABELS.items():
        directory = {"zxc": zxc, "velvet_bloom": velvet_bloom}.get(edition) or models
        stem = "avatar-" + edition.replace("_", "-")
        names = [directory / f"{stem}{suffix}.vrm" for suffix in ("", "-stockings")]
        if not all(path.is_file() for path in names):
            continue
        for variant, name in enumerate(names):
            doc, binary = decode_glb(name.read_bytes())
            rig = neutral_rig(doc, binary)
            canonical, bind = decode_glb(rig)
            key = tuple((n["name"], n.get("translation"), n.get("rotation"), n.get("scale"))
                        for i, n in enumerate(canonical["nodes"]) if i in canonical["skins"][0]["joints"])
            signature = (key, bind)
            if reference is None:
                reference = signature
            elif signature != reference:
                raise ValueError(f"{name.name} has an incompatible skeleton or bind pose")
            files[f"outfit-{edition}{'-stockings' if variant else ''}.part"] = extract(doc,binary,"outfit",edition)
            if not variant:
                files[f"rig-{edition}.part"] = rig
                files[f"hair-{edition}.part"] = extract(doc,binary,"hair",edition)
                manifest["parts"]["outfit"][edition] = label
                manifest["parts"]["hair"][edition] = label
                if edition in ("lunar", "zxc"):
                    files[f"head-{edition}.part"] = extract(doc,binary,"head",edition)
                    manifest["parts"]["head"][edition] = "Lumen" if edition=="lunar" else label
    if not all(manifest["parts"].values()):
        raise ValueError("The kit requires at least one fitted outfit, hairstyle and head")
    digest = sha256()
    for name, payload in sorted(files.items()):
        digest.update(name.encode())
        digest.update(sha256(payload).digest())
    generation = digest.hexdigest()[:20]
    folder = output / generation
    folder.mkdir(parents=True, exist_ok=True)
    for name, payload in files.items():
        destination = folder / name
        if not destination.exists() or destination.read_bytes() != payload:
            with NamedTemporaryFile(dir=folder, delete=False) as handle:
                handle.write(payload)
            Path(handle.name).replace(destination)
    manifest["generation"] = generation
    with NamedTemporaryFile(dir=output, delete=False) as handle:
        handle.write(json.dumps(manifest, separators=(",", ":")).encode())
    Path(handle.name).replace(output / "manifest.json")
    print(f"Prepared {len(files)} wardrobe parts in {generation}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("models", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--zxc", type=Path, help="Override the source directory for both ZXC assets")
    parser.add_argument("--velvet-bloom", type=Path, help="Override the source directory for both Velvet Bloom assets")
    args = parser.parse_args()
    build(args.models, args.output, args.zxc, args.velvet_bloom)
