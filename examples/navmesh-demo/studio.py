"""Studio runs of the NavMesh demo. Run from the repo root after
`npm run setup navmesh`, `npm run setup navmeshdebug` and `npm run setup constraineddelaunaydebug`,
and after `lune run examples/navmesh-demo/bake.luau`.

    python examples/navmesh-demo/studio.py shot [--view oblique|top] [--seconds 25]
    python examples/navmesh-demo/studio.py editor           # NavMeshEditor on the demo level
    python examples/navmesh-demo/studio.py play             # builds a place; press Play (F5)

`shot` runs the demo in edit mode with run-in-roblox for --seconds, captures the Studio window
(capture_window.ps1: PrintWindow, so only Studio's own pixels are saved) near the end, and prints the demo's log and timings. Output
lands in .bench/navmesh-demo/ (gitignored).
"""
import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
CAPTURE = HERE / "capture_window.ps1"  # PrintWindow: only Studio's own pixels, never a window on top
OUT = Path(".bench/navmesh-demo")

PRELUDE = """local ReplicatedStorage = game:GetService("ReplicatedStorage")
local src = ReplicatedStorage:WaitForChild("src", 10)
local Demo = ReplicatedStorage:WaitForChild("Demo", 10)
local NavMesh = require(src.navmesh.src.NavMesh)
local Renderer = require(src.constraineddelaunaydebug.src.DrawListRenderer)
"""

RUN = PRELUDE + """print("[MARK] start")
require(Demo.StudioDemo)({{
\tNavMesh = NavMesh, Renderer = Renderer, Game = require(Demo.Game), Level = require(Demo.Level),
\tBaked = require(Demo.Baked), Seconds = {seconds}, Camera = {camera},
}})
print("[MARK] done")
"""

EDITOR = PRELUDE + """print("[MARK] start")
local NavMeshEditor = require(src.navmeshdebug.src.NavMeshEditor)
local Level = require(Demo.Level)
local editor = NavMeshEditor.new(workspace, "NavMesh", Level.Desc)
-- There is no public way to place the markers or set the radius from code: use the private
-- _apply, as tools/navmesh/studio/EditorShot.luau does.
editor:_apply {{ Type = "SetMarker", Which = "Start", Position = Vector3.new(5, 0, 5) }}
editor:_apply {{ Type = "SetMarker", Which = "Goal", Position = Vector3.new(45, 6, 37) }}
editor:_apply {{ Type = "SetAgentRadius", Radius = 1.5 }}
print("[MARK] path " .. tostring(editor._pathStatus) .. " error " .. tostring(editor._error))
local gui = workspace:FindFirstChild("NavMeshEditor", true)
local screen = gui and gui:FindFirstChildOfClass("ScreenGui")
if screen then screen.Parent = game:GetService("StarterGui") end
local camera = workspace.CurrentCamera
camera.CameraType = Enum.CameraType.Scriptable
camera.FieldOfView = 50
camera.CFrame = CFrame.lookAt(Vector3.new(30, 46, -24), Vector3.new(30, 0, 22))
local deadline = os.clock() + {seconds}
while os.clock() < deadline do task.wait(0.5) end
editor:Destroy()
if screen then screen:Destroy() end
print("[MARK] done")
"""

SESSION = PRELUDE + """-- Play mode: the whole demo runs on the client (DrawListRenderer fills do not replicate).
require(Demo.StudioDemo)({
\tNavMesh = NavMesh, Renderer = Renderer, Game = require(Demo.Game), Level = require(Demo.Level),
\tBaked = require(Demo.Baked), Seconds = math.huge, Camera = nil,
})
"""


def run(cmd, **kw):
    print("$", " ".join(str(c) for c in cmd), flush=True)
    return subprocess.run(cmd, **kw)


def build_place(script: str, extra: dict | None = None, name: str = "demo") -> Path:
    OUT.mkdir(parents=True, exist_ok=True)
    lib = (Path.cwd() / "lib").as_posix()
    demo = {"$className": "Folder"}
    for module in ("StudioDemo", "Game", "Level", "Baked"):
        demo[module] = {"$path": (HERE / f"{module}.luau").as_posix()}
    src = {"$className": "Folder"}
    for pkg in ("constraineddelaunay", "constraineddelaunaydebug", "navmesh", "navmeshdebug"):
        src[pkg] = {"$path": f"{lib}/{pkg}"}
    tree = {"$className": "DataModel", "ReplicatedStorage": {"$className": "ReplicatedStorage", "src": src, "Demo": demo}}
    tree.update(extra or {})
    (OUT / f"{name}.project.json").write_text(json.dumps({"name": "navmesh-demo", "tree": tree}, indent=2), encoding="utf-8")
    (OUT / "run.luau").write_text(script, encoding="utf-8")
    place = OUT / f"{name}.rbxl"
    run(["rojo", "build", str(OUT / f"{name}.project.json"), "-o", str(place)], check=True)
    return place


def studio_with_capture(place: Path, png: Path, seconds: int, settle: int) -> int:
    capture = subprocess.Popen(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(CAPTURE),
                                "-OutPath", str(png.resolve()), "-SettleSec", str(settle)], stdout=subprocess.PIPE, text=True)
    result = run(["run-in-roblox", "--place", str(place), "--script", str(OUT / "run.luau")], capture_output=True,
                 text=True, encoding="utf-8", errors="replace", timeout=seconds + 300)
    text = result.stdout + result.stderr
    (OUT / f"{png.stem}.txt").write_text(text, encoding="utf-8")
    captured = capture.communicate(timeout=120)[0]
    print(text.strip())
    print(captured.strip())
    if "SAVED" in captured:
        # ponytail: fixed viewport box for this machine's Studio layout; adjust --crop if yours differs
        from PIL import Image
        box = tuple(int(v) for v in CROP.split(","))
        Image.open(png).crop(box).save(png.with_name(png.stem + "-viewport.png"))
        print(f"CROPPED {png.with_name(png.stem + '-viewport.png')}")
    return 0 if "[MARK] done" in text and "SAVED" in captured else 1


CROP = "10,175,955,840"  # left, top, right, bottom of the 3D viewport in the Studio capture


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="command", required=True)
    s = sub.add_parser("shot")
    s.add_argument("--view", choices=["oblique", "top"], default="oblique")
    s.add_argument("--seconds", type=int, default=25)
    s.add_argument("--settle", type=int, default=18, help="seconds after the window opens before the capture")
    e = sub.add_parser("editor")
    e.add_argument("--seconds", type=int, default=16)
    e.add_argument("--settle", type=int, default=8)
    p = sub.add_parser("play")
    p.add_argument("--no-open", action="store_true")
    args = ap.parse_args()

    if args.command == "shot":
        place = build_place(RUN.format(seconds=args.seconds, camera=f'"{args.view}"'))
        return studio_with_capture(place, OUT / f"shot-{args.view}.png", args.seconds, args.settle)
    if args.command == "editor":
        place = build_place(EDITOR.format(seconds=args.seconds))
        return studio_with_capture(place, OUT / "editor.png", args.seconds, args.settle)
    session = OUT / "session" / "NavMeshDemo.client.luau"
    session.parent.mkdir(parents=True, exist_ok=True)
    session.write_text(SESSION, encoding="utf-8")
    extra = {"StarterPlayer": {"$className": "StarterPlayer", "StarterPlayerScripts": {
        "$className": "StarterPlayerScripts", "NavMeshDemo": {"$path": session.resolve().as_posix()}}}}
    place = build_place("", extra, "play")
    print(f"Built {place.resolve()}. Open it in Studio and press Play (F5).")
    if not args.no_open:
        os.startfile(place.resolve())  # noqa: S606 (Windows)
    return 0


if __name__ == "__main__":
    sys.exit(main())
