# 34: Building with a staircase

**What to build:** A two-storey building made of Parts, whose upper floor is reached by a real
staircase of individual steps. NPCs of several sizes walk up and down it.

**Blocked by:** 33 (map scenario harness)

**Status:** done (2026-10-01, Track M1, branch `navmesh-maps-urban`). Step joins ruled: ramp
strips now, riser seams later (ticket 40).

- [x] **The map:** a two-storey building with walls, a doorway, an upper floor slab, and a
      staircase built from separate step Parts.
  - Use a typical Roblox stair: about a 1-stud rise, with a landing and a U-turn.
  - Add a second, straight stair that is narrower.
- [x] **Scenarios:**
  - ground to upper floor and back, at radius 0.5, 1 and 2;
  - the narrow stair rejects radius 2, which goes the long way or returns Partial;
  - a path that must use the landing.
- [x] **Steps must be walkable as a stair.**
  - Today each step's top is likely its own floor, with no seam to the next step: a riser's
    top edge doesn't lie on the next step's surface.
  - If the scenarios fail for that reason, add a step-height rule to the adapter: faces whose
    edges meet within a maximum step height are joined. Keep that a Part-adapter option,
    since the core already supports seams. Ask the user if the rule's shape needs a ruling.
  - The specs must cover it, with a negative control.
- [x] **Compare a wedge ramp with the same rise.** Report floor, seam and triangle counts,
      Build ms and path length for each. Include waypoint heights along the stair; ticket 25
      is the follow-up if interpolated Y cuts through the steps.
- [x] **A Studio screenshot** of the building, the mesh and the scenario paths, checked with
      the Read tool.

## As-built (2026-10-01)

### The map
`tools/navmesh/maps/Building.luau` builds it; `Maps/Building.luau` (steps) and
`Maps/BuildingRamp.luau` (the wedge comparison) are the harness maps. Named points are in
`BuildingPoints.luau`, and ticket 35 reuses all of them.
- **Shell:** 60 x 40 inside, walls 1 thick and 24 tall, an 8-wide doorway in the south wall,
  on a 100 x 80 lot. The upper floor is a 1-stud slab with its top at y 12, with holes over
  both stairs.
- **The U-stair:** 1-stud rise, 1.5-stud treads, 6 wide. Five steps climb east to a landing
  (top 6, 6 x 12), and five more climb back west to the upper floor.
- **The narrow stair:** 3 wide, 11 steps straight up along the south wall.

### Step-height rule (adapter)
- Without a rule, each step top is its own floor and nothing joins them: every stair scenario
  ended Partial at the stair's foot (18.0 studs).
- **Ruled 2026-10-01:** "We will go with ramp strips for now, but make a ticket for riser
  seams to replace it" (review.md). The four options were measured first; see the table
  below.
- **Built:** `AdapterOptions.MaxStepHeight` (default 0: off), in its own function
  `riserStrips`. Where an edge of a face lies over another floor's face, above it by no more
  than `MaxStepHeight`:
  - a strip floor `Riser`, `Riser 2`, ... (0.25 studs wide, as steep as the rise) runs from
    the edge out over the lower face;
  - it is cut out of the lower floor and seamed to both floors at their own heights.
  - It is skipped where the lower face doesn't reach past the strip, or where a cut stands in
    the strip's band (lower floor) or just inside the edge (upper floor). Build would reject a
    seam with nothing beside it.
  - Strips are cut as they are made, so where two meet at a block's corner the later one stops
    at the earlier.
  - Side edges count too: a 1-stud step can be climbed from its side, as in Roblox.
- **Specs:** 13 in `NavMeshAdapter.spec.luau` ("step-height rule (ticket 34)"). Negative
  controls:
  - with the rule off, the riser stays a wall (`Partial`);
  - with the cut subtraction disabled, "only the open part of a riser gets a strip" and
    "a riser blocked along its whole length..." both fail.
  - Map-level: with `MaxStepHeight = 0`, all 11 Building scenarios fail (Partial), and the map
    exits 1.
- **Mutation:** see the gate line under Numbers.

### Step joins compared (the ruling's numbers)
Building map: the U-stair, the narrow stair, radius 0.5 / 1 / 2, Lobby to Upstairs. Build is
the median of 5; FindPath the median of 20.

| Join | Floors | Seams | Links | Triangles | Build | Bake | Up the U-stair (r 0.5 / 1 / 2) | Waypoints |
|---|---|---|---|---|---|---|---|---|
| **Ramp strips (built)** | 43 | 60 | 0 | 268 | 28 ms | 49.5 KB | 57.6 / 59.7 / 64.0 | 30 |
| Riser seams (core check loosened, local only) | 13 | 30 | 0 | 160 | 16.5 ms | 29.8 KB | 57.3 / 57.7 / 59.2 | 19 |
| Wedge ramp (stand-in for a merged slope) | 15 | 4 | 0 | 125 | 8.7 ms | 16.9 KB | 55.0 / 56.0 / 58.0 | 6 |
| Links per riser (every 3 studs) | 13 | 0 | 42 | 156 | 18 ms | 30.4 KB | 64.0 / Partial / Partial | 28 |

- The wedge row is the probe's, with the narrow stair unjoined. The map `BuildingRamp` joins the
  narrow stair with strips too: 31 floors, 36 seams, 177 triangles, Build 14.5-16 ms, bake
  27.2 KB.
- Links fail at radius 1 and up: link ends 0.25 studs from the riser are inside the radius.
  They also give 12 follower link events per climb.

### Scenarios (`lune run tools/navmesh/maps/run.luau Building BuildingRamp`)
| Scenario | Result (steps) | Length | Wedge ramp |
|---|---|---|---|
| up the U-stair, r 0.5 / 1 / 2 | Success, visits Ground, Landing, Upper | 57.6 / 59.7 / 64.0 | 55.0 / 56.0 / 58.0 |
| down the U-stair, r 0.5 / 1 / 2 | Success, visits Upper, Landing, Ground | 61.7 / 63.1 / 65.9 | 51.3 / 52.9 / 56.3 |
| narrow stair, r 1 | Success, under 40 | 35.2 | |
| narrow stair rejects r 2: the long way | Success via the landing, over 60 | 97.0 | |
| street to upstairs, r 1 | Success, via the landing | 86.1 | |
| landing to upstairs, r 1 | Success | 31.6 | |
| control: narrow stair is not short at r 2 | `pass*`: "MaxLength: 97.0, want <= 40.0" | | |

- The harness gained `Expect.Visits` (floors that must appear in order, among others). With
  strips, a stair's floor list holds every riser, so `Floors` would be brittle.
- **Up and down differ** (57.6 against 61.7; on the ramps 55.0 against 51.3). The search is
  not optimal; this is noted in known-gaps.md, "Found by Track M1".

### Waypoint heights along the stair
Up the U-stair at radius 1, the waypoints sit at each strip's foot and top: (35.75, **0**),
(36.00, **1**, Riser), (37.25, **1**, Step), (37.50, **2**), ... (43.50, **6**, Landing), then
back west (43.50, **7**) ... (36.00, **12**, Upper). Interpolated height stays on each tread
and rises only across a 0.25-stud strip; the worst sample is 0.80 studs off a step top, inside
a strip. **So ticket 25 needs no follow-up for steps.** On the wedge ramp the path is 6
waypoints and lies on the ramp surface.

### Numbers
- **Building (steps):** FromParts 3.4 ms, Build 28-30 ms (37-50 ms in Studio); 268 triangles,
  43 floors, 60 seams; bake 49,532 bytes; FindPath 0.08-0.22 ms.
- **BuildingRamp:** FromParts 2.4 ms, Build 14.5-16 ms; 177 triangles, 31 floors, 36 seams;
  bake 27,242 bytes; FindPath 0.06-0.09 ms.
- **Gates:** adapter specs 38/38; adapter coverage 99.1% lines.

### Screenshot
`python tools/navmesh/maps/studio.py Building` (an oblique view, the upper slab and walls
see-through). It shows the U-stair with each riser strip in its own floor colour, the paths
climbing it, the narrow stair's radius-1 path, and the radius-2 path going round to the
U-stair. The drawn and cleared frames differ in 9.8% of pixels.
- The harness's Studio camera is placed once and left free (user: "do not lock it so I cant
  look around"). Studio's edit camera re-aims at `Focus`, so both are set.
- Map field `SeeThrough` lists Part names Studio draws at 0.75 transparency.
- A first capture got another session's Studio window: that session was using run-in-roblox's
  port 50312 at the same time. Wait until the port is free.
