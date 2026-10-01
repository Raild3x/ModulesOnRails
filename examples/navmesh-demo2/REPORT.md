# NavMesh dogfood report 2: the warehouse

I built the game in this folder (see README.md) as a first-time user of the round-1 APIs. I started from `NavMesh.luau`, `Types.luau`, `CONTEXT.md` and `NavMeshAdapter.luau`, and copied the tooling of `examples/navmesh-demo`.

The game:
- a 400 x 240 warehouse on two floors, authored only as Parts;
- 36 agents of radius 0.5-2, 24 of them chasing a moving target;
- six doors and eight sliding crates, about 9 `Update`s a second.

It runs headless under Lune and in Studio, and I checked the Studio run from screenshots.

Every claim below has a script in this folder that reproduces it:

- `repros.luau`: repros 1-7, one per pain point;
- `bench.luau`: the timing tables (the TileSize sweep and the agent-count sweep);
- `sim.luau`: one game, with counters and per-call timings;
- `invariants.luau`: every agent on the mesh and clear of the walls, every tick;
- `studio.py`: the Studio timings and the screenshots.

Each item is marked **NEW** or **KNOWN**:
- **NEW:** not in `docs/plans/navmesh/handoffs/known-gaps.md`, tickets 25 or 28-30, or the first report.
- **KNOWN:** the item names where it is already recorded.

## Summary

- **Round 1 fixed most of the first report.** The follower, the reachable queries, the adapter and the bake recipe all worked on the first try.
  - Following a path is now 20 lines of glue instead of about 150.
  - In 64,800 agent-ticks no agent left the mesh or came closer to a wall than its radius (`invariants.luau`).
  - The level is authored once, as 42 Parts. The adapter found its 4 floors and 4 seams by itself in 1-2 ms.
- **The biggest problem: `Update`'s changed regions are too coarse to save replans.**
  - A 4 x 4 crate reports a 128 x 128 box, the whole rebuilt tile.
  - Replanning by region replans 10.8 agents per `Update`. The per-tile stamps it was meant to beat flag 10.6.
  - A box around each added footprint is enough to know a path is still walkable, and it flags 0.57: 19 times fewer.
- **Off-mesh and unreachable cases still need code at every call site.**
  - An agent a crate lands on gets `NoStart` from `FindPath`. There is `GoalFallback`, but no start fallback.
  - `FindRandomPoint` returns points behind a shut door: 99 of 200 in repro 3.
- **Dynamic Parts are left to the game.** The adapter converts a level once, so the game computes each door's and crate's footprint and floor by hand. `AddObstacle` with the wrong floor name silently cuts the floor below (repro 5).
- **Hand-rolled code is about 230 lines** (table in "Setup cost"). Demo 1 had about 150 lines of pure path-following glue. Most of the glue now goes to replanning after changes (53 lines) and to shipping the bake from Lune (65 lines).
- **Timings are fine for 36 agents:** 0.6 ms per tick at the median and 5.2 ms at p95, under Lune.
  - The tick p95 is mostly `Update` plus the replans it triggers.
  - TileSize 32 instead of the default cuts `Update` from 2.08 to 0.80 ms, and the p95 tick from 5.2 to 2.1 ms.
  - Nothing tells a user to make that change.

## Pain points, by severity

### 1. A `ChangedRegion` is the whole rebuilt tile, so region replanning saves nothing (high, NEW)

Repro 1 adds one 4 x 4 crate at (200, 20) on the warehouse bake:

```
region Ground (128, 0)-(256, 128), 128 x 128 studs
a path along z = 100, 78 studs from the crate, lies in that box; FindPath after the Update returns the same path: true
```

- **Why:**
  - The warehouse floor's default TileSize is 128, which is about 36 edges per tile.
  - The box covers every rebuilt tile and every triangle whose clearance was recomputed, because its contract is "`FindPath` would return the same path".
  - A retriangulated tile can change a path's shape, so the whole tile has to be in the box.
- **The cost**, from `bench.luau`. Each cell counts agents per `Update`, as the median [min-max] over 900 ticks x 3 seeds.
  - The first column is what the game replans by region.
  - The second is what `IsPathValid`'s stamps flag as stale.
  - The third is what a box around each added footprint, grown by the agent's radius, flags as blocked.

| TileSize | Replanned by region | Stale by stamps | Blocked by an added footprint |
|---|---|---|---|
| default (128) | 10.8 [10.6-13.0] | 10.6 [10.5-11.5] | 0.57 [0.41-0.66] |
| 64 | 5.4 [3.8-5.7] | 6.1 [4.0-6.3] | 0.61 [0.41-0.77] |
| 32 | 2.3 [1.8-2.5] | 2.8 [2.6-3.1] | 0.45 [0.41-0.55] |
| 16 | 1.4 [1.3-1.5] | 2.3 [1.9-2.7] | 0.46 [0.45-0.47] |
| 8 | 1.2 [1.0-1.2] | 1.7 [1.5-2.6] | 0.51 [0.41-0.55] |

- At the default TileSize the region test is no better than stamps. It only pulls ahead at TileSize 16 and below, where `Update` and `Build` cost more (pain point 2).
- **A game needs to know whether its path is still walkable**, not whether `FindPath` would return the same path.
  - For an add, the obstacle's footprint grown by the agent's radius decides that. An agent whose path stays clear of it can keep walking.
  - That needs 19 times fewer replans at the default TileSize.
- **Suggestion:** have `Update` also return each added obstacle's footprint box per floor, or give `ChangedRegion` a `Blocked` box beside the tile box. Ticket 28's `FirstAffectedSegment` should test that box; on the tile boxes it inherits this problem.

### 2. The default TileSize is wrong for a level that changes often (high, KNOWN: first report pain point 4, ticket 31)

`bench.luau`, the TileSize sweep (Lune, 36 agents, ms, median [min-max]):

| TileSize | Triangles | Build | Bake bytes | `Update` p50 | `Update` p95 | tick p50 | tick p95 |
|---|---|---|---|---|---|---|---|
| default (128) | 300 | 19.3 | 31,216 | 2.08 [2.02-2.09] | 3.69 [3.68-3.74] | 0.60 [0.50-0.60] | 5.22 [5.17-5.58] |
| 64 | 370 | 19.0 | 38,333 | 1.14 [1.13-1.15] | 2.03 [1.97-2.08] | 0.38 [0.37-0.41] | 2.63 [2.52-2.95] |
| 32 | 586 | 26.9 | 60,523 | 0.80 [0.76-0.80] | 1.40 [1.37-1.59] | 0.35 [0.31-0.35] | 2.05 [1.75-2.10] |
| 16 | 1,228 | 56.7 | 128,364 | 0.92 [0.88-0.94] | 1.71 [1.64-1.71] | 0.55 [0.36-0.59] | 2.48 [2.22-2.79] |
| 8 | 3,627 | 160.2 | 383,176 | 1.70 [1.67-1.75] | 2.56 [2.54-2.66] | 0.62 [0.54-0.80] | 4.61 [3.59-4.87] |

- TileSize 32 nearly halves the tick p50 and cuts the tick p95 by 2.5x, for twice the bake size.
- The `Update` doc says "smaller tiles, cheaper updates". That holds down to 32 and fails below it.
- The default is chosen for build speed. Nothing in the docs says how to pick a TileSize for a level with doors and crates.
- The first report found the same for `IsPathValid`. These numbers are for `Update` itself and for the tick.
- **Suggestion:** a sentence in the `TileSize` doc ("for frequent `Update`s, try 32"), or a default that accounts for dynamic obstacles. Ticket 31 measures TileSize on big maps.

### 3. An obstacle landing on an agent: `FindPath` says `NoStart`, and every call site needs a rescue (medium, NEW)

Repro 4 drops a crate on an agent:

```
FindPath:         NoStart          (with GoalFallback = true)
MoveAlongSurface: NoStart
FindNearestPoint(searchRadius 6): (10.0, 0.0, 12.0)
```

- The off-mesh policy is consistent and documented in the table in the `NavMesh` class doc. `FindNearestPoint`'s search radius rescues the agent.
- But the rescue has to wrap every `FindPath` call.
  - My first version handled it only in the follower's `Blocked` branch.
  - A chaser that repathed while inside a crate got `NoStart` on every chase replan and stood frozen, until I moved the rescue into `repath`.
- `sim.luau 5400 3`: in 3 minutes, a door or a crate landed on 8 agents (`rescued 8`).
- **Suggestion:** a start counterpart of `GoalFallback` that snaps the start with a search radius, so `FindPath` returns a path from the nearest reachable point.

### 4. `FindRandomPoint` returns points the agent can't reach (medium, NEW)

Repro 3 builds two rooms joined by a doorway, shuts the door, and draws 200 wander goals around a point in the first room:

```
200 wander goals from (10, 0, 10), radius 30: 99 give a Partial path (the other room)
```

- The doc promises "a point where an agent can stand", and it delivers that: since ticket 24 it is radius-aware.
- It doesn't promise "reachable from here", and a wandering agent needs that.
- `sim.luau 1800 7`: in 60 s the Player and the Wanderers got 173 `Partial` paths (their `status:Partial` rows). Most were goals across a shut door, and each agent walks to the door and stands there.
- **Suggestion:** a `Reachable` option that draws only from triangles connected to `Center` for the filter. Detour's `findRandomPointAroundCircle` works this way.

### 5. A `ChangedRegion` doesn't say whether it opened or blocked (medium, NEW)

Repro 2: adding and then removing the same crate returns the same box.

- A `Partial` path should be retried when a change opens a way. The region can't say which happened, and a crate hop is both a remove and an add.
- Retrying every `Partial` path on every `Update` replanned an order of magnitude more paths. So the game now retries only when it opened a door itself (`world.Opened` in `Game.luau`): 81 retries in 60 s (`repath:partial`).
- **Suggestion:** a field on `ChangedRegion` (`Opened`, `Blocked` or both), or pain point 1's per-obstacle boxes, split into added and removed.

### 6. Dynamic Parts: footprint and floor by hand, and a wrong floor name fails silently (medium, NEW)

- The adapter is one-shot by design: ticket 26, ruling D5, says "games call `AddObstacle`/`Update` themselves". It exports only `FromParts` (repro 6).
- So the game does two things by hand:
  - turns each door and crate Part into a ring (`footprint`, 17 lines of CFrame math);
  - finds the floor the Part stands on (`FindNearestPoint` at its base).
- **The trap:** `AddObstacle` takes a floor name and ignores the ring's Y. Repro 5 adds a crate meant for a deck to `Ground` instead:

  ```
  ground under the deck: Partial (blocked)
  deck through the crate: Success (walks through it)
  ```

  There is no error. The crate cuts the ground under the deck, and agents on the deck walk through it.
- **Workaround found:** `FromParts({ floorPart }, { door })` returns the door's cut ring in 0.08 ms (repro 6), but it needs the floor's Part.
- **Suggestions:**
  - `NavMeshAdapter.Footprint(part, mesh) -> (floor, ring)`, using the adapter's own cut;
  - or an `AddObstacle` that picks the floor from the ring's height when no floor name is given;
  - and a `MoveObstacle(id, ring)`. Each crate hop is a remove and an add today, so the 479 hops in `sim.luau 1800 7` spent 479 obstacle ids.

### 7. The "what did this change touch" helper is still hand-rolled (medium, KNOWN: ticket 28)

- The region test (`segmentHitsBox`, `pathTouches`) and the replan policy are 53 lines of `Game.luau`, the largest glue category.
- It costs 0.0005 ms per agent per `Update` (p50), so only its code size matters.
- Ticket 28's `FirstAffectedSegment` covers it. But see pain point 1: on today's boxes it saves nothing at the default TileSize.

### 8. Path shape across floors (medium-low, KNOWN: ticket 25)

- Repro 7: a path from the ground up the west ramp onto the mezzanine has two waypoints, `(100, 0, 116) Ground` and `(210, 10, 120) Mezzanine`.
- Interpolated at the ramp's top (x 170), the path is at y 6.4, while the deck is at y 10.
- `Advance` walks it correctly over the surface. So, as the first report found, this matters only to a tween or `Humanoid:MoveTo`.

### 9. Debug drawing in a busy scene (low, partly KNOWN: ticket 26 "Not done")

- **KNOWN:** wireframes are `AlwaysOnTop`, so paths and mesh lines under the mezzanine show through it (`screenshot-mezzanine.png`).
- **NEW:** the mesh is redrawn in full after every `Update`.
  - A `Draw` costs 1.39-1.48 ms in Studio, 8.7 times a second here (`studio.py`, "mesh Draw median").
  - A per-tile redraw would help a scene with doors; the regions already say which tiles changed.
- **NEW:** `ToDrawList` draws whole `PathResult`s.
  - Drawing each agent's remaining path means building a fake `PathResult` from the follower (`drawPaths` in `StudioDemo.luau`, 16 lines).
  - Accepting followers would remove that.

### 10. Shipping the bake from Lune (low, KNOWN: bench.md "Shipping a bake", ticket 26)

- **The recipe works:**
  - 31,216 bytes become 41,624 base64 characters in one StringValue.
  - Studio decodes it with `EncodingService` in 0.05-0.13 ms, and `Deserialize` takes 0.38-0.67 ms.
- **But a Lune pipeline carries its own codec.** Lune has no base64, and its zstd frames don't load in Studio (both documented).
  - `BakeText.luau` is 65 lines.
  - Its Lune decoder takes 0.86-0.90 ms.
- **NEW, minor:** the Lune bake isn't byte-identical to `FromParts` + `Build` of the same Parts in Studio.
  - 30 of 31,216 bytes differ (`studio.py` prints it).
  - Studio's `CFrame.Angles(0, pi/2, 0)` has f32 noise (-4.37e-08) that Lune's doesn't.
  - This is harmless for paths, but a byte comparison that checks whether the shipped bake is stale would always say yes.

### 11. Setting up the adapter under Lune (low, NEW, tooling)

- In a worktree where only `lib/navmesh` is set up, requiring the adapter fails with `error requiring module "../NavMesh": could not resolve child component "NavMesh"`. The message doesn't say that the adapter needs its sibling packages vendored. Demo 1's `adapter_check.luau` shows it in such a worktree.
- `npm run setup navmeshadapter` fixes it, but it first runs the `navmesh` setup again, which clears `lib/navmesh`.
- Another session was benching in the same worktree, so I copied the `_Index` folders and link modules by hand instead.

## Wished-for features, by value to this game

1. **A "still walkable" box per added obstacle from `Update`,** with opened and blocked told apart, and ticket 28's helper on top (pain points 1, 5 and 7). It would cut replans 19x here.
2. **A start fallback in `FindPath`,** the mirror of `GoalFallback` (pain point 3).
3. **Reachable random points** (pain point 4).
4. **A footprint helper for one Part, and `MoveObstacle`** (pain point 6).
5. **TileSize guidance for dynamic levels** (pain point 2).
6. **Crowd separation.** It is out of scope per spec.md (KNOWN), but it is the most visible flaw.
   - At the end of `sim.luau 1800 7`, 29 pairs of agents overlap, and the Chasers stack up on the Player.
   - `screenshot-door-open.png` shows two Chasers inside each other in the doorway.
7. **Debug:** draw followers, and redraw only the changed tiles (pain point 9).
8. **Waypoints at seams and creases** (ticket 25, pain point 8).

## What worked well (keep it)

- **The Part adapter.**
  - Four walkable Parts and 38 obstacle Parts (walls, shelves, cylinder pillars) gave 4 floors and 4 seams with nothing hand-written: no seam coordinates, and no cut-out under the ramps.
  - `FromParts` takes 1-2 ms.
  - Wedges and cylinders worked the first time.
- **The follower.**
  - `NewFollower` + `Advance` replaced demo 1's whole follow function. My `follow` is 20 lines, most of it event handling.
  - There was no arrival trap and no stuck loop.
  - In `invariants.luau`, 64,800 agent-ticks (36 agents x 60 s) had 0 agents off the mesh and 0 closer to a wall than their radius minus 0.05.
- **The reachable queries.**
  - `GoalFallback` let chasers path to a Player anywhere without special cases.
  - `FindNearestPoint`'s search radius rescued every agent a door or crate landed on.
  - `FindRandomPoint` is radius-aware, so there is no rejection loop (demo 1 had one).
- **`Update` batching.**
  - Several doors and crates that change in one tick become one `Update`, and `HasPendingChanges` skips empty ticks.
  - It never failed in about 1,600 calls (`sim.luau 5400 3`).
- **Debug drawing.** `ToDrawList` with several paths, `PathColors`, `WallColor` and `Triangles = false` drew 36 coloured paths in 0.12-0.13 ms a `Draw`, without a hand-made line list.
- **Error messages and the off-mesh table** in the class doc. Every off-mesh answer I met was the one the table promised.

## Timings

- All times are in ms.
- The machine was shared with another session's benchmarks, so each cell is a median over runs, with the range.
- **Lune:** `bench.luau 900 3`, three seeds, interleaved.
- **Studio:** three edit-mode runs of `studio.py shot`, 32 s each, same seed.

**Load and build** (default TileSize):

| What | Lune | Studio |
|---|---|---|
| `FromParts` | 1.1-2.0 | (with Build) |
| `Build` (300 triangles) | 19.3 [19.0-19.3] | `FromParts` + `Build` 24.5-31.4 |
| Bake | 31,216 bytes; 41,624 base64 characters, 1 StringValue | same |
| base64 decode | 0.86-0.90 (plain Luau) | 0.05-0.13 (`EncodingService`) |
| `Deserialize` | 0.65 [0.36-1.14] | 0.38-0.67 |
| First `Update` after `Deserialize` (8 crates; the KNOWN load spike) | 8.5 [8.4-9.0] | 8.6-16.0 |

**Per frame** (36 agents, default TileSize; about 9 `Update`s a second, and 5 `FindPath`s a tick):

| Call | Lune p50 | Lune p95 | Studio p50 | Studio p95 |
|---|---|---|---|---|
| `Update` (one crate hop, or a door) | 2.08 [2.02-2.09] | 3.69 [3.68-3.74] | 1.95-1.99 | 3.63-4.26 |
| `FindPath` (chase and replan) | 0.081 [0.076-0.084] | 0.163 [0.155-0.193] | 0.080-0.082 | 0.18-0.19 |
| `Advance` | 0.0092 [0.0090-0.0097] | 0.018 | 0.0090-0.0092 | 0.017-0.019 |
| Region test, per agent per `Update` (glue) | 0.0005 | 0.002 | | |
| Whole tick (36 agents) | 0.60 [0.50-0.60] | 5.22 [5.17-5.58] | 0.66-0.71 | 5.24-5.48 |
| Mesh `Draw` after an `Update` | | | 1.39-1.48 | |
| Paths `Draw` (36 paths) | | | 0.12-0.13 | |

**Agent count** (`bench.luau`, default TileSize):

| Agents | `FindPath` per tick | `FindPath` p50 | `Update` p50 | tick p50 | tick p95 |
|---|---|---|---|---|---|
| 36 | 5.2 [4.8-5.5] | 0.082 | 2.07 | 0.61 [0.53-0.61] | 5.46 [5.22-5.80] |
| 71 | 9.6 [9.5-9.7] | 0.078 | 2.04 | 1.04 [0.99-1.10] | 7.36 [7.13-7.81] |
| 141 | 18.1 [18.0-18.5] | 0.079 | 2.12 | 1.87 [1.83-1.94] | 13.10 [12.15-13.60] |

- **Per-agent cost is flat:** `FindPath` stays at 0.08 ms, and the tick median grows linearly.
- **The p95 grows faster,** because each `Update` replans about 30% of the agents (pain point 1). At 141 agents the p95 tick is 13 ms, most of a 60 Hz frame.
- **Against demo 1** (a 60 x 40 level, 48 triangles, 7 agents):
  - `FindPath` was 0.02-0.04 ms there, and is about 2-4 times that here, on a level 40 times larger.
  - A door `Update` was 1.3-2.3 ms there, the same as here.

## Setup cost and hand-rolled code

**Setup:**
- The level is 86 lines of Parts (`LevelParts.luau`), the bake script is 45 lines and the sim 46.
- Getting the Lune environment to load the adapter took pain point 11's vendoring.
- Studio needed nothing beyond demo 1's run-in-roblox and capture pattern.

**Hand-rolled code** is counted as the non-blank lines between the `glue:<what>` markers in `Game.luau`, plus `BakeText.luau` and `drawPaths` in `StudioDemo.luau`. Timing and comparison counters are excluded.

```sh
awk '/--> glue:/{c=$0; sub(/.*glue:/,"",c); on=1; next} /--< glue/{on=0; next} on && NF {n[c]++} END {for (k in n) print k, n[k]}' examples/navmesh-demo2/Game.luau
```

| Category | Lines | What |
|---|---|---|
| Replan after `Update` | 53 (60 less 7 comparison counters) | the segment-vs-box test, which agents to replan, the `Partial` retry |
| Dynamic obstacles | 32 (36 less 4) | the Part footprint, the floor lookup, remove-and-add |
| Chase scheduling | 25 | replan when the target moved, 4 a tick round robin, catches |
| Rescue off the mesh | 21 | `FindNearestPoint` with a search radius, then `FindPath` again |
| Following | 20 | `Advance` events |
| Bake shipping | 65 | the base64 codec for Lune, the chunk loader |
| Debug paths | 16 | each agent's remaining path for `ToDrawList` |
| **Total** | **232** | |

- **Against demo 1:** its first report counted about 150 of 487 lines, nearly all following, arrival, links, stuck detection, rescue, random-point rejection and revalidation.
  - Demo 2 is a bigger game, so the totals don't compare directly.
  - What changed is where the glue goes. Following, arrival, links and random points are now library calls.
  - The new glue is replanning after changes (pain points 1, 5 and 7), dynamic Parts (pain point 6) and the Lune bake codec (pain point 10).
- **For a Roblox-only game** the glue is about 160 lines, without the Lune-only codec (about 45 lines) and the chase gameplay. Fixing pain points 1, 3 and 6, plus ticket 28, would remove about 100 of them.

## Screenshots

All are from `studio.py shot` and were checked by eye. Each pair taken 6 s apart in one run differs (the script checks this).

- `screenshot-top.png`: the whole warehouse.
  - Visible: the mesh coloured by floor, white walls with door gaps, the shelf rows, the crates, and the mezzanine with its two ramps.
  - The red Chasers converge on the Player along their paths, and the blue Wanderers stroll.
  - The 1-stud Player is only a few pixels at this scale.
- `screenshot-mezzanine.png`: the mezzanine from the south, with the green Player at the left. Lines under the deck show through it (pain point 9).
- `screenshot-door-shut.png` and `screenshot-door-open.png`: the east wall's middle door, 6 s apart.
  - Shut, the door is opaque and the mesh outlines its footprint.
  - Open, the door is faded, the outline is gone, and two Chasers walk through, overlapping each other.
