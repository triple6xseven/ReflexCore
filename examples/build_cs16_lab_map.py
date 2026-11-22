"""Generate an original Counter-Strike 1.6 map source, textures and fixture route."""

import argparse
import json
from pathlib import Path
import struct


MAP_NAME = "de_reflex_lab"
GRID = "RX_GRID"
SITE = "RX_SITE"
TRIGGER = "AAATRIGGER"
SPAWN = (-400, -224, 40)
ROUTE = [
    SPAWN,
    (-304, -224, 36),
    (-304, 160, 36),
    (128, 160, 36),
    (304, 160, 36),
    (364, 44, 36),
    (364, -188, 40),
]


def point(values):
    return " ".join(map(str, values))


def box(minimum, maximum, texture=GRID):
    """Return a closed, axis-aligned brush in Valve 220 plane order."""
    x, y, z = minimum
    u, v, w = maximum
    side_x = "[ 0 1 0 0 ] [ 0 0 -1 0 ]"
    side_y = "[ 1 0 0 0 ] [ 0 0 -1 0 ]"
    side_z = "[ 1 0 0 0 ] [ 0 -1 0 0 ]"
    planes = [
        ((x, y, z), (x, v, z), (x, v, w), side_x),
        ((u, v, z), (u, y, z), (u, y, w), side_x),
        ((u, y, z), (x, y, z), (x, y, w), side_y),
        ((x, v, z), (u, v, z), (u, v, w), side_y),
        ((x, y, z), (u, y, z), (u, v, z), side_z),
        ((u, y, w), (x, y, w), (x, v, w), side_z),
    ]
    faces = [
        f"( {point(a)} ) ( {point(b)} ) ( {point(c)} ) {texture} {axes} 0 1 1"
        for a, b, c, axes in planes
    ]
    return "{\n" + "\n".join(faces) + "\n}"


def entity(classname, properties, brushes=()):
    lines = [f'"classname" "{classname}"']
    lines.extend(f'"{key}" "{value}"' for key, value in properties.items())
    lines.extend(brushes)
    return "{\n" + "\n".join(lines) + "\n}\n"


def source_map():
    shell = [
        box((-512, -352, -16), (512, 352, 0)),
        box((-512, -352, 176), (512, 352, 192)),
        box((-512, -352, 0), (-496, 352, 176)),
        box((496, -352, 0), (512, 352, 176)),
        box((-496, -352, 0), (496, -336, 176)),
        box((-496, 336, 0), (496, 352, 176)),
        # The full-height divider forces the route north around an occluded corner.
        box((-176, -336, 0), (128, 72, 176)),
        box((284, -272, 0), (460, -100, 4), SITE),
    ]
    result = entity("worldspawn", {"mapversion": 220, "wad": "rx_lab.wad"}, shell)
    result += entity("info_player_deathmatch", {"origin": point(SPAWN), "angle": 0})
    result += entity("info_player_start", {"origin": "408 268 40", "angle": 270})
    result += entity(
        "func_bomb_target",
        {},
        [box((288, -268, 4), (456, -104, 112), TRIGGER)],
    )
    for x, y in [(-360, -224), (-304, 142), (0, 178), (340, 166), (364, -182)]:
        result += entity("light", {"origin": point((x, y, 144)), "_light": "236 242 255 350"})
    return result


def texture_lump(name, is_site):
    palette = [(31, 46, 54), (44, 66, 77), (81, 109, 120), (195, 127, 40), (238, 185, 84)]
    palette += [(0, 0, 0)] * (256 - len(palette))
    offsets = []
    pixels = bytearray()
    for scale in (1, 2, 4, 8):
        size = 64 // scale
        tile = max(1, size // 4)
        offsets.append(40 + len(pixels))
        for y in range(size):
            for x in range(size):
                edge = min(x, y) == 0 or max(x, y) == size - 1
                if is_site:
                    pixels.append(4 if edge else 3)
                else:
                    pixels.append(2 if edge else (x // tile + y // tile) % 2)
    header = struct.pack("<16s6I", name.encode("ascii"), 64, 64, *offsets)
    entries = bytes(channel for color in palette for channel in color)
    return header + pixels + struct.pack("<H", len(palette)) + entries + b"\0\0"


def source_wad():
    payload = bytearray()
    directory = bytearray()
    names = [(GRID, False), (SITE, True), (TRIGGER, False)]
    for name, is_site in names:
        lump = texture_lump(name, is_site)
        directory.extend(struct.pack(
            "<iiiBBH16s", 12 + len(payload), len(lump), len(lump), 0x43, 0, 0, name.encode("ascii")
        ))
        payload.extend(lump)
    return struct.pack("<4sII", b"WAD3", len(names), 12 + len(payload)) + payload + directory


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path, help="A new or empty output directory")
    output = parser.parse_args().output
    if output.exists() and any(output.iterdir()):
        parser.error("output directory is not empty")
    output.mkdir(parents=True, exist_ok=True)
    route = {
        "schema": "reflexcore.cs16.route.v1",
        "map": MAP_NAME,
        "site": "A",
        "waypoints": [
            {"x": x, "y": y, "z": z, "radius": 32 if index not in (0, len(ROUTE) - 1) else 24}
            for index, (x, y, z) in enumerate(ROUTE)
        ],
    }
    with (output / f"{MAP_NAME}.map").open("x", encoding="ascii") as target:
        target.write(source_map())
    with (output / "rx_lab.wad").open("xb") as target:
        target.write(source_wad())
    with (output / f"{MAP_NAME}.json").open("x", encoding="ascii") as target:
        json.dump(route, target, indent=2)
        target.write("\n")


if __name__ == "__main__":
    main()
