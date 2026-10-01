# 33: Map scenario harness

**What to build:** A way to build a Part-based test map, run named pathfinding scenarios on it,
and see pass/fail, numbers and a picture.
- It runs headless under Lune through the Part adapter, the way the adapter's own specs build
  Parts.
- It renders in Studio for screenshots.
- Every complex-map ticket (34-38) adds a map and scenarios to it.

**Blocked by:** None (can start immediately).

**Status:** done (2026-10-01, Track M1, branch `navmesh-maps-urban`), merged into `feat/navmesh`.

- [x] **Map definition:** a map is a function that creates Parts (walkable, obstacles, areas
      through `NavArea`, links) and returns them with named points (spawns, goals).
- [x] **Scenario definition:** a start point, a goal point, a filter (radius, area costs and
      so on), and expectations, each optional:
  - the path status;
  - the floors visited, in order;
  - the link labels used;
  - the area ids avoided;
  - a length bound, relative to the straight line or a reference path.
- [x] **Runner:** builds the map through the adapter, then `NavMesh.Build`, then runs every
      scenario.
  - It prints a table: scenario, pass/fail, the expectation that failed, path length and
    `FindPath` time.
  - It also prints Build ms, triangle, floor and seam counts, and bake bytes.
- [x] **Studio:** a command builds the same map as a place, draws the mesh and every
      scenario's path, and captures a PrintWindow screenshot.
- [x] **Tracer map:** a flat lot with one crate, and one scenario that must route around it.
- [x] **Negative control:** a scenario with a deliberately wrong expectation fails, and the
      runner reports which expectation failed.
- [x] The harness and its tracer map run in the navmesh spec run, or one command beside it,
      so later maps become regression checks.

## As-built (2026-10-01)

Everything lives in `tools/navmesh/maps/`. No library code changed.

| File | What it is |
|---|---|
| `Harness.luau` | `Run(map, NavMesh, Adapter, rbx, parent?)` returns a report; `Format(report)` prints it. Uses no Lune or Studio library, so both sides share it. |
| `Parts.luau` | `Parts(rbx, parent?)` returns `part`, `box` and `slab` makers (anchored, coloured). |
| `Maps/<Name>.luau` | One map per file: its Parts **and** its scenarios. |
| `run.luau` | The Lune runner. |
| `Studio.luau`, `studio.py` | The Studio screenshot. |

### Conventions for tickets 34-38 (M1, M2, M3)
- **Where maps live:** add `tools/navmesh/maps/Maps/<Name>.luau`. The runner picks up every file
  in that folder, so a new map is a regression check from the moment it lands.
- **A map module** returns:
  - `Name`;
  - `Build(rbx, parent?)`, which makes Parts with `Parts(rbx, parent)` and returns
    `{ Walkable, Obstacles, Points, Links? }`. `rbx` is `@lune/roblox` in Lune, Studio's globals
    in Studio. `Points` are named `rbx.Vector3`s. `Links` is a NavMesh `LinkDesc` list, added to
    the adapter's description;
  - `Scenarios`, a list (below);
  - optional: `MaxAgentRadius` (default 2), `AdapterOptions` (passed to `FromParts`), and
    `View = { From = {x, y, z}, To = {x, y, z} }` for the Studio camera (default: straight
    down, framed on the walkable Parts), and `SeeThrough = { "PartName", ... }`, Parts Studio
    draws at 0.75 transparency (an upper floor over a stair).
- **Shared builders:** a map used by several map files lives at the top of
  `tools/navmesh/maps/` (ticket 34's `Building.luau` and `BuildingPoints.luau`). studio.py
  mounts every top-level `.luau` there except `run.luau`.
- **A scenario** is `{ Name, From, To, Filter?, Expect?, MustFail? }`. `From` and `To` are point
  names; `Filter` is the `QueryFilter`. Every `Expect` field is optional:
  - `Status`: the `PathStatus`;
  - `Floors`: the floors visited, in order, with repeats collapsed;
  - `Visits`: floors that must appear in this order, among others. Added in ticket 34: with
    riser strips, a stair's floor list holds every riser;
  - `Links`: the labels of the links used, in order;
  - `Avoids`: area ids no walked segment may enter. A segment along an area's edge doesn't
    count; a link's hop isn't checked. The check samples every 0.25 studs;
  - `MaxStretch`: `Length` at most this many times the straight line From-To;
  - `MinLength` / `MaxLength`, in studs. For a reference path, run it once and use its length
    plus slack.
- **Negative controls:** `MustFail = "<Expect field>"` makes a scenario pass only if exactly that
  expectation fails. The table marks it `pass*` and still prints the failure text, so the
  runner's reporting is checked on every run. Give each new expectation-driven behaviour one.
- **Run command:** `lune run tools/navmesh/maps/run.luau [MapName ...]` from the repo root. It
  prints one table per map, then `ALL MAPS PASS` or `MAPS FAIL`, and exits 1 on any failure. It
  sits beside the spec run (`tools/navmesh/specs.luau`) rather than inside it: maps import the
  adapter, which the navmesh package's coverage copy can't reach.
- **Screenshot command:** `python tools/navmesh/maps/studio.py <MapName> [--hold 30]
  [--settle 20]`. (Raised from 20 and 12 in ticket 34, after a slow Studio load missed the
  drawn frame.) It needs `lib/navmesh`, `lib/navmeshadapter` and `lib/constraineddelaunaydebug`
  set up (link modules and `_Index`). It draws the mesh (seams and links on) and each
  scenario's path in its own colour, holds, then clears the drawing. The camera is placed once
  and not locked, so the user can look around (ruled during ticket 34). It captures once while
  drawn and once after, and fails unless the two differ. Output lands in `.bench/navmesh/maps/`:
  `<Map>.png`, `<Map>-viewport.png` (cropped, for this machine's maximized layout) and
  `<Map>.txt` (the log, with the same table). Check the PNG with the Read tool.
  - Other sessions also use run-in-roblox's port 50312. If the log shows another game's output
    or the capture shows another window, wait until
    `netstat -ano | grep :50312 | grep LISTENING` is empty, then rerun.

### The tracer map, `FlatLot`
A 60 x 40 lot, a 6 x 6 crate in the middle, and a mud patch (`NavArea` 3) to the north.

| Scenario | Expect | Result |
|---|---|---|
| around the crate (radius 1) | Success, `{Ground}`, length >= 40.5, stretch <= 1.2 | pass, 40.8 |
| mud avoided when costly (cost 10) | Success, avoids area 3 | pass, 41.5 |
| control: wrong floor | `Floors = {Roof}`, `MustFail = "Floors"` | pass*: "Floors: got {Ground}, want {Roof}" |
| control: mud walked at cost 1 | avoids area 3, `MustFail = "Avoids"` | pass*: "Avoids: segment 1-2 enters area 3" |

- **Numbers:** FromParts 0.1 ms, Build 0.8 ms (1.6 ms in Studio); 16 triangles, 1 floor,
  0 seams; bake 1882 bytes; `FindPath` 0.01-0.02 ms (best of 3).
- **Negative controls, run by hand:** with the crate removed, "around the crate" fails
  (`MinLength: 40.0, want >= 40.5`), the map reports `MAP FAIL`, and the command exits 1.
- **Screenshot:** both routes bend round the crate's corner. The costly-mud route skirts the
  patch's edge, and the cost-1 control cuts straight through it. The two frames differ in 8.4%
  of pixels.
