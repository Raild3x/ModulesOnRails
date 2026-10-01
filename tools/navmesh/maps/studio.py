"""Studio screenshot of a harness map: builds the map as a place, runs its scenarios (the same
table as run.luau), draws the mesh and every scenario's path, and captures the Studio window.
Run from the repo root, with lib/navmesh, lib/navmeshadapter and lib/constraineddelaunaydebug
set up (their link modules and _Index: `npm run setup <pkg>`, or copy them from a set-up checkout).

    python tools/navmesh/maps/studio.py FlatLot [--hold 30] [--settle 20]

Studio.luau draws for --hold seconds, then clears the drawing and holds again. The first capture
(at --settle seconds after the window opens) shows the drawing; the second (--hold seconds later)
must differ from it: the capture's negative control. PNGs (full window and the cropped viewport)
and the log land in .bench/navmesh/maps/ (gitignored). Exits 1 if Studio fails, a scenario
fails, or the frames don't differ.
"""
import argparse
import json
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
CAPTURE = HERE.parents[0] / "studio" / "capture.ps1"
OUT = Path(".bench/navmesh/maps")
# ponytail: the 3D viewport's box in this machine's maximized Studio layout (as demo 2's studio.py)
CROP = (10, 174, 1162, 993)

RUN = """local ReplicatedStorage = game:GetService("ReplicatedStorage")
local src = ReplicatedStorage:WaitForChild("src", 10)
local Maps = ReplicatedStorage:WaitForChild("Maps", 10)
print("[MARK] start")
require(Maps.Studio)({{
\tNavMesh = require(src.navmesh.src.NavMesh),
\tAdapter = require(src.navmeshadapter.src.NavMeshAdapter),
\tRenderer = require(src.constraineddelaunaydebug.src.DrawListRenderer),
\tHarness = require(Maps.Harness),
\tMap = require(Maps.Maps["{map}"]),
\tHold = {hold},
}})
print("[MARK] done")
"""


def build_place(script: str) -> Path:
    OUT.mkdir(parents=True, exist_ok=True)
    lib = (Path.cwd() / "lib").as_posix()
    maps = {"$className": "Folder", "Maps": {"$path": (HERE / "Maps").as_posix()}}
    for module in HERE.glob("*.luau"):  # Studio, Harness, Parts and shared map builders
        if module.stem != "run":
            maps[module.stem] = {"$path": module.as_posix()}
    src = {"$className": "Folder"}
    for pkg in ("constraineddelaunay", "constraineddelaunaydebug", "navmesh", "navmeshadapter"):
        src[pkg] = {"$path": f"{lib}/{pkg}"}
    tree = {"$className": "DataModel", "ReplicatedStorage": {"$className": "ReplicatedStorage", "src": src, "Maps": maps}}
    (OUT / "run.luau").write_text(script, encoding="utf-8")
    (OUT / "maps.project.json").write_text(json.dumps({"name": "navmesh-maps", "tree": tree}, indent=2), encoding="utf-8")
    place = OUT / "maps.rbxl"
    subprocess.run(["rojo", "build", str(OUT / "maps.project.json"), "-o", str(place)], check=True)
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
    ap.add_argument("map", help="a module name in tools/navmesh/maps/Maps")
    ap.add_argument("--hold", type=int, default=30, help="seconds the drawing stays, then the cleared view")
    ap.add_argument("--settle", type=int, default=20, help="seconds after the window opens before the first capture")
    args = ap.parse_args()

    place = build_place(RUN.format(map=args.map, hold=args.hold))
    drawn, cleared = OUT / f"{args.map}.png", OUT / f"{args.map}-cleared.png"
    captures = [capture(drawn, args.settle), capture(cleared, args.settle + args.hold)]
    result = subprocess.run(["run-in-roblox", "--place", str(place), "--script", str(OUT / "run.luau")],
                            capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=2 * args.hold + 300)
    text = result.stdout + result.stderr
    (OUT / f"{args.map}.txt").write_text(text, encoding="utf-8")
    print(text.strip())
    saved = [c.communicate(timeout=120)[0].strip() for c in captures]
    print("\n".join(saved))
    ok = "[MARK] done" in text and "MAP PASS" in text and all("SAVED" in line for line in saved)
    if ok:
        fraction = differ(drawn, cleared)
        print(f"FRAMES DIFFER in {fraction:.2%} of pixels")
        ok = fraction > 0
        from PIL import Image
        for png in (drawn, cleared):
            Image.open(png).crop(CROP).save(png.with_name(png.stem + "-viewport.png"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
