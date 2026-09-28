# NavMesh demo

A small game built on `lib/navmesh` to dogfood it. The findings are in [REPORT.md](REPORT.md).

The level is a 60 x 40 courtyard with crates, a mud patch (area 2), and a ramp up to a balcony. The balcony has a one-way "Jump" link down into an east room. A door into that room opens and closes every 6 s, and a gate on the balcony turns the jump link off and on every 15 s. Seven NPCs run on it:

| NPC | Radius | Behaviour |
|---|---|---|
| Runner | 0.5 | Patrols a loop: up the ramp, the jump, out through the door, across the mud. It is the chase target. |
| Chaser | 1.0 | Chases the Runner. Walks straight at it when `Raycast` says it can, otherwise repaths every 0.25 s once the Runner has moved 2 studs. |
| Small1-3 | 0.5 | Wander to random points. |
| Big1-2 | 1.5 | Wander to random points. They are too wide for the 2-stud gap between the crate pair. |

All of them use `AreaCosts = { [2] = 4 }`, so they cross the mud only when that is much shorter.

## Files

| File | What it is |
|---|---|
| `Level.luau` | The `NavMeshDesc` (floors, seams, link) plus the door footprint |
| `LevelParts.luau` | The same level as Parts; the Studio place builds its mesh from them with `NavMeshAdapter` |
| `adapter_check.luau` | Checks that the Parts give the same walkable region as `Level.luau` |
| `Game.luau` | All NPC logic, as pure Luau shared by Lune and Studio. Code marked `HAND-ROLLED` is what the library did not provide. |
| `bake.luau` | Build, then `Serialize`, into `Baked.luau` (a string literal of the buffer) |
| `sim.luau` | Headless run: `Deserialize` the bake, step N ticks, print events, tallies and timings |
| `bench.luau` | Costs at different `TileSize` values and on bigger maps |
| `mistakes.luau` | Authoring and query mistakes made on purpose, printing each error |
| `repros.luau` | Minimal repros for the bugs in REPORT.md |
| `StudioDemo.luau`, `studio.py`, `capture_window.ps1` | The Studio place and its screenshots |

## Run

From the repo root, after `npm run setup navmesh`, `npm run setup navmeshdebug` and `npm run setup constraineddelaunaydebug`:

```sh
lune run examples/navmesh-demo/bake.luau            # after any Level.luau change
lune run examples/navmesh-demo/adapter_check.luau   # after any Level.luau or LevelParts.luau change
lune run examples/navmesh-demo/sim.luau 3600 7      # ticks (30 Hz), seed; add --quiet to hide events
lune run examples/navmesh-demo/repros.luau
lune run examples/navmesh-demo/mistakes.luau
lune run examples/navmesh-demo/bench.luau           # takes about a minute

python examples/navmesh-demo/studio.py shot --view oblique   # or --view top; runs 25 s in edit mode
python examples/navmesh-demo/studio.py editor                # NavMeshEditor on the demo level
python examples/navmesh-demo/studio.py play                  # builds a place: press Play (F5)
```

`studio.py` writes its output to `.bench/navmesh-demo/` (gitignored). The capture script uses `PrintWindow`, so it saves only Studio's own window, even when another window is on top of it. The `-viewport.png` crop uses a fixed box fitted to one Studio layout. If your panels are arranged differently, change `CROP` in `studio.py`.

`screenshot-oblique.png` is a frame of the demo from the south, looking north. `screenshot-editor.png` shows `NavMeshEditor` open on the level with a radius-1.5 path.
