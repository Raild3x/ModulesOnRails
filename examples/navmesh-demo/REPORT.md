# NavMesh dogfood report

I built the game in this folder (see README.md) as a first-time user. I started from `NavMesh.luau`, `Types.luau`, `CONTEXT.md`, `NavMeshEditor.luau` and `DrawListRenderer.luau`, and read `spec.md` only afterwards. The game is 7 NPCs on a two-floor level with a timed door, a toggled jump link and a mud area. It runs headless under Lune and as a Studio place, and I checked the Studio place from screenshots. Every claim below has a script in this folder that reproduces it:

- `repros.luau`: bugs and surprises;
- `mistakes.luau`: error messages;
- `bench.luau`: costs;
- `sim.luau`: gameplay tallies.

## Summary

- **The core is solid and fast.** Queries cost microseconds, error messages are very good, and multi-floor paths with seams, one-way labelled links, `AreaCosts`, `Partial`, `Serialize` and `Deserialize` all worked on the first try.
- **One real correctness bug.** `AgentRadius` is dropped where a path crosses a seam at a wall corner. The path goes through the corner point itself (repro 1). My big NPCs graze the ramp corner in the demo.
- **One real performance problem.** `Update` rebuilds the whole mesh state, not just the dirty tiles. It costs 10-23 ms for a single 4x4 crate on a 256-stud map, and changing `TileSize` doesn't help. That rules out frequent doors or crates on real maps at 60 fps.
- **The biggest usability gap is between `FindPath` and a moving NPC.** I hand-rolled about 150 of `Game.luau`'s 487 lines: path following, arrival tolerance, link traversal, stuck detection, rescuing an NPC a door closed on, radius-aware random points, and revalidation polling. Every game will write this, and several of the traps are subtle. The arrival trap, for example, left NPCs stuck in a repath loop until I found it.
- **`IsPathValid` is too coarse to be useful at the default `TileSize`.** One door toggle invalidated 199 of 200 unrelated paths, so every NPC repaths on every toggle.

## Pain points, by severity

### 1. Bug: `AgentRadius` is dropped at a seam's wall corner (high)

Repro 1 builds a ramp whose footprint is cut out of Ground, with a seam at its foot. The wall along the ramp's side starts at the seam's end point `(10, 0, 8)`:

```lua
Ground = { Walkable = { rect(0, 0, 0, 30, 20) }, Obstacles = { rect(0, 10, 8, 20, 12) } },
Ramp = { Walkable = { { v(10, 0, 8), v(20, 5, 8), v(20, 5, 12), v(10, 0, 12) } } },
...
NavMesh.FindPath(mesh, v(2, 0, 2), v(25, 5, 10), { AgentRadius = 1.5 })
-- waypoints (2,0,2) (10,0,8) (16,3,9.5) (25,5,10): straight through the corner, wall distance 0.00
-- control, same corner with no seam: tangent waypoint (21.17,0,7.06), wall distance 1.21
```

- **What happens:** the corner (a wall corner, so SR4 says it gets an offset) is used as a raw waypoint for every radius. In the demo level the same corner at `(20, 0, 34)` gives a radius-1.5 path 0.57 studs of clearance and a radius-0.5 path 0.20 studs.
- **Visible:** in `screenshot-editor.png` the pink radius-1.5 path touches the ramp's corner.
- **Expected:** the tangent offset, as on a flat crate corner.
- **Fix:** in `Funnel`, treat a portal endpoint that is a wall vertex on either floor of a seam as a corner to offset. The seam portal's end vertex currently seems to be exempt as "free space".

### 2. `Update` is O(whole mesh), not O(dirty tiles) (high)

`bench.luau` adds or removes one 4x4 crate in the middle of each map and takes the median of 21 `Update` calls. The measurements (Lune; the machine was loaded, so treat them as ±30%):

| Map | Triangles | Update ms, no `MaxAgentRadius` | Update ms, `MaxAgentRadius` 2 |
|---|---|---|---|
| demo level (60 x 40) | 48 | 1.4 | 1.4 |
| props (64 x 64) | 3145 | 22.9 | 18.0 |
| bench (256 x 256) | 4613 | 22.4 | 15.2 |
| terrain (1024 x 1024) | 1305 | 13.9 | 9.6 |
| walls (256 x 256) | 700 | 16.7 | 9.9 |

The 256-stud "bench" map with `MaxAgentRadius` 2, sweeping `TileSize`:

| TileSize | 64 | 32 (default) | 16 | 8 |
|---|---|---|---|---|
| Update ms | 24.1 | 14.9 | 16.4 | 24.7 |

`TileSize` barely matters, which means the cost isn't in the dirty tiles. Reading `Tiles.luau`'s `apply` explains it. For atomicity it builds a fresh `Storage.New()` and does all of this on every call:

- copies every clean tile's triangles through `CopyOut`, allocating per-triangle tables;
- walks every triangle of the floor to collect heights;
- re-snaps every link;
- re-runs `Connect`;
- loops over `remap` (all triangles) once per changed obstacle box.

- **Expected:** "rebuilding only the tiles they touch" (the `Update` doc) at the cost the spec measured, 0.61 ms for a local re-snap.
- **Fix:** keep the fresh-state commit for the dirty ranges only. Build them into scratch and swap them in place (the SR14 range allocator already supports that), and keep a per-floor height map instead of rescanning triangles.
- **Also:** the "no cap" default for `MaxAgentRadius` costs 30-50% more on every `Update`. The docs don't say so, so a game dev would never know to set it. Suggest making it required, or defaulting it to a small value.

### 3. There is no path follower, and a naive follower gets stuck (high, usability)

`FindPath` returns waypoints and `MoveAlongSurface` moves a point. Joining the two took most of `Game.luau`'s `follow` function, and three traps took me a debugging session each:

- **Waypoints that the follower can never reach.**
  - A goal, and the end of a `Partial` or `Budget` path, is not offset by `AgentRadius`. `Partial` often ends exactly on a wall or in a corner, such as the door face `(41, 0, 18.8)` or the balcony corner `(52, 6, 34)`.
  - `MoveAlongSurface` keeps the agent `AgentRadius` off the wall, so it stops 0.5 (or 0.71 in a corner) short.
  - A follower that waits for "within one step" never arrives. It then re-requests the same `Partial` path forever: my first sim had NPCs doing that every 0.77 s.
  - Workaround:

```lua
-- HAND-ROLLED: waypoints (the goal, a Partial path's end) can sit closer to a wall than the
-- radius, and MoveAlongSurface keeps us AgentRadius off it, so "arrived" needs a tolerance.
if progress < 0.1 * step and remaining <= npc.Radius * math.sqrt(2) + 0.05 then -- sqrt 2: a corner
```

- **`MoveAlongSurface` is not radius-aware along the way.** Only the end point is pushed off walls (repro 2). A radius-1.5 agent walks straight through a 2-stud gap that `FindPath` reports as `Partial` for that radius. That's fine when you follow a correct path, but it can't be used as a steering primitive on its own. The chaser's direct-chase mode, which relies on `Raycast` plus `MoveAlongSurface`, clips corners that are too narrow for it.
- **Links need special handling.** `Label` sits on the waypoint where the link starts, and the next waypoint is the landing. The follower has to notice this and must not walk that segment with `MoveAlongSurface`, because that would walk off the balcony edge and stop. It isn't stated anywhere that walking a link segment fails, and the waypoint carries no link id.

**Suggestion:** a small, optional stateful follower in the library. For example, `NavMesh.Advance(mesh, path, cursor, position, maxStep, filter) -> (position, floor, cursor, event)`. Its event would be `"Arrived" | "Link"(label, from, to) | "Blocked"`, and arrival would treat the radius-pushed stop as reached. Failing that, return path end points already offset by the radius, and document the arrival rule.

### 4. `IsPathValid` invalidates almost everything (medium-high)

The demo level has 3 tiles at the default `TileSize` (one per floor). From `bench.luau`, 200 random paths and one door close:

| TileSize | default | 32 | 16 | 8 | 4 |
|---|---|---|---|---|---|
| Paths invalidated | 199/200 | 153 | 128 | 139 | 106 |
| Update ms | 1.4 | 1.1 | 0.95 | 1.5 | 2.8 |

In the 120 s sim, the 19 door toggles caused 119 repaths, which is every NPC every time. Repro 6: a 6-stud path 38 studs from the door is invalid after the door closes.

The per-tile conservatism is documented. The problem is that the default `TileSize` is sized for build speed, not for invalidation, and nothing tells the game where the change happened. Even at `TileSize` 4, half the paths are invalidated, because clearance reach bumps neighbouring tiles.

**Suggestions:**
- have `Update` return the changed boxes (or tile ids), so a game can test its own paths;
- give `IsPathValid` an exact mode that checks the path's corridor triangles against the changed boxes;
- or fire a `Changed` signal. Today I poll every path after every change (`revalidate` in `Game.luau`).

### 5. `FindRandomPoint` ignores `AgentRadius` (medium)

Repro 3: with `{ AgentRadius = 2 }` on a 10 x 10 floor, 652 of 1000 points are closer than 2 studs to a wall. `FindPath` to such a point still returns `Success`, ending 0.2 studs from the wall. For wandering NPCs this means goals they can't stand at, which feeds straight into trap 3.

- **Workaround:** a rejection loop using `FindDistanceToWall` (`pickWanderGoal`). In the sim it rejected 25 of 210 draws, and the big NPCs' rejections were 11 of about 60.
- **Fix:** sample only triangles whose clearance admits the radius, and push the sample off walls, or document it loudly.

### 6. `Vector3` in the types, `vector` at runtime (medium)

Every public type says `Vector3`, but the library works on `vector` and returns `vector`. Code meant to run under both Lune and Roblox has to use `vector.create`, and then strict mode rejects it. With the Roblox definitions, `luau-lsp analyze` on six lines of normal usage reports:

```
Expected this to be 'Vector3', but got 'vector'    (a walkable ring built with vector.create)
Expected this to be 'vector', but got 'Vector3'    (local feet: vector = path.Waypoints[1].Position)
```

- The library's own `Fixtures` gives up and types `Desc` as `any`. The library sources themselves also report "Key 'X' not found in external type 'vector'" under the same definitions.
- Under Lune, printing a waypoint gives `<vector>`.
- **Suggestion:** type the API as `vector`, which is what Roblox's `Vector3` is now at runtime, or as a `Vec3 = Vector3 | vector` alias. Document that Lune callers pass `vector.create`.

### 7. Off-mesh positions: five queries, five behaviours (medium)

Repro 5 closes a door on an agent standing in the doorway:

```
FindPath             -> NoStart
FindNearestPoint     -> nil (SnapExtents X/Z half-size 0.5)
Raycast              -> blocked=true, stop=from
FindDistanceToWall   -> 0
MoveAlongSurface     -> error "from is not on the mesh (snap it with FindNearestPoint first)"
```

So a follower must `pcall` `MoveAlongSurface`, and it must know to retry `FindNearestPoint` with a bigger `SnapExtents` to rescue the NPC (see `repath` in `Game.luau`).

Something similar happens when a moving target is mid-jump: the goal is more than 4 studs above the floor, so the chaser gets `NoGoal`.

**Suggestions:**
- one documented policy for off-mesh input: return a status rather than throw;
- a `FindNearestPoint` with a search radius ("closest point, however far");
- a `FindPath` option to snap the goal to the closest reachable point instead of returning `NoGoal`.

### 8. Waypoints skip slope changes and floor changes (medium)

A path up the ramp onto the balcony is `(19.5, 0, 34.1) Ground -> (45, 6, 37) Balcony`, with no point at the top of the ramp. Repro 7 shows the effect. On the straight 3D segment between two waypoints, the point just before the ramp top is at y 1.93 while the surface is at 4.9. `FindNearestPoint` then snaps that point to the floor *under* the overhang.

- **Consequences:**
  - interpolating `Y` between waypoints (what a tween or `Humanoid:MoveTo` does) is wrong;
  - my first clearance audit read "distance 0" there for exactly this reason;
  - `Floor` also changes between waypoints with no marker for where.
- **Workaround:** walk every segment with `MoveAlongSurface`. That is correct but costs one query per step.
- **Fix:** emit a waypoint where the path crosses a seam or a crease, or add a `SamplePath(path, spacing)` helper.

### 9. Path shape surprises (medium-low)

- **Area boundaries add bends even when all costs are 1** (repro 4). On an open floor with a mud patch, `(31, 0, 20) -> (19, 0, 33)` bends at the patch corner `(30, 0, 26)`. The path is 19.12 studs, against 17.69 with the patch removed (+8%). The search runs on edge midpoints (spec "Search nodes"), so the extra constrained edges steer the corridor. Suggest a final `Raycast`-style shortcut pass when both ends lie in areas of equal cost.
- **Corner clearance is a chord, not the radius.** At flat corners a radius-1.5 path measured 1.13, 1.20 and 1.21 studs from the wall (my clearance audit walks each path in 0.05-stud steps). SR4 in the spec explains that offsets apply only at corners, but the `QueryFilter.AgentRadius` doc says "paths keep this far from walls". Either add the arc's midpoint as a waypoint on sharp turns, or state the chord limit in the doc.
- **`PathResult.Cost` isn't the path length.** It was `102.67` for both the radius-0.5 and the radius-1.5 path in the demo, although their geometry differs. It is documented as the search cost, but a game wanting "distance to target" has to sum the waypoints itself.

### 10. Removed obstacles are never freed (medium-low)

Obstacle ids are "never reused", and the records stay forever too. Repro 8 toggles a door:

| Door toggles | 10 | 1000 | 4000 |
|---|---|---|---|
| Update ms | 0.64 | 1.36 | 4.01 |
| Serialize bytes | 1,367 | 23,642 | 91,142 |

A door every 6 s reaches 4000 toggles in under 7 hours of server uptime. Suggest dropping `Removed` records on commit, since the id counter can stay monotonic without keeping the rows.

### 11. Docs: stale in places, and I needed the spec (low-medium)

- **Stale text:**
  - the class doc says "See `docs/plans/navmesh/spec.md` for the full API; it lands ticket by ticket";
  - `IsPathValid` says "(or, later, an `Update`)";
  - `Waypoint.Label` says "(ticket 16)".
- **No worked example:** `Build` has no example description. The only examples are the `@private` `Fixtures`, whose `flat`/`points` helpers aren't exported, so every user writes their own `rect`.
- **Things I only learned from the spec:**
  - radius offsets apply only at wall corners (SR4), which explains the chord clearance and `MoveAlongSurface` in the gap;
  - search nodes sit at edge midpoints, which explains `Cost` and the extra bends;
  - a zero-cost link turns the heuristic into Dijkstra's algorithm for the whole mesh (SR7);
  - crowd avoidance, async search and exposing the corridor are out of scope. I spent time looking for avoidance, and my NPCs overlap each other: Big1 and Big2 in `screenshot-oblique.png`.
- **Ramps need three pieces of authoring, and only the fixtures show it.** A solid ramp is its own floor, plus two seams, plus an obstacle cut into Ground under it.

### 12. Authoring cost, and the missing Part to polygon adapter (low-medium)

- **Verbose but readable.** The level is 81 lines. `mistakes.luau` shows that the errors are excellent (see "What worked well").
- **Silent mistakes:**
  - `Walkable = ring` (a ring instead of a list of rings) reports "walkable ring 1: a ring needs at least 3 points", which is misleading;
  - a misspelled filter key (`AgentRaduis`) passes both at runtime and in `luau-lsp`;
  - `AddObstacle` without `Update` quietly keeps pathing through the wall. That is by design, but a `HasPendingChanges(mesh)` or a debug warning would help.
- **The adapter hurts more than the spec suggests.** I described the level twice: as polygons for NavMesh, and as Parts for Studio. `StudioDemo.buildLevel` derives the Parts from the polygons by list index (index 7 is "the ramp footprint, skip it"), and the ramp Part needs hand trigonometry. A real game goes the other way (Parts first), so without an adapter the level designer must keep two sources in sync by hand. Even a minimal adapter for anchored axis-aligned blocks and wedges would remove most of this.

### 13. Debug drawing (low)

- `DrawListRenderer` lives in `constraineddelaunaydebug`, not `navmeshdebug`, so it isn't discoverable from NavMesh.
- `ToDrawList` draws one path. I build my own `Line` primitives for seven paths (`pathList`).
- `Draw` replaces everything, so I need a second renderer to redraw paths without rebuilding the mesh fills.
- There are no colour options:
  - area 1 is `#9e9e9e` at 0.6 transparency, and walls are `#212121`, so both vanish on a typical grey or dark baseplate;
  - on my dark ground the area fills are barely visible, although 4 fill `MeshPart`s were created;
  - disabled links are drawn the same as enabled ones.
- Wireframes are `AlwaysOnTop`, so triangle outlines and paths show through walls and crates. That helps debugging but makes the demo shot noisy.
- Tile bounds are drawn at y 0, not at the floor's height.

### 14. Shipping a bake (low)

`Serialize` is compact (7 KB for the demo), but nothing says how to get a buffer into a place. I wrote it as a `\xNN` string literal in a ModuleScript (`bake.luau`), which is 4x the size (28 KB). The 256-stud bench map bakes to 581 KB, so 2.3 MB of source that way. A documented recipe would help: base64 plus `EncodingService`, or a `StringValue`, with chunking guidance.

### 15. Smaller API notes

- `SetLinkEnabled(mesh, 1, ...)` addresses links by their index in `Links`. A `Name` field, or a lookup by label, would survive edits to the level.
- `FindRandomPoint(mesh, filter, center, radius, rng)`: with five positional arguments, a wander call is `FindRandomPoint(mesh, filter, pos, 30, rng)`. An options table would read better.
- The editor has no public way to place markers or set the radius from code. `EditorShot.luau` and my `studio.py editor` both call the private `_apply`. It also runs only in Play mode, has no area colouring, and has no "Build and save a bake" action.

## Features I wished for, by value to a game

1. **A path follower or agent helper:** advance, arrival tolerance, link events and stuck detection (pain point 3).
2. **A cheap, local `Update` plus precise invalidation:** changed boxes returned by `Update`, or an exact `IsPathValid` (pain points 2 and 4).
3. **A Part to polygon adapter** for blocks, wedges and cylinders, producing floors, seams and obstacles (pain point 12).
4. **Closest-reachable queries:** radius-aware `FindRandomPoint`, `FindNearestPoint` with a search radius, and goal fallback in `FindPath` (pain points 5 and 7).
5. **Waypoints at seams and creases**, or `SamplePath` (pain point 8).
6. **Named links, and the link id on the `Waypoint`** (pain point 15).
7. **Debug:** multi-path drawing, a palette option, link enabled state, and a NavMesh-side re-export of `DrawListRenderer`.
8. **Local avoidance or separation.** Out of scope per the spec, but it is the next thing any crowd needs.
9. **Time-sliced search.** Not needed at these sizes (0.2-0.8 ms on 256-1024 stud maps), so low.

## What worked well (keep it)

- **Error messages.** Specific and actionable, naming the floor, ring, point and coordinates:
  - `NavMesh.Build: floor 'Ground': walkable rings 1 and 2 overlap with different heights near (13.333, 13.333); split them into separate floors`
  - `NavMesh.Build: seam 1: floors 'A' and 'B' are at different heights along it near (20.000, 20.000)`
  - `NavMesh.Build: link 1: To (100.000, 0.000, 100.000) is not on the mesh`
  - `NavMesh.RemoveObstacle: obstacle 1 is already removed`
  - `NavMesh.Deserialize: the buffer is truncated or corrupt`
- **Query speed.** Seven NPCs cost 0.05-0.16 ms per frame in total. None of the per-frame queries is a concern.
- **Multi-floor paths.** Ramp, balcony and one-way link worked the first time, including `Floor` on each waypoint. `Label = "Jump"` arrived on the right waypoint.
- **`Partial` is well chosen.** It returns the reachable point nearest the goal *in 3D*: with the jump disabled, it stops on the balcony edge above a goal in the east room.
- **`AreaCosts` is intuitive.** The mud at cost 4 was avoided unless the detour was long.
- **`Budget`** returns a usable prefix: `MaxExpansions = 3` gave 2 waypoints.
- **The pending-until-`Update` model** is simple, `Update` is atomic, and obstacles can be added to a deserialized mesh.
- **`Serialize` and `Deserialize`** are tiny and fast: 7 KB, 0.13-0.26 ms to load.
- **Plain-data mesh state, and an injectable `rng`** that makes the sim reproducible.
- **`NavMeshEditor`** loaded my description unchanged and showed a live radius path immediately. That is how I spotted bug 1 visually.

## Measured timings

All times are in ms. The machine was busy (a mutation gate was running), and runs varied by up to 2x, so each cell gives the range over runs.

The sim runs 120 s of game time at 30 Hz with 7 NPCs, on the demo level at the default `TileSize` (3 tiles):

| Call | Count | Lune mean | Lune p95 | Studio edit-mode mean | Studio p95 |
|---|---|---|---|---|---|
| `FindPath` | 498 | 0.020-0.039 | 0.035-0.066 | 0.049 | 0.083 |
| `MoveAlongSurface` (per step) | 24,778 | 0.007-0.012 | 0.010-0.019 | 0.016 | 0.044 |
| `Raycast` | 446 | 0.006-0.011 | 0.009-0.016 | 0.014 | 0.019 |
| `FindRandomPoint` | 210 | 0.013-0.025 | 0.016-0.032 | 0.025 | 0.029 |
| `FindDistanceToWall` | 210 | 0.006-0.011 | 0.009-0.016 | 0.010 | 0.013 |
| `IsPathValid` | 180 | 0.0002-0.0005 | 0.001 | 0.001 | 0.004 |
| `SetLinkEnabled` | 7 | 0.002-0.003 | | 0.008 | |
| `Update` (a door toggle) | 19 | 1.3-2.3 | 1.6-2.9 | 2.05 | 2.52 |
| Whole frame (7 NPCs) | 3600 | 0.06-0.11 | 0.09-0.17 | 0.158 | 0.247 |

- The Studio column comes from the 40 s run: `studio.py shot`, edit mode, and fewer calls than the Lune run.
- The demo level:
  - Build: 2.2-4.0 ms;
  - Serialize: 0.08-0.15 ms;
  - Deserialize: 0.13-0.26 ms;
  - bake: 6,916 bytes;
  - first mesh `Draw` in Studio: 0.5-1.0 ms;
  - redraw after a door toggle: 0.45-0.8 ms.
- The bigger maps (`bench.luau`, Lune, default `TileSize`):

| Map | Build ms (no cap / cap 2) | Bake bytes | FindPath r=0 | FindPath r=1 | MoveAlongSurface |
|---|---|---|---|---|---|
| props, 64 studs, 3145 tris | 716 / 468 | 381,189 | 0.44 | 0.012 (Partial at once) | 0.012 |
| bench, 256 studs, 4613 tris | 595 / 213 | 581,385 | 0.67 | 0.78 | 0.009 |
| terrain, 1024 studs, 1305 tris | 232 / 51 | 182,689 | 0.21 | 0.28 | 0.009 |
| walls, 256 studs, 700 tris | 146 / 67 | 148,165 | 0.14 (Partial) | 0.08 | 0.002 |

The `Update` columns for these maps are in pain point 2.

## Bugs, with minimal repros

Everything is in `repros.luau` (`lune run examples/navmesh-demo/repros.luau`):

1. **The radius is dropped at a seam's wall corner.** The path goes through `(10, 0, 8)` at r = 1.5 with wall distance 0.00. The control flat corner gives 1.21 (repro 1).
2. **`Update` scales with the whole mesh.** A 4x4 crate costs 10-24 ms on 700-4600 triangle maps whatever the `TileSize`. See `bench.luau` and the code pointer in pain point 2.
3. **Removed obstacle records leak.** After 4000 toggles, `Update` takes 0.64 -> 4.0 ms and the bake grows from 1.4 KB to 91 KB (repro 8).
4. **`FindRandomPoint` ignores `AgentRadius`** (repro 3). It may be by design, but the doc says "over the areas the filter allows".

These are by-design behaviours worth documenting or changing:

- `MoveAlongSurface` squeezes through a gap narrower than the radius (repro 2);
- equal-cost area boundaries bend paths (repro 4);
- off-mesh inputs are handled inconsistently (repro 5);
- per-tile invalidation hits everything on a small level (repro 6);
- waypoints skip slope changes (repro 7).

## Screenshots

- `screenshot-oblique.png`: the Studio place mid-run, looking north.
  - It shows the dark courtyard with the mesh wireframe, the brown mud strip, the crates, the 10-stud wall with the open door gap, the ramp and balcony in front, and the seam lines in cyan.
  - It also shows the purple jump arrow on the balcony and each NPC's remaining path in its own colour, with a goal circle.
  - Big1 and Big2 overlap, since there is no avoidance, and Small3 is at the ramp's bottom corner, where bug 1 lives.
- `screenshot-editor.png`: `NavMeshEditor` on the same description, with a radius-1.5 path from the start marker to the balcony. The path touches the ramp corner (bug 1).
