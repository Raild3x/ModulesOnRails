# NavMesh demo 2: the warehouse

The second dogfood game for `lib/navmesh`, built on the round-1 APIs (the Part adapter, the
follower, the reachable queries, `Update`'s changed regions, the bake recipe and the debug
drawing). The findings are in [REPORT.md](REPORT.md).

The level is a 400 x 240 warehouse, authored only as Parts (`LevelParts.luau`): three halls split
by two walls with three doorways each, a mezzanine 10 studs up with two ramps and four pillars, and
shelf rows with 3.5-stud aisles. Six doors open and shut every 5 s, staggered, and eight crates
(one on the mezzanine) slide back and forth in 2-stud hops, one hop per crate per second. That is
about 9 `Update`s a second. 36 agents run on it:

| Agents | Radius | Behaviour |
|---|---|---|
| Player | 0.5 | Runs to random points anywhere, at 12 studs/s. The chase target. |
| Chaser 1-24 | 0.5, 1, 1.5, 2 in turn | Chase the Player; replan once it is 6 studs from their path's goal, 4 replans per tick, round robin. |
| Wanderer 1-11 | 0.5, 1, 1.5, 2 in turn | Stroll to random points within 60 studs. |

After every `Update`, an agent replans when the rest of its path touches a changed region
(fattened by its radius), or when its path is `Partial` and a door has just opened.

## Files

| File | What it is |
|---|---|
| `LevelParts.luau` | The level as Parts (walkable, static obstacles, doors, crates), for Lune (`@lune/roblox`) and Studio |
| `Game.luau` | All agent logic, pure Luau, shared by Lune and Studio. Code between `glue:<what>` markers is what the library did not provide. |
| `BakeText.luau` | The bake-shipping recipe: base64 text in StringValues, decoded by `EncodingService` in Studio and by plain Luau under Lune |
| `bake.luau` | `FromParts`, `Build`, `Serialize`, then base64 into `NavMeshBake/1.txt`, ... |
| `sim.luau` | Headless run: load the bake, step N ticks, print counters and per-call timings |
| `bench.luau` | The REPORT's timing tables: a TileSize sweep and an agent-count sweep, interleaved over seeds |
| `invariants.luau` | Checks every agent every tick: on the mesh and at least its radius from a wall |
| `repros.luau` | One repro per pain point in REPORT.md |
| `StudioDemo.luau`, `studio.py` | The Studio run and its screenshots |

## Run

From the repo root. The adapter and the renderer need their sibling link modules: `npm run setup
navmesh navmeshadapter constraineddelaunaydebug` (or copy `_Index` and the `NavMesh.lua` /
`ConstrainedDelaunay.lua` links from a set-up checkout).

```sh
lune run examples/navmesh-demo2/bake.luau           # after any LevelParts.luau change
lune run examples/navmesh-demo2/sim.luau 1800 7     # ticks (30 Hz), seed, [agent scale]
lune run examples/navmesh-demo2/repros.luau
lune run examples/navmesh-demo2/invariants.luau     # about a minute
lune run examples/navmesh-demo2/bench.luau 900 3    # ticks, seeds; about 5 minutes

python examples/navmesh-demo2/studio.py shot --view top       # or oblique, door; 30 s in edit mode
```

`studio.py` runs the demo with run-in-roblox, captures the Studio window twice, 6 s apart, with
`tools/navmesh/studio/capture.ps1`, and fails unless the two frames differ. Its output, with
`-viewport.png` crops (a fixed box for one Studio layout: change `CROP`), lands in
`.bench/navmesh-demo2/` (gitignored).

## Screenshots

- `screenshot-top.png`: the whole warehouse from above. The mesh is drawn by floor, walls in white,
  shelf rows, crates, the mezzanine with its ramps, the agents (red Chasers, blue Wanderers; the
  1-stud green Player is a few pixels at this scale) and each agent's remaining path. The Chasers'
  red paths converge on the Player.
- `screenshot-mezzanine.png`: the mezzanine from the south, with the south ramp in front and the
  green Player at the left. Path and mesh lines under the deck show through it (the renderer's
  lines are `AlwaysOnTop`).
- `screenshot-door-shut.png` and `screenshot-door-open.png`: the east wall's middle door, 6 s
  apart in one run. Shut, it is opaque and the mesh outlines its footprint; open, it is faded and
  two Chasers go through it, overlapping (there is no avoidance).
