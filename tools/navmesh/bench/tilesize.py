"""TileSize benchmark in Studio, over the contrasting scenes in Scenes.luau: builds a place
with lib/navmesh, TileSize.luau and Scenes.luau, runs it N times through run-in-roblox, and
prints each cell's median over runs.

Run from the repo root (it launches Studio; run `npm run setup navmesh` first):

    python tools/navmesh/bench/tilesize.py --runs 3 --rounds 3

Output and raw runs land in .bench/navmesh/tilesize/ (gitignored).
"""
import argparse
import json
import shutil
import statistics
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from run import run  # noqa: E402

SCRIPT = """local ReplicatedStorage = game:GetService("ReplicatedStorage")
local NavMesh = require(ReplicatedStorage:WaitForChild("NavMesh", 10).src.NavMesh)
print("[MARK] start")
require(ReplicatedStorage:WaitForChild("TileSize", 10)).Run({{
\tNavMesh = NavMesh,
\tClock = os.clock,
\tYield = function() task.wait() end,
\tScenes = require(ReplicatedStorage:WaitForChild("Scenes", 10)),
\tRounds = {rounds},
\tDeadline = os.clock() + {budget},
}})
"""


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--runs", type=int, default=3)
    ap.add_argument("--rounds", type=int, default=3)
    ap.add_argument("--budget", type=int, default=480)
    args = ap.parse_args()

    out = Path(".bench/navmesh/tilesize")
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    for name in ("TileSize.luau", "Scenes.luau"):
        shutil.copy(HERE / name, out / name)
    project = {"name": "navmesh-tilesize", "tree": {"$className": "DataModel", "ReplicatedStorage": {
        "$className": "ReplicatedStorage",
        "NavMesh": {"$path": (Path.cwd() / "lib/navmesh").as_posix()},
        "TileSize": {"$path": "TileSize.luau"},
        "Scenes": {"$path": "Scenes.luau"}}}}
    (out / "place.project.json").write_text(json.dumps(project, indent=2), encoding="utf-8")
    (out / "run.luau").write_text(SCRIPT.format(rounds=args.rounds, budget=args.budget), encoding="utf-8")
    place = out / "bench.rbxl"
    run(["rojo", "build", str(out / "place.project.json"), "-o", str(place)])

    cells: dict = {}
    order: list = []
    ok = True
    for i in range(1, args.runs + 1):
        result = run(["run-in-roblox", "--place", str(place), "--script", str(out / "run.luau")], check=False,
                     capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=args.budget + 300)
        text = result.stdout + result.stderr
        (out / f"run{i}.txt").write_text(text, encoding="utf-8")
        if "[MARK] done" not in text:
            print(f"FAIL run {i} did not finish; see {out / f'run{i}.txt'}")
            ok = False
        for line in text.splitlines():
            line = line.strip()
            if line.startswith("[R]"):
                parts = [p.strip() for p in line[3:].split("|")]
                key = (parts[0], int(parts[1]))
                if key not in cells:
                    order.append(key)
                cells.setdefault(key, []).append([float(p) for p in parts[2:]])

    print(f"\n== TileSize over scenes: median of {args.runs} run(s) x {args.rounds} round(s) (Studio)")
    print(f"{'scene':>8}{'size':>6}{'build ms':>11}{'tris':>8}{'verts':>8}{'tiles':>7}{'tile ms':>10}  build spread")
    for key in order:
        rows = cells[key]
        med = [statistics.median(col) for col in zip(*rows)]
        spread = "/".join(f"{r[0]:.0f}" for r in rows)
        print(f"{key[0]:>8}{key[1]:>6}{med[0]:>11.1f}{med[1]:>8.0f}{med[2]:>8.0f}{med[3]:>7.0f}{med[4]:>10.3f}  {spread}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
