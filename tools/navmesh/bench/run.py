"""Navmesh storage benchmark: generate layouts, build a place, run Studio N times, aggregate.

Run from the repo root (rokit tools only resolve inside the repo):

    python tools/navmesh/bench/run.py --suite 2d --runs 3 --rounds 5   # the audited B1 method
    python tools/navmesh/bench/run.py --suite 2d --runs 1 --rounds 1   # smoke

Each run = median over interleaved rounds (layout order rotated) of best-of-3 reps; the table
is the median over runs. Output and raw runs land in .bench/navmesh/<suite>/ (gitignored).
Exits non-zero when a run hits its deadline, layouts disagree on the topology-only flood, or
the audited ranking does not reproduce (see RANKING_MIN_RATIO).
"""
import argparse
import json
import re
import shutil
import statistics
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
WORKLOADS = ["build", "locate", "flood", "dijkstra", "ins_grow", "ins_settle", "ins_pre", "toVec", "fromVec"]

# Layouts per suite, split by topology storage. The audit's headline (bench.md): i32 buffer
# topology beats table topology on a shuffled mesh's locate by about 1.9x (group medians).
SUITES = {
    "2d": {
        "buffer": ["L2_C_buf_f64", "L2_C_buf_f32", "L2_H_tblXY_bufTopo", "L2_C_buf_f64_typed",
                   "L2_D3_vlib_typed_bufTopo"],
        "table": ["L2_A_interleaved", "L2_B_split", "L2_H_bufXY_tblTopo", "L2_D3_scalar",
                  "L2_D3_scalar_typed", "L2_D3_vlib", "L2_D3_vlib_typed", "L2_D3_vmeth",
                  "L2_D2_scalar", "L2_D2_vmeth"],
    },
    "3d": {
        "buffer": ["L3_B3_f64", "L3_B3_f32", "L3_V3_vlib_typed_bufTopo", "L3_T3_split_bufTopo"],
        "table": ["L3_T3_interleaved", "L3_T3_split", "L3_B3_f64_tblTopo", "L3_V3_scalar_typed",
                  "L3_V3_vlib_typed", "L3_V3_vmeth_typed"],
    },
}
# Documented drift: Studio runs vary 10-30%. The audited ratio is ~1.9x, so 1.3x only fails
# when the ranking itself flips, not on noise.
RANKING_MIN_RATIO = 1.3

SCRIPT = """local Bench = game:GetService("ReplicatedStorage"):WaitForChild("Bench", 10)
print("[MARK] start")
require(Bench.Harness).run({config})
"""


def run(cmd, check=True, **kw):
    print("$", " ".join(str(c) for c in cmd), flush=True)
    return subprocess.run(cmd, check=check, **kw)


def build(out: Path, layouts, rounds: int, budget: int) -> Path:
    if out.exists():
        shutil.rmtree(out)
    bench = out / "bench"
    run([sys.executable, str(HERE / "gen_layouts.py"), str(bench / "gen")])
    for f in ("Harness.luau", "Mesh.luau"):
        shutil.copy(HERE / f, bench / f)
    project = {"name": "navmesh-bench", "tree": {"$className": "DataModel", "ReplicatedStorage": {
        "$className": "ReplicatedStorage", "Bench": {"$path": "bench"}}}}
    (out / "place.project.json").write_text(json.dumps(project, indent=2), encoding="utf-8")
    lua_list = "{ " + ", ".join(f'"{x}"' for x in layouts) + " }"
    config = (f"{{ budget = {budget}, rounds = {rounds}, meshes = {{ \"grid\", \"both\" }}, "
              f"layouts = {lua_list}, workloads = {{ " + ", ".join(f'"{w}"' for w in WORKLOADS) + " } }")
    (out / "run.luau").write_text(SCRIPT.format(config=config), encoding="utf-8")
    place = out / "bench.rbxl"
    run(["rojo", "build", str(out / "place.project.json"), "-o", str(place)])
    return place


def parse(text: str, data: dict, checks: dict):
    cols = []
    for line in text.splitlines():
        line = line.strip()
        if line.startswith("[HDR]"):
            cols = [c.strip() for c in line.split("|")][3:]
        elif line.startswith("[R]"):
            parts = [p.strip() for p in line.split("|")]
            _, mesh, layout = parts[0].split()
            for col, value in zip(cols, parts[1:1 + len(cols)]):
                if value != "n/a":
                    data.setdefault((mesh, layout, col), []).append(float(value))
        elif line.startswith("[CHECK]"):
            m = re.match(r"\[CHECK\] (\S+) (\S+) = (\S+) :: (.*)", line)
            if m:
                mesh, workload, value, layouts = m.groups()
                checks.setdefault((mesh, workload), set()).add(value)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--suite", choices=sorted(SUITES), default="2d")
    ap.add_argument("--runs", type=int, default=3)
    ap.add_argument("--rounds", type=int, default=5)
    ap.add_argument("--budget", type=int, default=420, help="seconds per Studio run before the harness stops")
    args = ap.parse_args()

    groups = SUITES[args.suite]
    out = Path(".bench/navmesh") / args.suite
    place = build(out, groups["buffer"] + groups["table"], args.rounds, args.budget)

    texts = []
    for i in range(1, args.runs + 1):
        result = run(["run-in-roblox", "--place", str(place), "--script", str(out / "run.luau")], check=False,
                     capture_output=True, text=True, encoding="utf-8", errors="replace",
                     timeout=args.budget + 300)
        texts.append(result.stdout + result.stderr)
        (out / f"run{i}.txt").write_text(texts[-1], encoding="utf-8")
    print(f"\n== {args.suite}: median of {args.runs} run(s), each the median of {args.rounds} round(s), ms")
    return 0 if report(texts, groups) else 1


def report(texts, groups) -> bool:
    """Print the median table and return whether every gate passed."""
    layouts = groups["buffer"] + groups["table"]
    data, checks, ok = {}, {}, True
    for i, text in enumerate(texts, 1):
        if "deadline hit" in text or "[MARK] done" not in text:
            print(f"FAIL run {i} did not finish (deadline or error)")
            ok = False
        parse(text, data, checks)

    for mesh in ("grid", "both"):
        print(f"-- mesh {mesh}" + (" (vertex and triangle ids shuffled)" if mesh == "both" else ""))
        print(f"{'layout':28s}" + "".join(f"{w:>11s}" for w in WORKLOADS))
        for layout in layouts:
            cells = [data.get((mesh, layout, w)) for w in WORKLOADS]
            print(f"{layout:28s}" + "".join(f"{statistics.median(c):11.2f}" if c else f"{'n/a':>11s}" for c in cells))

    for mesh in ("grid", "both"):
        flood = checks.get((mesh, "flood"), set())
        if len(flood) != 1:
            print(f"FAIL {mesh} flood: layouts disagree {sorted(flood)}")
            ok = False

    def group_median(name):
        return statistics.median(statistics.median(data[("both", L, "locate")]) for L in groups[name]
                                 if ("both", L, "locate") in data)

    try:
        buf, tbl = group_median("buffer"), group_median("table")
    except statistics.StatisticsError:
        print("FAIL no shuffled locate timings were collected")
        return False
    ratio = tbl / buf
    ok &= ratio >= RANKING_MIN_RATIO
    print(f"\n{'PASS' if ratio >= RANKING_MIN_RATIO else 'FAIL'} shuffled locate: table topology {tbl:.2f} ms"
          f" / buffer topology {buf:.2f} ms = {ratio:.2f}x (audited ~1.9x; must be >= {RANKING_MIN_RATIO}x)")
    return ok

if __name__ == "__main__":
    sys.exit(main())
