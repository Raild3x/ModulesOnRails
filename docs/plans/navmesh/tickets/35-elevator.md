# 35: Elevator beside the staircase

**What to build:** An elevator in ticket 34's building, on the same map as the staircase, so the
two compete. NPCs ride it between floors, choose between it and the stairs by cost, and react
when its availability changes while they are on the way.

**Blocked by:** 34 (building with a staircase)

**Status:** done (2026-10-01, Track M1). Reroute policy ruled: hysteresis on the game's event,
plus library aids (ticket 41).

- [x] **The elevator:** a shaft with a cab that moves between the floors.
  - Navigation sees it as labelled links ("Elevator") between the floors' landing points.
    Their cost stands for the wait plus the ride.
  - Availability follows the cab: `SetLinkEnabled`, or runtime links if ticket 30 has landed.
- [x] **Riding:** the NPC walks to the elevator, gets the follower's link event, and waits for
      the cab. It boards, rides and exits, then continues the path. The game does the waiting
      and riding; the library only routes.
- [x] **Priority scenarios:**
  - stairs win when the elevator's cost is high;
  - the elevator wins when the stairs are far or the NPC's costs penalise them;
  - an elevator that is out of service sends everyone to the stairs.
- [x] **The user's question: reroute when the elevator becomes available?** An NPC is partway
      up the stairs when the elevator becomes available. Should it reroute? Investigate and
      present options to the user with measurements:
  - **What the library reports today.** Enabling a link doesn't invalidate a path that avoids
    it. `IsPathValid` and `ChangedRegion` only report blocking changes, and demo 2's pain point
    5 noted that a region doesn't say whether it opened or blocked. So the NPC never hears of
    the better route.
  - **Candidate policies:**
    - compare the remaining cost of the current path against a fresh path from the NPC's
      position, and reroute only past a threshold (hysteresis);
    - a commit point (once on the stairs, keep going);
    - re-plan at waypoints only.
  - **What would help**, as candidate library features: a region or event that reports an
    *opened* route, or a cheap "remaining cost" query on a follower.
  - **The reverse case:** the elevator goes out of service while the NPC is walking to it,
    waiting, or riding.
- [x] **Measure:** reroute decisions and the time saved or lost over a seeded crowd of NPCs on
      mixed routes. Present the policy options with those numbers before building any library
      feature.
- [x] **A Studio screenshot** with NPCs on both the stairs and the elevator.

## As-built (2026-10-01)

### The elevator
- `Building.Build(rbx, parent, { Elevator = true })` adds:
  - a shaft at x 2..8, z 10..16 (an obstacle on both floors);
  - a cab Part (shown in Studio, not navigated);
  - one two-way link labelled "Elevator", `Area` 6, `Cost` 56, between landing points
    (5, 0, 18) and (5, 12, 18) in front of the doors.
- Every step Part gets `NavArea` 5 (stairs), so NPC kinds can price the stairs.
- **Cost:** 56 studs is the best case: 3.5 s at 16 studs/s, the ride (1.5 s) plus doors (2 s)
  with the cab already waiting. The game passes the current wait as
  `AreaCosts[6] = expected seconds / 3.5`: the cab's distance, and the queue ahead in full cab
  loads.
- **Deviation:** availability follows *service*, not the cab's position. The link is enabled
  while the elevator runs, and the cab's whereabouts go into the per-query multiplier.
  Toggling the link at every cab arrival would invalidate every path near the doors each time
  (see ticket 41).

### Riding
`tools/navmesh/maps/ElevatorSim.luau` is the game side; the library only routes.
- The follower's `Link` event at "Elevator" puts the NPC in its floor's queue.
- The cab (capacity 4) boards while its doors are open, rides, and lands each rider at the
  link's `To`. The follower then continues from the landing waypoint.

### Priority scenarios (`lune run tools/navmesh/maps/run.luau BuildingElevator`)
All radius 1. Kinds are filters: walker (all costs 1), tired (stairs x5), wheelchair (stairs
`math.huge`).

| Scenario | Result | Length |
|---|---|---|
| walker: stairs beat the elevator (Lobby to Upstairs) | no link, via the landing | 59.5 |
| walker: the elevator wins far from the stairs (WestGround to WestUpper) | Elevator | 44.2 |
| tired: the elevator wins | Elevator | 56.4 |
| tired, elevator busy (x3): the stairs win again | no link, via the landing | 59.5 |
| wheelchair: elevator only | Elevator | 56.4 |
| out of service: the tired take the stairs | no link | 59.5 |
| out of service: a wheelchair can't go up | Partial, on Ground | 18.0 |
| out of service: the far walker takes the stairs | no link | 94.9 |
| control: out of service is not ridden | `pass*`: "Links: got {}, want {Elevator}" | |

- The harness gained `DisabledLinks` (labels switched off for one scenario, then back on).
- **Numbers:** FromParts 4.6 ms, Build 42 ms; 280 triangles, 43 floors, 60 seams; bake 52,783
  bytes. FindPath takes 0.08-0.2 ms, but **3-4 ms for a weighted query that ends on the stairs**
  (tired, stairs x5).

### The reroute study (the user's question)
`lune run tools/navmesh/bench/elevator_reroute.luau [seeds=20] [count=40]`.
- **Setup:** a crowd of half walkers, 35% tired and 15% wheelchairs. 80% are bound for the
  other floor, spawning over 8 s. The elevator changes state at t = 6 s.
- **Effort** is the NPC's own price: trip seconds plus (stairs multiplier - 1) x seconds on
  the stairs. "Better" and "worse" count NPCs whose effort moved by more than 0.5 s against
  `ignore`, same seed.
- **Calibration:** the wait estimate is within -0.06 to +0.20 s of the actual wait. A first
  run had riders who arrived during open doors miss the cab; the promise was then 1.6-1.9 s
  short and every reroute looked bad. Fixed before these numbers.
- **Cost-mode pitfall:** both costs in a decision come from FindPath in the weighted mode. The
  elevator multiplier is never exactly 1, and "stay" uses 1e6 rather than `math.huge`.
  Otherwise the two costs are measured differently (known-gaps.md).

**The elevator frees up**, 20 x 40:

| Policy | Mean trip | p90 | Effort | NPCs rerouted | Their own gain | Better / worse | Crowd effort saved | FindPath calls |
|---|---|---|---|---|---|---|---|---|
| ignore | 5.70 s | 9.69 | 6.60 | 0 | | | 0 | 868 |
| always (any saving) | 5.84 | 10.46 | 6.60 | 31 | +0.79 s | 47 / 30 | -5.7 s | 1305 |
| **hysteresis 15% (ruled)** | 5.74 | 9.98 | **6.57** | 16 | **+1.58 s** | 22 / 15 | **+21.9 s** | 1305 |
| commit point | 5.70 | 9.69 | 6.60 | 0 | | | 0 | 868 |
| re-plan at waypoints | 5.79 | 10.32 | 6.60 | 17 | -0.25 s | 15 / 13 | +0.8 s | 9290 |
| library only (IsPathValid) | 5.88 | 10.48 | 6.63 | 405 | +0.01 s | 47 / 43 | -28.1 s | 1526 |

- **Light crowd** (20 x 10): rerouters gain about 1.5 s each, but the crowd nets -3 to -6 s.
  Those few switchers take the cab from others.
- **Commit point = ignore:** by the time the elevator reopens, everyone who would switch is
  already on the stairs.
- **Library only:** `IsPathValid` flagged 405 paths, none using the elevator. The flags come
  from the tile stamps at the link's ends, and those re-plans happen to send some tired NPCs to
  the elevator.

**The elevator goes out of service** at t = 6 s, 20 x 40:

| Policy | Mean trip | p90 | Unfinished | Stranded | Paths flagged (not using the elevator) |
|---|---|---|---|---|---|
| game broadcast | 13.10 s | 9.13 | 58 (wheelchairs with no way up) | 0 | |
| library only | 16.73 s | 112.41 | 85 | **47 (6%)** | 429 (308) |

- **By phase:** NPCs walking to it re-plan, from the broadcast or (library only) from
  `IsPathValid`. NPCs waiting at the doors re-plan only on the broadcast; library-only, they
  are stranded. Riders are delivered, then the cab parks.

### Screenshot
`python tools/navmesh/maps/studio.py BuildingElevator`. The map's `Animate` hook runs the sim
live under the ruled policy: 80 NPCs over 40 s, balls coloured by kind, the cab following the
sim. The capture shows a walker on the narrow stair, a wheelchair at the elevator doors, the
cab in its shaft, and tired NPCs upstairs. The drawn and cleared frames differ in 23.9% of
pixels.
- With the camera unlocked (ruled), the view can differ from `View`: Studio re-aims it, or the
  user moves it.

### Found here (known-gaps.md, "Found by Track M1")
- `PathResult.Cost` changes meaning between uniform and weighted filters
  (`tools/navmesh/bench/path_cost_modes.luau`).
- Riser strips don't carry the step's `NavArea`, so a stairs multiplier skips the 0.25-stud
  strips (about 1/6 of each tread).
