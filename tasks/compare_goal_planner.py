"""Compare two release executables on the same 2,048-step read-only goal."""
import argparse
import json
import math
from pathlib import Path
import statistics
import subprocess
import tempfile
import time

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("before", type=Path)
    parser.add_argument("after", type=Path)
    args = parser.parse_args()
    binaries = [args.before.resolve(), args.after.resolve()]
    times = [[], []]
    with tempfile.TemporaryDirectory(prefix="reflex-planner-") as directory:
        goal = {"schema": "reflexcore.goal.v1", "name": "chain",
                "initial_state": "s0", "goal_state": "s2048", "skills": [
                    {"id": f"a{i:04}", "from": f"s{i}", "to": f"s{i+1}", "flow": "demo", "cost": 1}
                    for i in range(2048)]}
        manifest = Path(directory) / "chain.json"
        manifest.write_text(json.dumps(goal), encoding="utf-8")
        expected = None
        for trial in range(22):
            for i in ([0, 1] if trial % 2 == 0 else [1, 0]):
                start = time.perf_counter_ns()
                result = subprocess.run([binaries[i], "agent", "plan", manifest],
                                        cwd=directory, capture_output=True, check=True)
                ms = (time.perf_counter_ns() - start) / 1_000_000
                if expected is None:
                    expected = result.stdout
                if result.stdout != expected or b"2048 skills, total cost 2048" not in result.stdout:
                    raise ValueError("Plans differ")
                if trial >= 2:
                    times[i].append(ms)
    for name, samples in zip(("before", "after"), times):
        p95 = sorted(samples)[math.ceil(.95*len(samples))-1]
        print(f"{name} n={len(samples)} p50_ms={statistics.median(samples):.3f} p95_ms={p95:.3f}")
if __name__ == "__main__":
    main()
