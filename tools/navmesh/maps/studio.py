"""Studio screenshot of a harness map: builds the map as a place, runs its scenarios (the same
table as run.luau), draws the mesh and every scenario's path, and captures the Studio window.
Run from the repo root, with lib/navmesh, lib/navmeshadapter and lib/constraineddelaunaydebug
set up (their link modules and _Index: `npm run setup <pkg>`, or copy them from a set-up checkout).

    python tools/navmesh/maps/studio.py FlatLot [--hold 30] [--settle 20] [--view fx,fy,fz,tx,ty,tz --tag name]
    python tools/navmesh/maps/studio.py Highlands --tour views.json [--dwell 6] [--hold 5]

Studio.luau draws for --hold seconds, then clears the drawing and holds again. The first capture
(at --settle seconds after the window opens) shows the drawing; the second (--hold seconds later)
must differ from it: the capture's negative control. PNGs (full window and the cropped viewport)
and the log land in .bench/navmesh/maps/ (gitignored). Exits 1 if Studio fails, a scenario
fails, or the frames don't differ.

--tour takes a JSON list of camera stops ({"Tag", "From": [x, y, z], "To": [x, y, z]}, and
optionally "Start"/"Goal" points for the path probe, "Attributes" for Start, "Parts" for the
Parts' transparency; see Studio.luau). Studio prints a mark at each stop and this captures it as
<map>-<tag>.png (and -viewport.png), all in one session; the drawn/cleared pair is skipped.
"""
import argparse
import json
import shutil
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
\tMap = {view}(require(Maps.Maps["{map}"])),
\tHold = {hold},
\tTour = {tour},
\tDwell = {dwell},
\tBaked = Maps:FindFirstChild("Baked"),
}})
print("[MARK] done")
"""


def bake(name: str) -> Path | None:
    """A map with `Bake = true` is built and its scenarios run in Lune (bake.luau): Studio only
    builds its Parts and loads the mesh, so it stays under the 10-second "not responding" watchdog."""
    if "Bake = true" not in (HERE / "Maps" / f"{name}.luau").read_text(encoding="utf-8"):
        return None
    out = OUT / "Baked"
    shutil.rmtree(out, ignore_errors=True)
    result = subprocess.run(["lune", "run", str(HERE / "bake.luau"), name, str(out)], capture_output=True, text=True,
                            encoding="utf-8", errors="replace")
    print(result.stdout.strip())
    if not (out / "Mesh.txt").exists():
        sys.exit(f"bake failed:\n{result.stderr}")
    return out


def build_place(script: str, baked: Path | None = None) -> Path:
    OUT.mkdir(parents=True, exist_ok=True)
    lib = (Path.cwd() / "lib").as_posix()
    maps = {"$className": "Folder", "Maps": {"$path": (HERE / "Maps").as_posix()}}
    if baked:
        maps["Baked"] = {"$path": baked.resolve().as_posix()}
    for module in HERE.glob("*.luau"):  # Studio, Harness, Parts and shared map builders
        if module.stem not in ("run", "bake", "plan"):  # Lune-only
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


def lua(value) -> str:
    """A JSON value as a Luau literal."""
    if isinstance(value, dict):
        return "{ " + ", ".join(f"[{json.dumps(k)}] = {lua(v)}" for k, v in value.items()) + " }"
    if isinstance(value, list):
        return "{ " + ", ".join(lua(v) for v in value) + " }"
    if isinstance(value, bool):
        return "true" if value else "false"
    return json.dumps(value)


def tour(args, view: str) -> int:
    stops = json.loads(Path(args.tour).read_text(encoding="utf-8"))
    place = build_place(RUN.format(map=args.map, hold=args.hold, view=view, tour=lua(stops), dwell=args.dwell),
                        bake(args.map))
    proc = subprocess.Popen(["run-in-roblox", "--place", str(place), "--script", str(OUT / "run.luau")],
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, encoding="utf-8", errors="replace")
    lines, saved = [], []
    from PIL import Image
    for line in proc.stdout:
        lines.append(line)
        print(line, end="", flush=True)
        if "[MARK] drawn" in line:  # puts the window on the main monitor before the first stop
            capture(OUT / f"{args.map}-tour-start.png", 0).communicate(timeout=120)
        if "[MARK] view " in line:
            tag = line.split("[MARK] view ", 1)[1].strip()
            png = OUT / f"{args.map}-{tag}.png"
            out = capture(png, 0).communicate(timeout=120)[0].strip()
            print(out, flush=True)
            if "SAVED" in out:
                Image.open(png).crop(CROP).save(png.with_name(png.stem + "-viewport.png"))
                saved.append(tag)
    proc.wait(timeout=2 * args.hold + 600)
    text = "".join(lines)
    (OUT / f"{args.map}-tour.txt").write_text(text, encoding="utf-8")
    print(f"TOUR captured {len(saved)} of {len(stops)}: {', '.join(saved)}")
    return 0 if "MAP PASS" in text and len(saved) == len(stops) else 1


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("map", help="a module name in tools/navmesh/maps/Maps")
    ap.add_argument("--hold", type=int, default=30, help="seconds the drawing stays, then the cleared view")
    ap.add_argument("--settle", type=int, default=20, help="seconds after the window opens before the first capture")
    ap.add_argument("--view", help="camera override 'fx,fy,fz,tx,ty,tz' (eye, then target), for a close-up")
    ap.add_argument("--tag", help="suffix for the output files (one name per view)")
    ap.add_argument("--tour", help="a JSON file of camera stops, each captured (see above)")
    ap.add_argument("--dwell", type=int, default=6, help="seconds at each tour stop")
    args = ap.parse_args()

    view = ""
    if args.view:
        f = [float(v) for v in args.view.split(",")]
        view = (f"(function(m) local c = table.clone(m) c.View = {{ From = {{ {f[0]}, {f[1]}, {f[2]} }}, "
                f"To = {{ {f[3]}, {f[4]}, {f[5]} }} }} return c end)")
    name = args.map + (f"-{args.tag}" if args.tag else "")
    if args.tour:
        return tour(args, view)
    place = build_place(RUN.format(map=args.map, hold=args.hold, view=view, tour="nil", dwell=args.dwell), bake(args.map))
    drawn, cleared = OUT / f"{name}.png", OUT / f"{name}-cleared.png"
    captures = [capture(drawn, args.settle), capture(cleared, args.settle + args.hold)]
    result = subprocess.run(["run-in-roblox", "--place", str(place), "--script", str(OUT / "run.luau")],
                            capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=2 * args.hold + 300)
    text = result.stdout + result.stderr
    (OUT / f"{name}.txt").write_text(text, encoding="utf-8")
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
