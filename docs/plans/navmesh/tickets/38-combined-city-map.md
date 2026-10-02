# 38: Combined city map (regression bench)

**What to build:** One map joining the building with stairs and elevator, the street, and the
forest and river. NPCs run daily routes across all of it, and the map becomes the regression
bench for realistic content.

**Blocked by:** 35 (elevator), 36 (street), 37 (uneven terrain)

**Status:** done (2026-10-02, Track M2, branch `navmesh-maps-outdoor`).

- [x] **The map:** the pieces from 34-37 placed together. The street connects the building to
      the outdoor area, and the river separates part of the outdoors.
- [x] **Daily routes:**
  - upstairs in the building, by stairs or elevator;
  - out the door, across at a crosswalk;
  - through the forest, over the river.
  - Run them for a seeded crowd of NPCs with mixed radii and costs, using the follower.
- [x] **Dynamic events during the run:** the elevator going out of service and back, a door
      closing, and a crate dropped on a sidewalk. Record repaths and the decisions from
      ticket 35's reroute policy.
- [x] **Bench numbers in bench.md,** so later tickets can be checked against them:
  - Build ms, bake bytes, Deserialize ms;
  - `FindPath` median and p95;
  - `Update` per event;
  - triangle, floor and seam counts.
- [x] **Studio screenshots:** an overview, plus one per district.
- [x] Runs in one command, so any future change can be checked against this map.

## As-built (2026-10-02)

**Run it:** `lune run tools/navmesh/maps/run.luau City` (the scenarios) and
`lune run tools/navmesh/bench/city_day.luau [seed=1] [count=60]` (the crowd's day and the bench
numbers; exits 1 if a walking NPC doesn't get home or anyone sets foot in the river). The City is
also in the plain `run.luau`, so every map run checks it.

**Files:**
- `tools/navmesh/maps/Maps/City.luau`: the map and eight scenarios.
- `tools/navmesh/bench/city_day.luau`: the day.
- `tools/navmesh/maps/ElevatorSim.luau` (ticket 35's crowd) gained, without changing its
  building-only runs: `o.Crowd` (NPCs with a kind, radius, extra area costs and legs walked in
  turn), and `Changed(regions)`, which re-plans each walker whose path ahead an `Update`'s
  regions touch (`FirstAffectedSegment`), and each stuck NPC.
- `tools/navmesh/maps/Street.luau` passes building options (the elevator) and links through.
  `ForestRiver.WithTilt` takes `{ LevelSouth = true }`, so the meadow meets the sidewalk level.
- `tools/navmesh/maps/studio.py` gained `--view fx,fy,fz,tx,ty,tz --tag name` for close-ups.

**The map:** ticket 36's street (curbs, both crosswalks, parked cars) with ticket 34's building and
ticket 35's elevator, and ticket 37's ForestRiver (5 degrees, seed 37) south of the sidewalk,
moved by (-20, 0, -210). The river runs up to the sidewalk, which crosses it like a culvert; south
of it the east side is reached by the bridge or the ford. The sidewalk, the lot and the level
ground beyond it are one floor, "Ground"; the road and crosswalks are "Road".

**Scenarios** (all pass, Lune and Studio):

| Scenario | Expect | Length |
|---|---|---|
| walker: upstairs to the forest, by a crosswalk and the bridge | visits Upper, Landing, Ground, Road, Bridge; avoids Road and the ford | 387.6 |
| walker, ford cheap: wades the ford instead | visits Ground, Road, Ford | 206.4 |
| wheelchair: down by the elevator, out to the meadow | link Elevator, avoids Road | 167.7 |
| tired, home from the plateau: up by the elevator | visits Bridge, Road, Ground; link Elevator | 411.3 |
| elevator out: a wheelchair can't leave the upper floor | Partial | 51.3 |
| radius 2 through the forest from the street | visits Bridge | 323.7 |
| control: road cost 1 crosses off the crosswalks | `MustFail = "Avoids"` | pass* |
| control: the out-of-service elevator is not ridden | `MustFail = "Links"` | pass* |

**The day** (`city_day.luau`): 60 NPCs, half walkers (stairs and ford at cost 1), 35% tired
(stairs x5, ford 50), 15% wheelchairs (stairs and ford closed); radii 0.5, 1, 1, 1.5 or 2; the road
costs 10 for everyone, so they cross at crosswalks. Each leaves a home on the upper floor within
30 s, walks to a spot outdoors that it can reach, and comes home. Events:

| t s | Event | What the game does |
|---|---|---|
| 20 | a crate dropped on the sidewalk, in front of the west crosswalk | `AddObstacle`, `Update`, re-plan the touched paths |
| 35 / 50 | the door closes, then opens | the same; those inside are stuck (Partial) until it opens |
| 60 / 90 | the elevator out of service, then back | `SetLinkEnabled` and ticket 35's ruled policy: broadcast out of service, 15% hysteresis back in |
| 100 | the crate taken away | `RemoveObstacle`, `Update` |

Seeds 1-10 all pass: every NPC home, 0 steps in the river. Numbers (seeds 1-3):

| | Seed 1 | Seed 2 | Seed 3 |
|---|---|---|---|
| FromParts / Build / Deserialize ms | 2,620 / 1,804 / 13.8 | 2,729 / 1,840 / 14.8 | 2,748 / 1,807 / 10.6 |
| `FindPath` calls, median / p95 ms | 218, 1.91 / 12.7 | 229, 1.89 / 12.3 | 239, 2.36 / 13.1 |
| crate dropped: Update ms, re-planned | 12.8, 3 | 10.6, 6 | 10.0, 8 |
| door closes: Update ms, re-planned | 16.1, 21 | 15.3, 28 | 14.7, 30 |
| door opens: Update ms, re-planned | 12.7, 44 | 14.4, 46 | 12.4, 45 |
| elevator out: handling ms, rerouted | 125, 14 | 171, 17 | 154, 19 |
| elevator back: handling ms, rerouted | 19, 0 | 21, 0 | 32, 0 |
| crate taken away: Update ms, re-planned | 8.7, 0 | 10.4, 0 | 10.3, 1 |
| median day, walker / tired / wheelchair s | 41 / 45 / 91 | 47 / 48 / 74 | 50 / 52 / 93 |

- 5,667 triangles, 326 floors, 513 seams, bake 809,898 bytes.
- "Handling" for the elevator is the link toggle plus the policy's re-plans: each re-plan is a
  weighted `FindPath` (stairs priced), about 9 ms on this map. Back in service, the 15%
  hysteresis moves nobody.
- "Door opens" re-plans everyone stuck behind it; most of the crowd is still at home then.

**What it found:**
- **The follower can stall for good beside a vertex where several meadow floors meet** (core;
  known-gaps.md, repro `tools/navmesh/bench/follower_vertex_stall.luau`). The first crowd drew a
  destination there and an NPC looped Blocked, re-plan, Blocked. The crowd now draws other
  spots, so the day passes; the repro keeps the case.
- Two setup bugs, fixed in the bench: homes must fit the widest NPC (a radius-2 home sat on a
  1-stud strip), and a random point clear for a radius can still sit in a pocket between trees
  that radius can't enter, so each destination is checked with `FindPath`.

**Screenshots** (`.bench/navmesh/maps/`, checked with the Read tool):
- `City-viewport.png`: the overview. The building, the road with parked cars and crosswalks, the
  sidewalk, the meadow, river, bridge, ford and forest, and the scenario paths.
- `City-building-viewport.png` (`--view 78,62,-22,34,2,22 --tag building`): the upper floor, the
  elevator shaft and the U-stair, paths down by elevator and by stairs, out the doorway.
- `City-street-viewport.png` (`--view 30,55,-80,30,0,-30 --tag street`): paths through the west
  crosswalk between the parked cars, onto the sidewalk and the meadow.
- `City-river-viewport.png` (`--view 150,90,-60,80,0,-135 --tag river`): the meadow's hills, the
  river, paths over the bridge, the ford, and the forest trail.
- Drawn and cleared frames differ in 4.0-17.0% of pixels.
