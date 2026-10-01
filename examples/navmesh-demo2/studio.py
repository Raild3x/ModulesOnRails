"""Studio run of the warehouse demo, with screenshots. Run from the repo root after
`lune run examples/navmesh-demo2/bake.luau`, with lib/navmesh, lib/navmeshadapter and
lib/constraineddelaunaydebug set up (their link modules and _Index; see README.md).

    python examples/navmesh-demo2/studio.py shot [--view top|oblique|door] [--seconds 30] [--no-draw]
    python examples/navmesh-demo2/studio.py play [--view free|top|oblique|door]   # opens Studio; press Run (F8)

Runs the demo in edit mode with run-in-roblox and captures the Studio window twice
(tools/navmesh/studio/capture.ps1: PrintWindow, maximized) at --settle and --settle + 6 seconds.
The two frames must differ (agents moved): that is the capture's negative control. Prints the
demo's log and timings; output lands in .bench/navmesh-demo2/ (gitignored).
"""
import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
CAPTURE = HERE.parents[1] / "tools" / "navmesh" / "studio" / "capture.ps1"
OUT = Path(".bench/navmesh-demo2")
# ponytail: the 3D viewport's box in this machine's maximized Studio layout; change it if yours differs
CROP = (10, 174, 1162, 993)

RUN = """local ReplicatedStorage = game:GetService("ReplicatedStorage")
local src = ReplicatedStorage:WaitForChild("src", 10)
local Demo = ReplicatedStorage:WaitForChild("Demo", 10)
print("[MARK] start")
require(Demo.StudioDemo)({{
\tNavMesh = require(src.navmesh.src.NavMesh),
\tAdapter = require(src.navmeshadapter.src.NavMeshAdapter),
\tRenderer = require(src.constraineddelaunaydebug.src.DrawListRenderer),
\tGame = require(Demo.Game), LevelParts = require(Demo.LevelParts), BakeText = require(Demo.BakeText),
\tBakeFolder = Demo.NavMeshBake, Seconds = {seconds}, Camera = "{view}", Draw = {draw},
}})
print("[MARK] done")
"""


def build_place(script: str, play: bool = False) -> Path:
    OUT.mkdir(parents=True, exist_ok=True)
    lib = (Path.cwd() / "lib").as_posix()
    demo = {"$className": "Folder", "NavMeshBake": {"$path": (HERE / "NavMeshBake").as_posix()}}
    for module in ("StudioDemo", "Game", "LevelParts", "BakeText"):
        demo[module] = {"$path": (HERE / f"{module}.luau").as_posix()}
    src = {"$className": "Folder"}
    for pkg in ("constraineddelaunay", "constraineddelaunaydebug", "navmesh", "navmeshadapter"):
        src[pkg] = {"$path": f"{lib}/{pkg}"}
    tree = {"$className": "DataModel", "ReplicatedStorage": {"$className": "ReplicatedStorage", "src": src, "Demo": demo}}
    (OUT / "run.luau").write_text(script, encoding="utf-8")
    if play:  # the same script as a server Script, so Run (F8) starts the demo
        (OUT / "play.server.luau").write_text(script, encoding="utf-8")
        tree["ServerScriptService"] = {"$className": "ServerScriptService",
                                       "NavMeshDemo2": {"$path": (OUT / "play.server.luau").resolve().as_posix()}}
    (OUT / "demo.project.json").write_text(json.dumps({"name": "navmesh-demo2", "tree": tree}, indent=2), encoding="utf-8")
    place = OUT / ("play.rbxl" if play else "demo.rbxl")
    subprocess.run(["rojo", "build", str(OUT / "demo.project.json"), "-o", str(place)], check=True)
    return place


def capture(png: Path, settle: int) -> subprocess.Popen:
    return subprocess.Popen(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(CAPTURE),
                             "-OutPath", str(png.resolve()), "-SettleSec", str(settle)], stdout=subprocess.PIPE, text=True)


def differ(a: Path, b: Path) -> float:
    """The fraction of pixels that differ between two captures."""
    from PIL import Image, ImageChops
    diff = ImageChops.difference(Image.open(a).convert("RGB"), Image.open(b).convert("RGB")).convert("L")
    changed = sum(1 for v in diff.get_flattened_data() if v > 16)
    return changed / (diff.width * diff.height)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="command", required=True)
    s = sub.add_parser("shot")
    s.add_argument("--view", choices=["top", "oblique", "door"], default="top")
    s.add_argument("--seconds", type=int, default=30)
    s.add_argument("--settle", type=int, default=16, help="seconds after the window opens before the first capture")
    s.add_argument("--no-draw", action="store_true", help="no debug drawing (negative control)")
    p = sub.add_parser("play")
    p.add_argument("--view", choices=["free", "top", "oblique", "door"], default="free")
    args = ap.parse_args()

    if args.command == "play":
        place = build_place(RUN.format(seconds="math.huge", view=args.view, draw="true"), play=True)
        os.startfile(place.resolve())  # noqa: S606 (Windows)
        print(f"opened {place}: press Run (F8) in Studio; Stop (Shift+F5) ends it")
        return 0

    name = f"shot-{args.view}" + ("-nodraw" if args.no_draw else "")
    place = build_place(RUN.format(seconds=args.seconds, view=args.view, draw="false" if args.no_draw else "true"))
    first, second = OUT / f"{name}-a.png", OUT / f"{name}-b.png"
    captures = [capture(first, args.settle), capture(second, args.settle + 6)]
    result = subprocess.run(["run-in-roblox", "--place", str(place), "--script", str(OUT / "run.luau")],
                            capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=args.seconds + 300)
    text = result.stdout + result.stderr
    (OUT / f"{name}.txt").write_text(text, encoding="utf-8")
    print(text.strip())
    saved = [c.communicate(timeout=120)[0].strip() for c in captures]
    print("\n".join(saved))
    ok = "[MARK] done" in text and all("SAVED" in line for line in saved)
    if ok:
        fraction = differ(first, second)
        print(f"FRAMES DIFFER in {fraction:.2%} of pixels")
        ok = fraction > 0
        from PIL import Image
        for png in (first, second):
            Image.open(png).crop(CROP).save(png.with_name(png.stem + "-viewport.png"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
