# 25: Path shape and waypoint metadata

**What to build:** Waypoints that a tween or `Humanoid:MoveTo` can follow directly, and links
that are addressable by name.

**Blocked by:** none

**Status:** built on `navmesh-path-output` (2026-10-01, Track G): the seam and crease
waypoints (the drape), `PathResult.Length`, and heron nodes for the path-length item. The
bisector funnel was measured and moved to ticket 32 (ruled). Weighted queries (area costs) keep
midpoint nodes; research on them continues on `proto/g-areabend`. The link items belong to Track E (ticket 30). From the
dogfood report, pain points 8, 9 and 15, and repros 4 and 7.

- [x] **Waypoints where a path crosses a seam or a crease (slope change).**
  - Today a ramp-to-balcony path has no point at the ramp's top. Interpolating Y between
    waypoints passes 3 studs under the surface, and `FindNearestPoint` then lands on the floor
    below (repro 7).
  - The alternative is a `SamplePath(path, spacing)` helper.
- [x] **Equal-cost area boundaries don't bend paths.** (Heron nodes; the bend was general.)
  - Repro 4: a patch with cost 1 makes a path 8% longer.
  - Candidate fix: a final shortcut pass over segments whose area costs are equal.
- [x] **Link id on the link's waypoint.** (Track E: `Waypoint.LinkId`, `FollowerLink.Id`.)
- [x] **An optional `Name` on `LinkDesc`,** (Track E: `SetLinkEnabled(mesh, name, on)` toggles every link with that name) with `SetLinkEnabled` accepting it, since today
      it only takes an index into `Links`.
- [x] Decide whether `PathResult` gains a `Length` (the 3D polyline length). `Cost` is the
      search cost and differs from it.

The corner-chord clearance is documented in `QueryFilter.AgentRadius` as of 3ce0e7c. Emitting
an arc-midpoint waypoint on sharp turns stays optional.

## As built (2026-10-01, Track G)
- **Seam and crease waypoints: the drape, in `Funnel.luau`.**
  - After each funnel run, every straight stretch is walked across the portals it crosses.
    Each crossing's height comes from the portal edge, so it is exact. Between crossings, both
    the surface and a lerp are linear, so checking at the crossings is enough.
  - A sleeve of allowed slopes from the last kept point keeps the fewest crossings for which a
    height lerped between consecutive waypoints stays within 0.01 studs of the surface. It is
    one pass, like the funnel in plan. A flat floor gets no extra waypoint.
  - An added waypoint takes its floor from the triangle before the portal, as funnel corners
    do.
  - `pull` now also returns which portal each point lies on.
- **The follower:** each added waypoint costs `Advance` at most one short step, because a
  step that reaches a waypoint stops there.
  - Ramp paths took 155 steps instead of 154.
  - 200 random demo-level paths took 21,170 steps instead of 21,163, for 17 added waypoints.
  - No added stall or `Blocked`.
- **`SamplePath` was measured as the alternative, and not built.** It walks each segment over
  the surface and emits a point every `spacing` studs. Numbers are from
  `tools/navmesh/bench/path_shape.luau`, 100 paths per scene, r 0.5:

  | scene | lerp drift, no drape | drift, drape | FindPath, no drape / drape | SamplePath 1 stud: cost, points, drift | SamplePath 0.25: cost, points, drift |
  |---|---|---|---|---|---|
  | overhang (repro 7) | 3.21 | 0.0000 | 16.5 / 15.8 us | 54 us, 19, 0.123 | 200 us, 72, 0.030 |
  | hills (one uneven ring) | 3.70 | 0.0099 | 22.2 / 25.0 us | 39 us, 14, 0.160 | 152 us, 51, 0.034 |
  | props (flat) | 0 | 0 | 209 / 218 us | 327 us, 42, 0 | 1,128 us, 146, 0 |
  | walls (flat) | 0 | 0 | 92 / 96 us | 934 us, 196, 0 | 3,633 us, 766, 0 |

  - The drape costs about what run-to-run noise does (±5%), and it is exact.
  - `SamplePath` costs 2-10x a FindPath at 1-stud spacing and still drifts 0.12-0.16 studs.
  - It also walks from each waypoint, so where two floors overlap at a seam it can start on the
    wrong one. The ThreeFloorStairs fixture's Ground runs on under its stairs, and the spec
    oracle hit exactly that.
- **`PathResult.Length`:** the 3D length of the waypoint polyline, with a link's hop counted
  as a straight line. It is 0 with no waypoints. There was no real trade-off, so it wasn't
  asked.
- **Specs:** `NavMesh.PathShape.spec.luau`.
  - The drape is checked by a surface walk: lerped heights stay within 0.0101 of it on the
    overhang (r 0 and 0.5), a gabled roof and a hilly ring.
  - Repro 7's exact waypoints, the roof's ridge point, no non-turning waypoint over 60 Courtyard
    paths, and `Length`.
- **Negative controls:** each fails a spec: no drape (3 fail), tolerance 1 stud (1), the sleeve
  never or always cutting (3 each), heights lerped instead of taken from the portal (3), and
  either sleeve bound frozen (3 and 2).

## Heron nodes (2026-10-01, Track G, ruled)
- **Ruling:** "Heron, gated (Recommended)", after a second research round on what other
  engines do (`proto/g-areabend`, `docs/plans/navmesh/research/path-length-standard-fixes.md`).
  No mainstream engine guarantees shortest paths. Detour, Unity, Unreal and Godot all use one
  node per polygon plus a funnel.
- **As built in `Search.luau`:** an edge node sits at the edge point minimising |parent - x| +
  |x - goal|, the goal reflected across the edge when it is on the parent's side. It is used
  only when every multiplier is 1 (or excluded) and the heuristic scale is 1 (no link cheaper
  than walking). Otherwise, and at seam portals, nodes stay at midpoints.
  - The prototype kept nodes r off wall-vertex ends. That was dropped: no spec could see it,
    and lengths and success counts moved within noise either way.
- **Numbers:**
  - Prototype, 32k pairs against the exact oracle: p95 1.074 to 1.0036, max 2.33 to 1.23,
    paths over 1% too long 19.5% to 2.7%.
  - As built, FindPath us per call on bench scenes against the same code with midpoints:

    | scene | r 0 | r 1 |
    |---|---|---|
    | props | 150 to 72 | 181 to 187 |
    | bench | 207 to 100 | 242 to 155 |
    | walls | 65 to 67 | 85 to 84 |

  - Repro 4's room with two area patches (uniform costs): 88 of 300 paths bent (worst 1.18x)
    with midpoints, against 7 (worst 1.014x) with heron.
- **Specs:**
  - The node-chain oracle now recomputes heron nodes for uniform-cost cases and midpoints for
    the others, so it checks the gate both ways. `Search.HeronPoint` is exported for it.
  - A* = Dijkstra is checked with midpoint nodes, selected by a multiplier of 2 on an unused
    area. Heron nodes depend on the route to them, so there is no fixed graph to agree on.
  - The convex-room spec (PathShape): no path over 1.02x the straight line, and at most 15 of
    300 bend.
- **Negative controls:** each fails a spec: heron off (2 fail), the multiplier gate ignored (2),
  and the link gate ignored (1).
- **Found while measuring (known-gaps.md):** with an agent radius, which node model runs
  decides Success or Partial for about 7 of 260 `props` queries, both ways. Both flipped pairs
  checked are connected by the grid flood. The search closes a triangle by its first entry, and
  a dead-end entry can lock out a better one. This predates heron.

## Weighted paths (2026-10-01, Track G, ruled)
- **Ruling:** "Cost-aware funnel + exact edge costs (Recommended)", after the research on
  `proto/g-areabend` (`docs/plans/navmesh/research/weighted-paths.md`, with a validated
  weighted reference, `WeightedOracle.luau`).
- **Exact edge costs, in `Search.luau`:** a step from a node to the next edge's node lies in one
  triangle and costs its multiplier. The last step into the goal's triangle is split where it
  crosses the edge. It was the mean of the two multipliers. This is Detour's rule, and the
  search's cost is now that of a real line.
- **The cost-aware funnel, in `Funnel.luau` (`refract`):**
  - With `AreaCosts`, each run of a piece between links is pinned on every portal where the
    multiplier changes. Pins start at portal midpoints; starting them where the plain path
    crosses was measured and changed neither time nor result, so it was dropped.
  - Each sweep pulls the path through the pins. The pins then settle against the path points
    either side of them, or against each other where no corner lies between: a golden-section
    step on m1 |p - x| + m2 |x - q| along the portal, repeated up to 200 times without a pull.
  - Sweeps repeat (up to 32) until a pull no longer moves a pin, so a corner the bent path
    meets moves the pins again.
  - The drape treats a pinned portal the path crosses head-on as a crossing point.
  - The prototype re-ran the funnel about 100 times per pin per sweep (3x FindPath). This
    version needs one pull per sweep.
- **Numbers:**
  - Against the reference (4,350 routes, radius 0), as built: mean 1.0219, p95 1.128, worst
    1.994, 24.3% over 1%. Before: 1.043, 1.212, 3.09 and 35%. This matches the prototype.
  - Weighted FindPath, us per call, old vs new:

    | scene | r 0, mud x5 | r 1, mud x5 | r 0, mud x0.5 |
    |---|---|---|---|
    | props | 149-161 vs 150-167 | 176-189 vs 178-187 | 291-297 vs 291-307 |
    | bench | 231-235 vs 236-249 | 259-267 vs 266-288 | 431-453 vs 530-531 |

  - Queries with no `AreaCosts` skip all of this.
- **Specs** (PathShape):
  - Snell's law at a border, and at both borders of a mud strip (residual under 1e-4);
  - a corner the bent path meets moves the pin again;
  - two pins with a crate corner between them each bend towards the corner;
  - a pin crossed head-on still gets its crease waypoint;
  - on repro 4's room (patch x5 and x0.5), the path is never dearer than the plain funnel's on
    the same corridor, by an exact rectangle-clip cost in the spec, and cheaper on at least 10
    of 120.
  - The node-chain oracle now prices steps by Detour's rule, with its own crossing math.
- **Negative controls:** each fails a spec: refract off (2 fail), the drape's pinned-portal
  case (1), multipliers swapped (2), one settling pass (1), one sweep (1), pins settled
  against the portal ends (2), and a neighbouring pin taken for the point beside a pin, either
  side (1 each). Mean edge costs instead of Detour's rule fail the node-chain
  spec (2).
- **Left as it is:** the corridor choice. The rest of the excess is the same "wrong side of an
  obstacle" error as before. Weighted heron and Steiner points were measured and rejected
  (research doc).

## Measured, not built (2026-10-01, Track G)
- **The area-edge bend is not an area effect** (now fixed by heron nodes for uniform costs). It comes from A* nodes at entry-edge midpoints.
  - The reference is an exact shortest path: a visibility graph over reflex wall vertices, with
    exact sightline tests. It was validated on a convex room (ratio exactly 1) and on a
    hand-solved room, with three negative controls.
  - Over 31,989 pairs (r 0, equal costs, 15 small flat scenes), FindPath / shortest has mean
    1.0123, p95 1.0736, p99 1.182 and max 2.33. 19.5% of paths are more than 1% too long.
  - Removing areas moves the mean by under a point, except repro 4's convex room.
  - "Heron" nodes put the node at the point of the entry edge minimising |parent - x| + |x -
    goal|, gated to queries whose area multipliers are all 1. They give p95 1.0036 and max 1.23,
    with 2.7% over 1%. FindPath takes 0.48x the time at r 0 and 0.80x at r 1.
  - A shortcut post-pass gives p95 1.060 at 3.5x the time. Theta*-like any-angle search is worse
    and slower.
  - Branch `proto/g-areabend`, `docs/plans/navmesh/research/path-length.md` there, with the
    oracle `tools/navmesh/bench/PathOracle.luau`.
- **The bisector-offset funnel.**
  - Off-portal offsets bend the corridor: without a post-check, 0.7-8% of paths on the dense
    `bench` map cross a wall.
  - With the post-check (`checked-t`), sparse maps keep exactly 1.00 r. Dense maps keep their
    worst case (0.01-0.08 r), because 10-47% of paths fall back. FindPath is 1.6-2.3x slower.
  - **Correction:** the low clearance is at turns, not on straight stretches. In 79-100% of
    today's paths the worst point is within 1.5 r of a turn waypoint.
  - Branch `proto/g-bisector`, `docs/plans/navmesh/research/bisector-funnel.md` there, with
    `tools/navmesh/bench/funnel_clearance.luau`.

## Track G merge gate (2026-10-01)
- `lune run coverage.luau package=navmesh --mutate --mutate-files=src/Funnel.luau,src/NavMesh.luau,src/Search.luau`:
  291 specs pass, 98.8% of statements.
- Mutation, against `mutation-baseline.md`: Funnel 85.9% (83.3), NavMesh 94.9% (94.7), Search
  89.7% (84.0).
- New survivors were triaged and the real ones killed with specs (tickets 27 and 28 list
  them). Those left are equivalent:
  - `FirstAffectedSegment`'s prefilter (a speed reject only), `axis = 0`, `first + 0`, and
    `inf % 1`;
  - the end check's nudge direction in Z;
  - `startCut = true`, whose end-selection role the end check now shares, and whose re-entry
    role ticket 27 found unreachable on buildable meshes.
- **After the weighted follow-up (same command):** 297 specs pass, 98.9% of statements;
  Funnel 85.4%, NavMesh 94.9%, Search 88.9%. The refraction loop's surviving mutants are its
  stopping thresholds and loop caps, which change only when it stops, plus golden-section ties.

**Where the research lives (2026-10-01):** the four write-ups (`path-length.md`,
`path-length-standard-fixes.md`, `weighted-paths.md`, `bisector-funnel.md`) are copied into
`docs/plans/navmesh/research/` on `feat/navmesh`. Their bench tools (the exact and weighted
references `PathOracle.luau` and `WeightedOracle.luau`, the prototypes, `funnel_clearance.luau`)
stay only on `proto/g-areabend` and `proto/g-bisector`. Keep those branches if the numbers
need re-running.
