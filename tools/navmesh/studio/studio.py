"""Studio runs for the NavMesh debug renderer (ticket 20): the renderer-primitive benchmark and
the F7 screenshot. Run from the repo root, after `npm run setup constraineddelaunaydebug` and
`npm run setup navmesh`, and `npm run setup navmeshdebug` for the editor (the places mount
lib/<pkg> with the link modules setup writes).

    python tools/navmesh/studio/studio.py bench --runs 3 --rounds 5   # RendererBench.luau
    python tools/navmesh/studio/studio.py shot courtyard              # F7: Shot.luau + capture.ps1
    python tools/navmesh/studio/studio.py shot bench
    python tools/navmesh/studio/studio.py shot palette                # three paths + custom palette, dark baseplate
    python tools/navmesh/studio/studio.py shot editor                 # F7 of NavMeshEditor (EditorShot.luau)
    python tools/navmesh/studio/studio.py play                        # Play-mode editor session (ticket 21)

`bench` prints each cell's median over runs and exits 1 when a run does not finish or a Draw
yields. `shot` briefly maximizes Studio (PrintWindow capture: no focus, nothing on top leaks in), and saves the PNG in .bench/navmesh/studio/
(gitignored) for review with the Read tool. `shot editor[:<Fixture>]` opens NavMeshEditor on a
NavMesh fixture (default ThreeFloorStairs). `play [--fixture F] [--mode NavMesh|CDT]` builds
.bench/navmesh/studio/editor.rbxl, with a baseplate and a LocalScript that opens the editor,
and opens it in Studio: press Play (F5) there. `rojo build` embeds sources, so each command
rebuilds the place.
"""
import argparse
import json
import os
import statistics
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "bench"))
from run import run  # noqa: E402

OUT = Path(".bench/navmesh/studio")

PRELUDE = """local ReplicatedStorage = game:GetService("ReplicatedStorage")
local src = ReplicatedStorage:WaitForChild("src", 10)
local Studio = ReplicatedStorage:WaitForChild("Studio", 10)
print("[MARK] start")
local NavMesh = require(src.navmesh.src.NavMesh)
local Renderer = require(src.constraineddelaunaydebug.src.DrawListRenderer)
local Scenes = require(Studio.Scenes)
"""

BENCH = PRELUDE + """require(Studio.RendererBench)({{
\tNavMesh = NavMesh, Scenes = Scenes, Shipped = Renderer,
\tRounds = {rounds}, Reps = {reps}, Deadline = os.clock() + {budget},
}})
"""

EDITOR_SHOT = PRELUDE + """require(Studio.EditorShot)({{
	NavMesh = NavMesh, NavMeshEditor = require(src.navmeshdebug.src.NavMeshEditor), Fixture = "{fixture}",
	HoldSeconds = {hold},
}})
"""

# The Play-mode session: a LocalScript that opens the editor on a fixture.
SESSION = """-- Opens NavMeshEditor for the ticket 21 manual check (built by studio.py play).
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local src = ReplicatedStorage:WaitForChild("src")
local NavMesh = require(src.navmesh.src.NavMesh)
local ConstrainedDelaunay = require(src.constraineddelaunay.src.ConstrainedDelaunay)
local NavMeshEditor = require(src.navmeshdebug.src.NavMeshEditor)
local initial = if "{mode}" == "CDT"
	then ConstrainedDelaunay.Fixtures.ToInput(ConstrainedDelaunay.Fixtures["{fixture}"])
	else NavMesh.Fixtures["{fixture}"].Desc
local editor = NavMeshEditor.new(workspace, "{mode}", initial)
editor.Changed:Connect(function()
	print("[NavMeshEditor] description changed; press P to print it")
end)
"""

SHOT = PRELUDE + """require(Studio.Shot)({{
\tNavMesh = NavMesh, Renderer = Renderer, Scenes = Scenes, Scene = "{scene}", HoldSeconds = {hold},
}})
"""


def build_place(script: str, extra: dict | None = None, name: str = "studio") -> Path:
    OUT.mkdir(parents=True, exist_ok=True)
    lib = (Path.cwd() / "lib").as_posix()
    studio = {"$className": "Folder"}
    for module, path in (("RendererBench", HERE / "RendererBench.luau"), ("Shot", HERE / "Shot.luau"),
                       ("EditorShot", HERE / "EditorShot.luau"), ("Scenes", HERE.parent / "bench" / "Scenes.luau")):
        studio[module] = {"$path": path.as_posix()}
    src = {"$className": "Folder"}
    for pkg in ("constraineddelaunay", "constraineddelaunaydebug", "navmesh", "navmeshdebug"):
        src[pkg] = {"$path": f"{lib}/{pkg}"}
    project = {"name": "navmesh-studio", "tree": {"$className": "DataModel", "ReplicatedStorage": {
        "$className": "ReplicatedStorage", "src": src, "Studio": studio}}}
    project["tree"].update(extra or {})
    (OUT / f"{name}.project.json").write_text(json.dumps(project, indent=2), encoding="utf-8")
    (OUT / "run.luau").write_text(script, encoding="utf-8")
    place = OUT / f"{name}.rbxl"
    run(["rojo", "build", str(OUT / f"{name}.project.json"), "-o", str(place)])
    return place


def studio(place: Path, timeout: int) -> str:
    result = run(["run-in-roblox", "--place", str(place), "--script", str(OUT / "run.luau")], check=False,
                 capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=timeout)
    return result.stdout + result.stderr


def bench(args) -> int:
    place = build_place(BENCH.format(rounds=args.rounds, reps=args.reps, budget=args.budget))
    timings, memory, order, ok = {}, {}, [], True
    for i in range(1, args.runs + 1):
        text = studio(place, args.budget + 300)
        (OUT / f"bench{i}.txt").write_text(text, encoding="utf-8")
        if "[MARK] done" not in text or "deadline hit" in text:
            print(f"FAIL run {i} did not finish; see {OUT / f'bench{i}.txt'}")
            ok = False
        for line in text.splitlines():
            line = line.strip()
            parts = [p.strip() for p in line[3:].split("|")]
            if line.startswith("[W]") and i == 1:
                print(line)
            elif line.startswith("[Y]") and "YIELDS" in line:
                print(f"FAIL Draw yields: {line}")
                ok = False
            elif line.startswith("[R]"):
                key = (parts[0], parts[1])
                if key not in timings:
                    order.append(key)
                timings.setdefault(key, []).append([float(x) for x in parts[2:6]])
            elif line.startswith("[M]"):
                memory.setdefault((parts[0], parts[1]), []).append([float(x) for x in parts[2:5]])

    def med(rows, col):
        return statistics.median(r[col] for r in rows) if rows else float("nan")

    print(f"\n== renderer primitive: median of {args.runs} run(s) x {args.rounds} round(s), best of {args.reps}")
    print(f"{'scene':>10} {'variant':<13} {'draw ms':>8} {'redraw ms':>9} {'ready fr':>8} {'instances':>9} "
          f"{'engine MB':>9} {'rCPU ms':>8} {'rGPU ms':>8}  draw per run")
    for key in order:
        if key[1] == order[0][1]:
            base = memory.get((key[0], "none"), [])
            print(f"{key[0]:>10} {'(nothing)':<13} {'':>8} {'':>9} {'':>8} {'':>9} {'':>9} "
                  f"{med(base, 1):>8.2f} {med(base, 2):>8.2f}")
        rows, mem = timings[key], memory.get(key, [])
        spread = "/".join(f"{r[0]:.2f}" for r in rows)
        print(f"{key[0]:>10} {key[1]:<13} {med(rows, 0):>8.2f} {med(rows, 1):>9.2f} {med(rows, 3):>8.0f} "
              f"{med(rows, 2):>9.0f} {med(mem, 0):>9.2f} {med(mem, 1):>8.2f} {med(mem, 2):>8.2f}  ({spread})")
    return 0 if ok else 1


def shot(args) -> int:
    if args.scene.startswith("editor"):
        fixture = args.scene.partition(":")[2] or "ThreeFloorStairs"
        place = build_place(EDITOR_SHOT.format(fixture=fixture, hold=args.hold))
    else:
        place = build_place(SHOT.format(scene=args.scene, hold=args.hold))
    png = (OUT / f"{args.scene.replace(':', '-')}.png").resolve()
    capture = subprocess.Popen(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
                                str(HERE / "capture.ps1"), "-OutPath", str(png), "-SettleSec", str(args.settle)],
                               stdout=subprocess.PIPE, text=True)
    text = studio(place, args.hold + 300)
    (OUT / f"{args.scene.replace(':', '-')}.txt").write_text(text, encoding="utf-8")
    captured = capture.communicate(timeout=120)[0]
    print(text.strip())
    print(captured.strip())
    return 0 if "[MARK] done" in text and "SAVED" in captured else 1


def play(args) -> int:
    (OUT / "session").mkdir(parents=True, exist_ok=True)
    session = OUT / "session" / "NavMeshEditorSession.client.luau"
    session.write_text(SESSION.format(mode=args.mode, fixture=args.fixture), encoding="utf-8")
    extra = {
        "StarterPlayer": {"$className": "StarterPlayer", "StarterPlayerScripts": {
            "$className": "StarterPlayerScripts",
            "NavMeshEditorSession": {"$path": session.resolve().as_posix()}}},
        "Workspace": {"$className": "Workspace", "Baseplate": {"$className": "Part", "$properties": {
            "Anchored": True, "Size": [256, 1, 256], "Position": [20, -0.6, 10],
            "Color": [0.35, 0.35, 0.35], "Material": "SmoothPlastic"}}},
    }
    place = build_place("", extra, "editor")
    print(f"Built {place.resolve()}. Open it in Studio and press Play (F5).")
    if not args.no_open:
        os.startfile(place.resolve())  # noqa: S606 (Windows: opens the place in Studio)
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="command", required=True)
    b = sub.add_parser("bench")
    b.add_argument("--runs", type=int, default=3)
    b.add_argument("--rounds", type=int, default=5)
    b.add_argument("--reps", type=int, default=3)
    b.add_argument("--budget", type=int, default=480, help="seconds per Studio run")
    s = sub.add_parser("shot")
    s.add_argument("scene", help="courtyard, palette, a bench scene (props, bench, terrain, walls), or editor[:<Fixture>]")
    s.add_argument("--hold", type=int, default=14, help="seconds Studio stays open after drawing")
    s.add_argument("--settle", type=int, default=7, help="seconds capture.ps1 waits after the window opens")
    pl = sub.add_parser("play")
    pl.add_argument("--fixture", default="ThreeFloorStairs", help="a NavMesh fixture (a CDT fixture with --mode CDT)")
    pl.add_argument("--mode", choices=["NavMesh", "CDT"], default="NavMesh")
    pl.add_argument("--no-open", action="store_true", help="only build the place")
    args = ap.parse_args()
    return {"bench": bench, "shot": shot, "play": play}[args.command](args)


if __name__ == "__main__":
    sys.exit(main())
