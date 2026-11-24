import math
import time
import unittest

from plan_cs16_bsp_route import find_path, simplify


class OpenFixture:
    models = [(-128, -128, -32, 128, 128, 64), (48, 0, 0, 48, 0, 0)]

    def walk(self, start, x, y):
        return x, y, 0

    def floor(self, point, drop):
        return (point[0], point[1], 0) if point[1] == 0 else None

    def goal(self, index, point):
        return index == 1 and point == (48, 0, 0)


class RecoveryTest(unittest.TestCase):
    def test_shortcuts_without_lateral_support_keep_the_grid_hops(self):
        bsp = OpenFixture()
        points = [(0, 0, 0), (16, 0, 0), (32, 0, 0)]
        self.assertEqual(simplify(bsp, points, 16), [points[0], points[-1]])
        self.assertEqual(simplify(bsp, points, 16, require_clearance=True), points)

    def test_recovery_cannot_simplify_back_into_the_blocked_heading(self):
        bsp = OpenFixture()
        start = (0, 0, 0)
        deadline = time.monotonic() + 2
        direct, _ = find_path(bsp, start, [1], 16, deadline)
        self.assertEqual(direct[1], (16, 0, 0))
        recovered, target = find_path(bsp, start, [1], 16, deadline, 0)
        self.assertEqual(target, 1)
        x, y, _ = recovered[1]
        self.assertGreaterEqual(abs(math.degrees(math.atan2(y, x))), 46)
        simplified = simplify(bsp, recovered, 16, preserve_first=True)
        self.assertEqual(simplified[1], recovered[1])
        self.assertEqual(simplified[-1], direct[-1])


if __name__ == "__main__":
    unittest.main()
