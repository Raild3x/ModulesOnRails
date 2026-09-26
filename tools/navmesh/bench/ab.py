"""A/B experiments for NavMesh prototypes, in Studio (native), with the audited method.

    python tools/navmesh/bench/ab.py <experiment> --runs 3 --rounds 5

Builds a place with lib/navmesh, the harness (AB.luau, TileSize.luau), the experiment
(ab/<experiment>.luau) and every prototype under variants/. It runs the place N times through
run-in-roblox and prints each cell's median over runs. It exits 1 when a variant's output
differs from the baseline, or a run does not finish. Run from the repo root, after
`npm run setup navmesh`. Raw runs land in .bench/navmesh/ab/<experiment>/ (gitignored).
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
local NavMesh = ReplicatedStorage:WaitForChild("NavMesh", 10)
local Bench = ReplicatedStorage:WaitForChild("Bench", 10)
local variants = {{}}
for _, child in Bench.Variants:GetChildren() do
\tvariants[child.Name] = if child:IsA("ModuleScript") then require(child) else require(child.ConstrainedDelaunay)
end
print("[MARK] start")
require(Bench.Experiment)({{
\tNavMesh = require(NavMesh.src.NavMesh),
\tQuantize = require(NavMesh.src.Quantize),
\tNavMeshStorage = require(NavMesh.src.Storage),
\tNavMeshOpenList = require(NavMesh.src.OpenList),
\tHeap = require(ReplicatedStorage:WaitForChild("Heap", 10)),
\tCDT = require(NavMesh.ConstrainedDelaunay),
\tTileSize = require(Bench.TileSize),
\tScenes = require(Bench.Scenes),
\tOpenLists = require(Bench.OpenLists),
\tAB = require(Bench.AB),
\tVariants = variants,
\tRounds = {rounds},
\tClock = os.clock,
\tYield = function() task.wait() end,
\tDeadline = os.clock() + {budget},
}})
"""


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("experiment")
    ap.add_argument("--runs", type=int, default=3)
    ap.add_argument("--rounds", type=int, default=5)
    ap.add_argument("--budget", type=int, default=480, help="seconds per Studio run")
    args = ap.parse_args()

    out = Path(".bench/navmesh/ab") / args.experiment
    if out.exists():
        shutil.rmtree(out)
    bench = out / "Bench"
    bench.mkdir(parents=True)
    shutil.copy(HERE / "AB.luau", bench / "AB.luau")
    shutil.copy(HERE / "TileSize.luau", bench / "TileSize.luau")
    shutil.copy(HERE / "Scenes.luau", bench / "Scenes.luau")
    shutil.copy(HERE / "OpenLists.luau", bench / "OpenLists.luau")
    shutil.copy(HERE / "ab" / f"{args.experiment}.luau", bench / "Experiment.luau")
    shutil.copytree(HERE / "variants", bench / "Variants")
    project = {"name": "navmesh-ab", "tree": {"$className": "DataModel", "ReplicatedStorage": {
        "$className": "ReplicatedStorage",
        "NavMesh": {"$path": (Path.cwd() / "lib/navmesh").as_posix()},
        "Heap": {"$path": (Path.cwd() / "lib/heap/src").as_posix()},
        "Bench": {"$path": "Bench"}}}}
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
                workload, variant, ms = [p.strip() for p in line[3:].split("|")]
                if (workload, variant) not in cells:
                    order.append((workload, variant))
                cells.setdefault((workload, variant), []).append(float(ms))
            elif line.startswith("[CHECK]") and "DIFFERENT" in line:
                print(f"FAIL output differs from baseline: {line}")
                ok = False

    print(f"\n== {args.experiment}: median of {args.runs} run(s) x {args.rounds} round(s), ms (native, Studio)")
    base: dict = {}
    for workload, variant in order:
        runs = cells[(workload, variant)]
        med = statistics.median(runs)
        base.setdefault(workload, med)
        spread = "/".join(f"{r:.2f}" for r in runs)
        print(f"{workload:>10} {variant:<16} {med:>10.2f}  {base[workload] / med:>5.1f}x  ({spread})")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
