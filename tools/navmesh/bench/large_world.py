"""Ticket 31 in Studio: load the largest bakes and measure what ships to clients. Each bake
written by `lune run tools/navmesh/bench/large_world.luau ... bakes` (default TileSize) goes into
the place as a base64 StringValue (a Rojo `.txt`); the run decodes it with
EncodingService:Base64Decode and runs LargeWorld.Measure: Deserialize, heap, FindPath (cold,
unbounded, MaxExpansions) and Update (cold, then add/remove cycles).

Run from the repo root (it launches Studio; run `npm run setup navmesh` first):

    python tools/navmesh/bench/large_world.py --runs 3 [--side 4096]

Maps run in rotated order per run. Raw runs land in .bench/navmesh/large_world_studio/
(gitignored); the table is median [min-max] over runs.
"""
import argparse
import base64
import json
import shutil
import statistics
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from run import run  # noqa: E402

BAKES = Path(".bench/navmesh/large_world")
COLS = ["bake KB", "Deserialize ms", "heap MB", "FindPath p50", "p95", "Budget p50", "p95", "hits",
        "cold FindPath", "warm", "cold Update", "Update p50"]

SCRIPT = """local ReplicatedStorage = game:GetService("ReplicatedStorage")
local EncodingService = game:GetService("EncodingService")
local NavMesh = require(ReplicatedStorage:WaitForChild("NavMesh", 10).src.NavMesh)
local LargeWorld = require(ReplicatedStorage:WaitForChild("LargeWorld", 10))
local Bakes = ReplicatedStorage:WaitForChild("Bakes", 10)
local med, pct = LargeWorld.Median, LargeWorld.Pct
print("[MARK] start")
local names = {names}
for k = 0, #names - 1 do
\tlocal name = names[(k + {run}) % #names + 1]
\tlocal bake = EncodingService:Base64Decode(buffer.fromstring(Bakes[name].Value))
\ttask.wait()
\tlocal r = LargeWorld.Measure({{
\t\tNavMesh = NavMesh, Clock = os.clock, Yield = function() task.wait() end, Reps = 5, Pairs = 30,
\t}}, bake, {side})
\tprint(string.format("[R] %s | %.0f | %.1f | %.1f | %.2f | %.2f | %.2f | %.2f | %d | %.2f | %.2f | %.1f | %.1f",
\t\tname, buffer.len(bake) / 1024, med(r.deserialize), r.heap / 1024, med(r.path), pct(r.path, 0.95),
\t\tmed(r.pathBudget), pct(r.pathBudget, 0.95), r.budgetHits, r.coldPath, r.warmPath, r.coldUpdate, med(r.update)))
end
print("[MARK] done")
"""


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--runs", type=int, default=3)
    ap.add_argument("--side", type=int, default=4096)
    ap.add_argument("--timeout", type=int, default=1800)
    args = ap.parse_args()

    out = Path(".bench/navmesh/large_world_studio")
    if out.exists():
        shutil.rmtree(out)
    (out / "Bakes").mkdir(parents=True)
    names = []
    for bin_path in sorted(BAKES.glob(f"*-{args.side}.bin")):
        name = bin_path.stem.split("-")[0]
        names.append(name)
        (out / "Bakes" / f"{name}.txt").write_bytes(base64.b64encode(bin_path.read_bytes()))
    if not names:
        print(f"no bakes in {BAKES} for side {args.side}: run large_world.luau with `bakes` first")
        return 1
    shutil.copy(HERE / "LargeWorld.luau", out / "LargeWorld.luau")
    project = {"name": "navmesh-large-world", "tree": {"$className": "DataModel", "ReplicatedStorage": {
        "$className": "ReplicatedStorage",
        "NavMesh": {"$path": (Path.cwd() / "lib/navmesh").as_posix()},
        "LargeWorld": {"$path": "LargeWorld.luau"},
        "Bakes": {"$path": "Bakes"}}}}
    (out / "place.project.json").write_text(json.dumps(project, indent=2), encoding="utf-8")
    place = out / "bench.rbxl"
    run(["rojo", "build", str(out / "place.project.json"), "-o", str(place)])

    cells: dict = {}
    ok = True
    lua_names = "{" + ", ".join(f'"{n}"' for n in names) + "}"
    for i in range(1, args.runs + 1):
        script = out / f"run{i}.luau"
        script.write_text(SCRIPT.format(names=lua_names, run=i - 1, side=args.side), encoding="utf-8")
        result = run(["run-in-roblox", "--place", str(place), "--script", str(script)], check=False,
                     capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=args.timeout)
        text = result.stdout + result.stderr
        (out / f"run{i}.txt").write_text(text, encoding="utf-8")
        if "[MARK] done" not in text:
            print(f"FAIL run {i} did not finish; see {out / f'run{i}.txt'}")
            ok = False
        for line in text.splitlines():
            line = line.strip()
            if line.startswith("[R]"):
                parts = [p.strip() for p in line[3:].split("|")]
                cells.setdefault(parts[0], []).append([float(p) for p in parts[1:]])

    print(f"\n== {args.side}-stud bakes in Studio: median [min-max] over {args.runs} run(s)")
    print("| map | " + " | ".join(COLS) + " |")
    print("|" + "---|" * (len(COLS) + 1))
    for name in names:
        rows = cells.get(name, [])
        if not rows:
            continue
        out_cols = []
        for col in zip(*rows):
            med, lo, hi = statistics.median(col), min(col), max(col)
            out_cols.append(f"{med:.2f}" if lo == hi else f"{med:.2f} [{lo:.2f}-{hi:.2f}]")
        print(f"| {name} | " + " | ".join(out_cols) + " |")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
