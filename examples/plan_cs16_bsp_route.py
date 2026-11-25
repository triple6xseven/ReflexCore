"""Draft a standing walk route from a local Counter-Strike 1.6 BSP v30.

The standing hull and static brush models bound the route. Use a real game
run to verify dynamic collisions, C4 possession and successful planting.
"""

import argparse
import heapq
import json
import math
from pathlib import Path
import re
import struct
import sys
import time


EMPTY = -1
SOLID = -2
STEP_UP = 18.0
GROUND_CLEARANCE = 0.05
MAX_EXPANSIONS = 20_000
MAX_BSP = 32 * 1024 * 1024
MAX_ROUTE_HOP = 224.0


def vector(text):
    parts = tuple(float(value) for value in text.split())
    if len(parts) != 3 or not all(math.isfinite(value) for value in parts):
        raise ValueError("invalid vector")
    return parts


def translated(point, translation):
    return tuple(value - offset for value, offset in zip(point, translation))


def interpolate(start, end, fraction):
    return tuple(a + (b - a) * fraction for a, b in zip(start, end))


class Bsp:
    def __init__(self, path):
        with path.open("rb") as source:
            data = source.read(MAX_BSP + 1)
        if len(data) < 124 or len(data) > MAX_BSP or struct.unpack_from("<i", data)[0] != 30:
            raise ValueError("expected a bounded GoldSrc BSP v30 file")

        def lump(index):
            offset, size = struct.unpack_from("<ii", data, 4 + 8 * index)
            if offset < 0 or size < 0 or offset + size > len(data):
                raise ValueError("invalid BSP lump bounds")
            return memoryview(data)[offset:offset + size]

        self.planes = tuple(struct.iter_unpack("<4fi", lump(1)))
        self.nodes = tuple(struct.iter_unpack("<ihh", lump(9)))
        self.visual_nodes = tuple(struct.iter_unpack("<ihh6hHH", lump(5)))
        self.leaves = tuple(entry[0] for entry in struct.iter_unpack("<ii6h2H4B", lump(10)))
        self.models = tuple(struct.iter_unpack("<9f7i", lump(14)))
        if not self.models or not self.nodes:
            raise ValueError("BSP standing collision hull is missing")
        if any(not all(math.isfinite(v) for v in plane[:4]) for plane in self.planes):
            raise ValueError("non-finite BSP plane")
        if any(not 0 <= plane < len(self.planes) or max(front, back) >= len(self.nodes)
               for plane, front, back in self.nodes):
            raise ValueError("invalid clip node reference")

        self.entities = [
            dict(re.findall(r'"([^"\n]+)"\s+"([^"\n]*)"', chunk))
            for chunk in bytes(lump(0)).decode("latin1").split("}")
        ]
        self.obstacles = []
        for entity in self.entities:
            if entity.get("classname") not in {"func_breakable", "func_wall", "func_wall_toggle",
                                                 "func_door", "func_door_rotating"}:
                continue
            if not re.fullmatch(r"\*[0-9]{1,4}", entity.get("model", "")):
                continue
            model = self.models[int(entity["model"][1:])]
            origin = vector(entity.get("origin", "0 0 0"))
            mins = tuple(model[i] + origin[i] - (38 if i == 2 else 18) for i in range(3))
            maxs = tuple(model[i + 3] + origin[i] + (38 if i == 2 else 18) for i in range(3))
            self.obstacles.append((mins, maxs, model[10], origin))

    def trace(self, start, end, headnode):
        stack = [(headnode, 0.0, 1.0, 0.0)]
        delta = tuple(b - a for a, b in zip(start, end))
        remaining = 4 * len(self.nodes)
        while stack and remaining:
            remaining -= 1
            node, lo, hi, entry_z = stack.pop()
            if node < 0:
                if node != EMPTY and hi - lo > 1e-8:
                    return lo, entry_z
                continue
            plane, front, back = self.nodes[node]
            nx, ny, nz, distance, _ = self.planes[plane]
            x, y, z = start
            base = nx * x + ny * y + nz * z - distance
            rate = nx * delta[0] + ny * delta[1] + nz * delta[2]
            a, b = base + lo * rate, base + hi * rate
            if a >= 0.0 and b >= 0.0:
                stack.append((front, lo, hi, entry_z))
            elif a < 0.0 and b < 0.0:
                stack.append((back, lo, hi, entry_z))
            else:
                cross = min(hi, max(lo, -base / rate))
                if a >= 0.0:
                    near, far, normal_z = front, back, nz
                else:
                    near, far, normal_z = back, front, -nz
                stack.append((far, cross, hi, normal_z))
                stack.append((near, lo, cross, entry_z))
        if stack:
            raise ValueError("BSP clip node traversal budget exceeded")
        return None

    def first_hit(self, start, end):
        first = self.trace(start, end, self.models[0][10])
        if first is not None and first[0] == 0:
            return first
        for mins, maxs, headnode, origin in self.obstacles:
            if any(max(a, b) < lo or min(a, b) > hi
                   for a, b, lo, hi in zip(start, end, mins, maxs)):
                continue
            hit = self.trace(translated(start, origin), translated(end, origin), headnode)
            if hit is not None and (first is None or hit[0] < first[0]):
                first = hit
        return first

    def floor(self, point, drop):
        x, y, z = point
        hit = self.first_hit(point, (x, y, z - drop))
        if hit is not None and 0.0 < hit[0] <= 1.0 and hit[1] >= 0.7:
            return x, y, z - drop * hit[0] + GROUND_CLEARANCE
        return None

    def walk(self, start, x, y):
        z = start[2]
        target = (x, y, z)
        if self.first_hit(start, target) is None:
            floor = self.floor(target, STEP_UP + GROUND_CLEARANCE)
            if floor is not None:
                return floor
        raised = (start[0], start[1], z + STEP_UP)
        destination = (x, y, raised[2])
        if self.first_hit(start, raised) is None and self.first_hit(raised, destination) is None:
            return self.floor(destination, 2 * STEP_UP + GROUND_CLEARANCE)
        return None

    def brush_contains(self, model_index, point):
        node = self.models[model_index][9]
        x, y, z = point
        for _ in range(len(self.visual_nodes) + 1):
            if node < 0:
                return self.leaves[-1 - node] == SOLID
            plane, front, back, *_ = self.visual_nodes[node]
            a, b, c, distance, _ = self.planes[plane]
            node = front if a * x + b * y + c * z >= distance else back
        raise ValueError("BSP brush node traversal budget exceeded")

    def target_models(self):
        ids = [
            int(entity["model"][1:]) for entity in self.entities
            if entity.get("classname") == "func_bomb_target"
            and re.fullmatch(r"\*[0-9]{1,4}", entity.get("model", ""))
        ]
        if not ids:
            raise ValueError("no brush-based bomb target in this map")
        return ids

    def goal(self, model_index, point):
        # Keep the final waypoint radius within the actual brush rather than
        # succeeding at a target's rectangular bounding box.
        x, y, z = point
        for dx, dy in ((0, 0), (18, 0), (-18, 0), (0, 18), (0, -18)):
            if not self.brush_contains(model_index, (x + dx, y + dy, z)):
                return False
        return True


class NoWalkablePath(ValueError):
    pass


def find_path(bsp, start, model_indices, spacing, deadline, blocked_heading=None):
    targets = [(index, tuple(zip(bsp.models[index][:3], bsp.models[index][3:6])))
               for index in model_indices]

    def distance_to(point, bounds):
        return math.hypot(*(max(lo - v, 0, v - hi) for v, (lo, hi) in zip(point[:2], bounds)))

    def estimate(point):
        return min(distance_to(point, bounds) for _, bounds in targets)

    start_key = (0, 0, round(start[2]))
    points = {start_key: start}
    cost = {start_key: 0.0}
    parents = {start_key: None}
    queue = [(estimate(start), 0.0, start_key)]
    directions = [(dx, dy) for dx in (-1, 0, 1) for dy in (-1, 0, 1) if dx or dy]
    for iteration in range(MAX_EXPANSIONS):
        if not queue:
            break
        if iteration % 64 == 0 and time.monotonic() >= deadline:
            raise ValueError("BSP search exceeded its time budget")
        _, distance, key = heapq.heappop(queue)
        if distance > cost[key]:
            continue
        point = points[key]
        for index, bounds in targets:
            if distance_to(point, bounds) == 0 and bsp.goal(index, point):
                path = []
                while key is not None:
                    path.append(points[key])
                    key = parents[key]
                return path[::-1], index
        for dx, dy in directions:
            i, j = key[0] + dx, key[1] + dy
            x, y = start[0] + i * spacing, start[1] + j * spacing
            if not (bsp.models[0][0] <= x <= bsp.models[0][3] and
                    bsp.models[0][1] <= y <= bsp.models[0][4]):
                continue
            result = bsp.walk(point, x, y)
            if result is None:
                continue
            neighbor = (i, j, round(result[2]))
            next_cost = distance + math.dist(point, result)
            if key == start_key and blocked_heading is not None:
                angle = math.degrees(math.atan2(dy, dx))
                if abs((angle - blocked_heading + 180) % 360 - 180) < 46:
                    continue
            if next_cost + 1e-6 < cost.get(neighbor, math.inf):
                points[neighbor] = result
                cost[neighbor] = next_cost
                parents[neighbor] = key
                heapq.heappush(queue, (next_cost + estimate(result), next_cost, neighbor))
    raise NoWalkablePath("no ordinary standing walk found within the search budget")


def walk_segment(bsp, start, end, spacing):
    steps = max(1, math.ceil(math.dist(start[:2], end[:2]) / (spacing * math.sqrt(2) + 1e-6)))
    current = start
    for step in range(1, steps + 1):
        x, y, _ = interpolate(start, end, step / steps)
        current = bsp.walk(current, x, y)
        if current is None:
            return False
    return abs(current[2] - end[2]) <= 2.0


def has_side_clearance(bsp, start, end, spacing):
    dx, dy = end[0] - start[0], end[1] - start[1]
    length = math.hypot(dx, dy)
    if length == 0:
        return False
    for sign in (-1, 1):
        offset = (-dy * sign * 7 / length, dx * sign * 7 / length)
        shifted = []
        for x, y, z in (start, end):
            point = bsp.floor((x + offset[0], y + offset[1], z + 2), 8)
            if point is None or abs(point[2] - z) > 6:
                return False
            shifted.append(point)
        if not walk_segment(bsp, *shifted, spacing):
            return False
    return True


def simplify(bsp, points, spacing, preserve_first=False, require_clearance=False):
    last = int(preserve_first and len(points) > 1)
    result = points[:last + 1]
    while last < len(points) - 1:
        end = last + 1
        for candidate in range(end + 1, len(points)):
            if math.dist(points[last], points[candidate]) > MAX_ROUTE_HOP:
                break
            if (walk_segment(bsp, points[last], points[candidate], spacing)
                    and (not require_clearance or has_side_clearance(bsp, points[last], points[candidate], spacing))):
                end = candidate
        result.append(points[end])
        last = end
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bsp", type=Path)
    parser.add_argument("--start", type=float, nargs=3, metavar=("X", "Y", "Z"))
    parser.add_argument("--lobby-site", type=int, choices=(0,1))
    parser.add_argument("--lobby-spawn", action="store_true", help="Plan from a map spawn for lobby waypoint discovery")
    parser.add_argument("--auto", action="store_true", help="Discover and search all brush bomb targets")
    parser.add_argument("--blocked-heading", type=float,
                        help="Exclude the failed direction on the first recovery hop")
    parser.add_argument("--resume", action="store_true", help="Replan from a verified live actor position")
    parser.add_argument("--avoid-site", choices=("A", "B"), help="Prefer the other brush group during recovery")
    parser.add_argument("--site", choices=("A", "B"), help="Display label for a manual route")
    parser.add_argument("--target-model", type=int, help="Brush model index for a manual route")
    parser.add_argument("--spacing", choices=(16, 24, 32), type=int, default=24)
    args = parser.parse_args()
    if args.blocked_heading is not None and (not args.resume or not math.isfinite(args.blocked_heading)):
        parser.error("--blocked-heading needs --resume and a finite angle")
    if args.avoid_site is not None and not args.resume:
        parser.error("--avoid-site needs --resume")
    if args.resume and not args.auto:
        parser.error("--resume needs --auto")
    if args.auto and (args.site is not None or args.target_model is not None):
        parser.error("--auto discovers its own sites")
    if not args.auto and (args.site is None or args.target_model is None):
        parser.error("manual routes need --site and --target-model")
    name = args.bsp.stem
    if not re.fullmatch("[a-z0-9_]{1,32}", name):
        parser.error("invalid map name")
    try:
        bsp = Bsp(args.bsp)
        targets = bsp.target_models()
        if len(targets) > 16:
            raise ValueError("too many brush bomb targets")
        if not args.auto and args.target_model not in targets:
            raise ValueError("target-model must be a brush bomb target")
        spawns = [vector(e["origin"]) for e in bsp.entities
                  if e.get("classname") == "info_player_deathmatch" and "origin" in e]
        if args.lobby_spawn == bool(args.start):
            raise ValueError("choose one start source")
        start = spawns[0] if args.lobby_spawn else tuple(args.start)
        if not all(math.isfinite(v) for v in start) or (not args.resume and
                not any(math.dist(start, p) <= 48 for p in spawns)):
            raise ValueError("start must be an actual position near a Terrorist spawn")
        anchor = bsp.floor(start, 44) or bsp.floor((start[0], start[1], start[2] + 1), 44)
        if anchor is None:
            raise ValueError("could not settle a standing player on spawn ground")
        deadline = time.monotonic() + 20
        eligible = targets if args.auto else [args.target_model]
        if args.lobby_site is not None:
            eligible = [targets[args.lobby_site]]
        if args.avoid_site is not None and len(targets) > 1:
            eligible = targets[1:] if args.avoid_site == "A" else targets[:1]
        try:
            path, target = find_path(bsp, anchor, eligible, args.spacing, deadline, args.blocked_heading)
        except NoWalkablePath:
            if args.avoid_site is None or eligible == targets:
                raise
            path, target = find_path(bsp, anchor, targets, args.spacing, deadline, args.blocked_heading)
        route = simplify(bsp, path, args.spacing, args.blocked_heading is not None, args.auto)
        if not 2 <= len(route) <= 128:
            raise ValueError("route exceeds waypoint limit")
        if not bsp.goal(target, route[-1]):
            raise ValueError("standing route endpoint fails the brush safety check")
        if not all(walk_segment(bsp, start, end, args.spacing)
                   for start, end in zip(route, route[1:])):
            raise ValueError("simplified route fails standing-hull replay")
    except (OSError, IndexError, ValueError, struct.error) as error:
        parser.error(str(error))
    if not args.lobby_spawn:
        print(f"{len(path)} grid points -> {len(route)} waypoints in model {target}", file=sys.stderr)
    print(json.dumps({
        "schema": "reflexcore.cs16.route.v1",
        "map": name,
        "site": args.site or ("A" if target == targets[0] else "B"),
        "waypoints": [
            {"x": x, "y": y, "z": z, "radius": 8 if args.auto else 12}
            for x, y, z in route
        ],
    }, indent=2))


if __name__ == "__main__":
    main()
