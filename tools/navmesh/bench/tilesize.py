"""TileSize benchmark (ticket 13) in Studio: builds a place with lib/navmesh and TileSize.luau,
runs it N times through run-in-roblox, and prints the median over runs of each cell.

Run from the repo root (it launches Studio; `npm run setup navmesh` first):

    python tools/navmesh/bench/tilesize.py --runs 3 --rounds 3 --map 256

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
\tSizes = {{ {sizes} }},
\tMapSize = {map},
\tRounds = {rounds},
\tDeadline = os.clock() + {budget},
}})
"""


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--runs", type=int, default=3)
    ap.add_argument("--rounds", type=int, default=3)
    ap.add_argument("--map", type=int, default=256, help="map side in studs")
    ap.add_argument("--sizes", default="8,16,32,64,128")
    ap.add_argument("--budget", type=int, default=420)
    args = ap.parse_args()

    out = Path(".bench/navmesh/tilesize")
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    shutil.copy(HERE / "TileSize.luau", out / "TileSize.luau")
    repo = Path.cwd()
    project = {"name": "navmesh-tilesize", "tree": {"$className": "DataModel", "ReplicatedStorage": {
        "$className": "ReplicatedStorage",
        "NavMesh": {"$path": (repo / "lib/navmesh").as_posix()},
        "TileSize": {"$path": "TileSize.luau"}}}}
    (out / "place.project.json").write_text(json.dumps(project, indent=2), encoding="utf-8")
    (out / "run.luau").write_text(SCRIPT.format(sizes=args.sizes.replace(",", ", "), map=args.map,
                                                rounds=args.rounds, budget=args.budget), encoding="utf-8")
    place = out / "bench.rbxl"
    run(["rojo", "build", str(out / "place.project.json"), "-o", str(place)])

    cells: dict = {}
    ok = True
    for i in range(1, args.runs + 1):
        result = run(["run-in-roblox", "--place", str(place), "--script", str(out / "run.luau")],
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
                cells.setdefault(int(parts[0]), []).append([float(p) for p in parts[1:]])

    print(f"\n== TileSize, {args.map}-stud map: median of {args.runs} run(s) x {args.rounds} round(s)")
    print(f"{'size':>6}{'build ms':>11}{'tris':>8}{'verts':>8}{'tiles':>7}{'tile ms':>10}  build spread")
    for size in sorted(cells):
        rows = cells[size]
        med = [statistics.median(col) for col in zip(*rows)]
        spread = "/".join(f"{r[0]:.0f}" for r in rows)
        print(f"{size:>6}{med[0]:>11.1f}{med[1]:>8.0f}{med[2]:>8.0f}{med[3]:>7.0f}{med[4]:>10.2f}  {spread}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
