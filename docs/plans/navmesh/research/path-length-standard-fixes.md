# Paths longer than needed: what other navmesh systems do, measured (ticket 25)

Branch `proto/g-areabend` (2026-10-01). This follows `path-length.md` (same branch), which built
the exact shortest-path oracle and measured the heron, shortcut and Theta*-like prototypes. This
note answers "what are the standard fixes?" from primary sources, then measures the ones not yet
measured, against the same oracle, scenes and pairs. Nothing here is merged; every prototype is a
bench mode that is off unless installed.

## Summary
- **No production engine guarantees the shortest path.**
  - Detour, Unity, Unreal and Godot all run A* on one point per polygon, then a funnel.
  - Unity's docs and the Recast maintainers say in writing that the path is not always the
    shortest.
  - What they ship instead:
    - Detour repairs the corridor while the agent walks (a raycast ahead each frame, and a small
      re-search every 0.5 s).
    - Godot places each node better: the point on the portal closest to the parent's point.
    - Detour also has an opt-in Theta*-style option, off by default.
- **The exact answer exists, but only in research code and only for our simplest case.**
  - Polyanya (2017) is optimal any-angle search on a navmesh.
  - It covers a point agent (r = 0) with all costs equal: no agent radius, no area costs.
- **Measured here (31,989 pairs, r = 0, equal costs):**
  - **Polyanya is exact on every pair, at 1.1-2.1x today's FindPath time** (1.4x on a
    35k-triangle map). The same 2 specs fail as with heron.
  - **Steiner points (several fixed nodes per edge)** are the textbook fix for weighted areas.
    - With 9 points per edge: p95 1.0009, at 15-28x the time.
    - With area costs they make paths cheaper on average only when the funnel is pinned at area
      changes (2-4% cheaper on average), and single paths can still be up to 2.5x costlier.
  - **A DetourCrowd-style follower** (raycast to the corner after next, re-plan every 0.5 s)
    moves p95 from 7.8% to 6.8% too long. It costs about 23 raycasts and 3.7 FindPaths per
    walk.
  - **Kallmann's "visibility metric"** (the published cousin of heron) is *worse* than
    midpoints on our meshes: p95 1.17, max 2.86.
- **Recommendation unchanged: heron, gated to uniform costs** (option 1 below).
  - It is the cheap end of the same family Godot, Mononen and Kallmann use.
  - It is the only measured fix that is also faster than today.
  - Take Polyanya only if an exact r = 0 guarantee is worth a second search module.

## 1. Survey (primary sources)
Code links are pinned:
- RC = https://github.com/recastnavigation/recastnavigation/blob/9f4ce64458dfae86e1239c525ddc219c4e9e06f1/
- GD = https://github.com/godotengine/godot/blob/084a2caa05119b625a99b6b51d44b459a26362de/

The survey was read by a research subagent; I re-read Kallmann's metric definitions myself (see
1.6).

### 1.1 Recast/Detour
- **findPath.**
  - A* over polygons. A node's position is the midpoint of the portal it was *first* reached
    through, and it is not moved when the node is reparented (RC
    Detour/Source/DetourNavMeshQuery.cpp L1080-1086, `getEdgeMidPoint` L2355-2366).
  - Cost is `dtVdist(pa, pb) * m_areaCost[area]` (L79-100). The heuristic is distance × 0.999
    (`H_SCALE`, L103, L1116). It is not scaled by the smallest area cost, so it is inadmissible
    below cost 1.
  - Up to 4 nodes per polygon exist, but only for the side a tile border was crossed from
    (DetourNode.h L35-47; PR #17, https://github.com/recastnavigation/recastnavigation/pull/17).
- **`DT_FINDPATH_ANY_ANGLE`** (DetourNavMesh.h L122-125): Theta*-style.
  - When expanding, it raycasts from the parent's node to the neighbour's (with
    `DT_RAYCAST_USE_COSTS`), and on a clear ray takes the grandparent as parent
    (DetourNavMeshQuery.cpp L1405-1418).
  - It only does this within `walkableRadius * 50` (L141, L1245-1253), only in the sliced API,
    and never across off-mesh links.
  - It is off by default; PR #17's history records "changed the default options of the
    pathfinder to 0 (i.e. no raycasts)". No guarantee is stated.
- **findStraightPath** is the funnel (L1793-2022). Its `AREA_CROSSINGS` / `ALL_CROSSINGS`
  options only *add* vertices at portal crossings (DetourNavMesh.h L114-118); they do not change
  the path.
- **DetourCrowd corridor repair** (DetourPathCorridor.cpp L157-196: "Every time a move function
  is used there is a chance that the path will become non-optimal... periodically running
  optimizePathTopology() and optimizePathVisibility()"):
  - `optimizePathVisibility` (L293-347):
    - raycasts from the agent to the corner after next (DetourCrowd.cpp L1112-1117), every
      update;
    - range `pathOptimizationRange`, documented as "radius * 30" (DetourCrowd.h L444-449);
    - it splices the ray's polygons into the corridor when the ray reaches. The ray ignores area
      costs.
  - `optimizePathTopology` (L353-378) re-runs a sliced findPath from the corridor start for 32
    iterations and merges the partial result. The crowd runs it for at most one agent per update,
    each agent at most every 0.5 s (`OPT_TIME_THR`, `OPT_MAX_AGENTS`, DetourCrowd.cpp L907-936).
- **Acknowledged as suboptimal:**
  - issue #106, "findPath might not always generate the shortest path": the maintainer calls it
    "a really tough problem", and the acceptable trade-off is "raycasting a few refs ahead"
    (https://github.com/recastnavigation/recastnavigation/issues/106);
  - issue #239: "a side-effect of the choice of node locations... where there are large polys
    next to small ones" (https://github.com/recastnavigation/recastnavigation/issues/239);
  - Mononen's blog posts "Navmesh node locations" (2010,
    http://digestingduck.blogspot.com/2010/08/navmesh-node-locations.html) and "Towards better
    navmesh path planning" (2010,
    http://digestingduck.blogspot.com/2010/05/towards-better-navmesh-path-planning.html). The
    second proposes the edge's crossing with the segment to the goal, else the edge end nearest
    the goal: Kallmann's metric below.

### 1.2 Unity
- A* over polygons, then "steering towards the next visible corner"; the corridor is "locally
  adjusted as the agent's position moves"
  (https://docs.unity3d.com/Packages/com.unity.ai.navigation@2.0/manual/NavInnerWorkings.html).
- The Areas and Costs page
  (https://docs.unity3d.com/Packages/com.unity.ai.navigation@2.0/manual/AreasAndCosts.html):
  - costs must be ≥ 1;
  - "The pathfinder does not always choose the shortest path... the nodes on the big polygons may
    get placed anywhere in the big polygon".
- No documented corridor-optimisation setting. Unverified: that Unity is Recast-derived (only
  Recast's README says so).

### 1.3 Unreal
- Engine source is private, so this comes from the API docs only.
- The Detour fork keeps `getEdgeMidPoint`. Its `initSlicedFindPath` has no options parameter, so
  no any-angle (https://dev.epicgames.com/documentation/en-us/unreal-engine/API/Runtime/Navmesh/dtNavMeshQuery).
- `dtQueryFilter` adds a heuristic scale and per-area fixed entry costs.
- No documented optimality fix.

### 1.4 Godot (its own A*; Recast only bakes)
- **Node position.** The entry point is the point on the portal closest to the parent's entry
  point, recomputed when the node is reparented (GD
  modules/navigation_3d/3d/nav_mesh_queries_3d.cpp L293-308).
  - That is our `nearest` prototype: mean 1.0063, p95 1.039, 8 specs fail (`path-length.md`).
- **Costs** are per region: travel cost × distance plus an enter cost (GD
  doc/classes/NavigationRegion3D.xml L83-94).
- **Post-processing:** the corridor funnel (default), edge-centred points, or none. An optional
  Ramer-Douglas-Peucker simplify only removes points (GD
  doc/classes/NavigationPathQueryParameters3D.xml L30-75).
- **Radius** is baked into the mesh (GD doc/classes/NavigationMesh.xml L95-97).

### 1.5 Roblox PathfindingService
- The docs say ComputeAsync "returns the shortest path... with the exception that it attempts to
  avoid jumps" (https://create.roblox.com/docs/characters/pathfinding).
- The algorithm is undocumented. Unverified whether "shortest" holds.

### 1.6 Literature
- **TA* / TRA\*** (Demyen & Buro, AAAI 2006, https://cdn.aaai.org/AAAI/2006/AAAI06-148.pdf):
  - **Search.** States are triangles, with g and h as *lower bounds* over the entry edge.
  - **Anytime.** It keeps searching after the first path until the best path ≤ the smallest
    remaining f, which proves optimality.
  - **Radius.** Exact per-triangle width tests for radius, plus a radius funnel.
  - **Quality.** Their own figure for TA* given 10x the first path's time: within 4% of optimal
    75% of the time, within 6% 95% of the time.
  - **Scope.** No area costs.
- **Polyanya** (Cui, Harabor & Grastien, IJCAI 2017, https://www.ijcai.org/proceedings/2017/0070.pdf):
  - **Search.** Nodes are (interval on an edge, root vertex). Expanding projects the interval
    across the next polygon, and the root changes only at obstacle corners.
  - **Bounds and pruning.** h is the Heron distance through the interval; pruning keeps the best
    g per root.
  - **Guarantee.** Optimal in one search. Competitive with TA*(F=1) or up to 2.5x faster.
  - **Scope.** Planar, no radius, no weights. The vleue Rust port adds layers and handles radius
    by offsetting the mesh polygons (https://github.com/vleue/polyanya,
    https://github.com/vleue/vleue_navigator).
- **Kallmann** (SCA 2010, "Shortest Paths with Arbitrary Clearance from Navigation Meshes",
  http://graphics.ucmerced.edu/papers/10-sca-tripath.pdf, section 5, read directly):
  - **Four node metrics.** He compares centroid, edge midpoint, a "visibility" metric, and that
    metric kept r from the edge ends. The visibility metric is: "If the segment connecting q [the
    goal] to the reference point of the previous traversal intersects e, then the intersection
    point is taken, otherwise the vertex of e which is closest to q".
  - **No guarantee.** He states "it is not possible to obtain a metric which will always return
    globally optimal solutions".
  - **Global search is optional.** A branch-and-bound over funnel fronts reaches the global
    optimum, at about 100x the local search's time in his example (401.92 ms vs 3.11 ms).
  - **Radius.** It is a per-query clearance test, as in our Clearance.
- **Weighted regions:**
  - The exact problem is not solvable in the algebraic computation model over the rationals
    (de Carufel et al. 2014, https://arxiv.org/pdf/1305.5209).
  - Mitchell & Papadimitriou 1991 give an ε-optimal algorithm with an O(n^4)-size map
    (https://doi.org/10.1145/102782.102784).
  - The practical (1+ε) method is Steiner points on edges (Aleksandrov, Maheshwari & Sack 2005,
    https://doi.org/10.1145/1044731.1044733).

### 1.7 Comparison

| system | node placement / search | guarantee | radius | area costs | links / floors |
|---|---|---|---|---|---|
| Detour findPath + funnel | edge midpoint, fixed at first visit | none (issues #106, #239) | baked into the mesh | yes | yes |
| Detour ANY_ANGLE | Theta*: raycast to grandparent, ≤ 50 r | none; off by default | baked | yes (costed ray) | ray skips links |
| DetourCrowd VIS / TOPO | ray to corner after next each update; 32-step re-search every 0.5 s | repair only | baked | VIS ignores costs | – |
| Unity | "a point on each polygon" | "not always the shortest" | baked | costs ≥ 1 | yes |
| Unreal | Detour fork, no any-angle | none documented | baked | yes, plus entry cost | yes |
| Godot | closest portal point to the parent's | none | baked | per region | yes |
| Roblox | undocumented | docs say "shortest" (unverified) | AgentRadius | material costs | links |
| TA* | triangle states, lower bounds, anytime | optimal at convergence | exact widths | no | 2D |
| Polyanya | interval + root | optimal, one search | no (offset the mesh) | no | 2D (layers in vleue) |
| Kallmann | visibility metric; optional front search | local; global optional (~100x) | per query | no | 2D |
| Steiner points | k nodes per edge, graph search | (1+ε) as k grows | per transition | yes | – |

## 2. What was measured, and how
- **Setup.** Same oracle, scenes, seeds and pair generator as `path-length.md`: 16 small flat
  scenes, r = 0, no AreaCosts.
  - 2000 pairs per scene (31,989 reachable) unless a row says otherwise.
  - The ratio is FindPath's 3D polyline length over the oracle's length.
- **Times.** `findpath_modes_ab.luau`: 400 pairs on each bench scene, passes interleaved with
  the order rotated, median of 7, all modes in one run.
- **Already covered in `path-length.md`:**
  - Detour's ANY_ANGLE is the `theta` prototype.
  - Godot's placement is `nearest`.
  - A shortcut post-pass is `shortcut`.
- **New modes:**
  - `polyanya` (`tools/navmesh/bench/Polyanya.luau`, about 300 lines):
    - Polyanya on triangles, with observable and non-observable successors, root-level pruning,
      and a root sitting on a vertex of the next triangle seeing all of it.
    - Its node chain gives the corridor, which the normal funnel pulls (back to the same taut
      path).
    - It runs only at r = 0, with every multiplier 1 or excluded, and no links or seams. Anything
      else, and a search that finds nothing, falls back to the library search.
  - `steinerN` (`Steiner.luau`):
    - N fixed points per portal edge: the midpoint for N = 1, else N evenly spaced points
      including the ends. A point is one node shared by both triangles.
    - A segment to any point on another edge of either triangle costs length × that triangle's
      multiplier.
    - It is a fixed graph, so A* with the SR7 heuristic is exact on it.
    - `+pin` funnels each run of equal multiplier separately, pinned at the graph's crossing
      point between runs. The plain funnel is blind to costs.
  - `kallmann`: Kallmann's visibility metric as quoted above, kept min(r, half the edge) from
    wall ends (his fourth variant at r > 0).
  - `follow <mode> <variant>`: a DetourCrowd-style follower, simulated.
    - It walks the path in 0.5-stud steps (16 studs/s at 30 Hz).
    - `vis`: each step, a point raycast from the agent to the corner after next; when clear, the
      next corner is dropped. The range is unlimited, so this is an upper bound on Detour's
      `30 r` range.
    - `topo`: every 8 studs (0.5 s), a full FindPath re-plan from where it stands, taken
      unconditionally. This is an upper bound on Detour's 32-iteration local re-search.
    - The ratio is walked length over the oracle's. Its time is all its queries (FindPaths and
      raycasts) over one FindPath.
- **Not prototyped:**
  - **TA\*.** Its own paper puts it at 6% p95 after 10x the first path's time. Heron is already
    at 0.36% p95, and Polyanya is exact and reported faster than TA*.
  - **Kallmann's front search:** about 100x by his own numbers.

## 3. Results

### 3.1 Length, r = 0, equal costs (all pairs)

| fix | mean | p50 | p95 | p99 | max | > 1.01x | specs (of 271) |
|---|---|---|---|---|---|---|---|
| today (midpoint) | 1.0123 | 1 | 1.0736 | 1.1820 | 2.3335 | 19.5% | 271 |
| heron, gated to uniform costs (`path-length.md`) | 1.0009 | 1 | 1.0036 | 1.0225 | 1.2331 | 2.7% | 269 |
| shortcut post-pass (`path-length.md`) | 1.0094 | 1 | 1.0597 | 1.1618 | 2.3335 | 14.5% | 271 |
| Theta*-like, cf. Detour ANY_ANGLE (`path-length.md`) | 1.0072 | 1 | 1.0422 | 1.1429 | 2.3335 | 12.0% | 266 |
| Godot-like `nearest` (`path-length.md`) | 1.0063 | – | 1.039 | – | – | – | 263 |
| **Kallmann visibility metric** | 1.0271 | 1 | 1.1696 | 1.3801 | 2.8606 | 23.7% | 267 |
| **Polyanya** | **1 (exact)** | 1 | 1 | 1 | 1 | 0% | 269 |
| **Steiner, 3 per edge** (200 pairs/scene) | 1.0054 | 1 | 1.0300 | 1.1008 | 1.3509 | 11.8% | – |
| **Steiner, 5 per edge** | 1.0015 | 1 | 1.0071 | 1.0318 | 1.5587 | 3.9% | – |
| **Steiner, 9 per edge** | 1.0003 | 1 | 1.0009 | 1.0077 | 1.5587 | 0.7% | 270 |

- **Polyanya:** not one of 29,963 searched pairs differs from the oracle beyond the 1e-6 check
  (the other 2,026 have both ends in one triangle, where every mode draws the straight line). The
  run would error on any pair shorter than the oracle.
- **Steiner's 1.56 max** is on repro 4, at N = 5 and N = 9 alike. Not investigated pair by
  pair. The room has only 8 triangles, with edges up to about 40 studs, so points are about 5
  studs apart even at N = 9. Fixed spacing gives no relative bound for short paths across long
  edges.
- **Kallmann's metric loses to midpoints** here because of its fallback. When the segment
  parent → goal misses the edge, the node jumps to an edge end, which on our long CDT edges is
  far off. Heron's reflection is what makes the goal-ward idea work.
- **Spec failures:**
  - Polyanya and heron fail the same 2 model-pinning specs: "a path's cost is the cost of its own
    node chain" and "A* finds Dijkstra's costs" (the Dijkstra run uses a 0 multiplier, so it
    falls back to the midpoint search).
  - Steiner fails only the first; it is a fixed graph, so A* = Dijkstra holds.
  - Kallmann also fails "the funnel is the tight string" and "a cheap link behind the start".

### 3.2 FindPath time, r = 0 (µs per call, ratio to today)

| scene (triangles) | today | heron | Polyanya | Steiner 3 | Steiner 5 | Steiner 9 |
|---|---|---|---|---|---|---|
| props (3152) | 156.3 | 76.6 (0.49) | 176.3 (1.13) | 714 (4.6) | 1161 (7.4) | 2445 (15.6) |
| bench (4605) | 235.0 | 111.5 (0.47) | 291.0 (1.24) | 1114 (4.7) | 1835 (7.8) | 3669 (15.6) |
| terrain (1297) | 85.1 | 62.6 (0.74) | 121.5 (1.43) | 361 (4.2) | 608 (7.2) | 1299 (15.3) |
| walls (692) | 55.7 | 55.8 (1.00) | 115.2 (2.07) | 299 (5.4) | 611 (11.0) | 1551 (27.9) |
| bench density at 768 studs (34,862) | 1393 | 451 (0.32) | 1958 (1.41) | – | – | – |

- **Total length vs today** on these 400-pair sets:
  - heron 0.970-0.999;
  - Polyanya 0.968-0.997;
  - Steiner 9 0.970-0.998.
- **Polyanya's work:** 1.1-1.2 nodes generated per expansion. Expansions per call are 260
  (props), 467 (bench) and 3,450 (768 studs), against 432 / 657 open-list pops for today's
  search on props / bench.
- **Run-to-run noise:** an earlier run of the same comparison gave Polyanya 1.09 / 1.32 / 1.58 /
  1.97x.
- **Unoptimised:** Polyanya is a bench file without the paper's intermediate and dead-end
  pruning and without Search's inlined buffer reads, so its ratios are an upper bound.
- **Unreachable goals:** Polyanya then searches everything and falls back, so it pays twice.
  Not timed.

### 3.3 Area costs (no oracle: weighted cost of the returned path vs today's, same pairs, r = 0)
Weighted cost = plan length × multiplier per triangle walked. There are 21 rows: 7 scenes with
areas × multiplier 2, 5 and 0.5, 400 pairs each.

| fix | mean cost vs today, per row | cheaper / costlier pairs per row | worst single pair |
|---|---|---|---|
| heron, gated | identical (it does not run) | 0 / 0 | 1 |
| Polyanya | identical (it does not run) | 0 / 0 | 1 |
| Steiner 9, plain funnel | 0.979-1.125; worse at multiplier 5 | 16-251 / 21-140 | 3.90 |
| Steiner 9, pinned funnel | 0.957-0.986 | 69-316 / 13-77 | 2.53 |

- **The plain funnel undoes Steiner's graph.** The funnelled path's walked cost is up to 1.40x
  the graph path's (repro 4, multiplier 5), because the funnel straightens through expensive
  triangles the graph went round.
- **Pinning the funnel at multiplier changes** fixes most of it.
  - Mean cost is 1.4-4.3% below today's in every row, but single pairs are still up to 2.5x
    costlier.
  - Walked cost still exceeds graph cost in aggregate (up to 1.16x on repro 4, multiplier 5).
  - Likely cause: graph paths that run exactly along an area's edge, which the bench's cost walk
    may count on the expensive side. Not verified.
- **Today's search overestimates.** The walked cost is 0.78-0.91x the search's cost, because
  midpoint nodes overprice routes.

### 3.4 DetourCrowd-style repair while walking (300 pairs per scene, 4,799)

| follower over | variant | mean | p95 | p99 | max | > 1.01x | FindPaths / raycasts per walk | query time vs one FindPath |
|---|---|---|---|---|---|---|---|---|
| today | none | 1.0129 | 1.0779 | 1.2054 | 1.4842 | 19.9% | 1 / 0 | 1 |
| today | vis | 1.0103 | 1.0680 | 1.1982 | 1.4842 | 14.2% | 1 / 23.3 | 7.0 |
| today | topo | 1.0127 | 1.0759 | 1.1877 | 1.4842 | 20.4% | 3.7 / 0 | 3.2 |
| today | vis + topo | 1.0104 | 1.0683 | 1.1812 | 1.4842 | 14.9% | 3.7 / 23.4 | 9.8 |
| heron | none | 1.0009 | 1.0032 | 1.0217 | 1.1798 | 2.6% | 1 / 0 | 1 |
| heron | vis + topo | 1.0007 | 1.0006 | 1.0172 | 1.1983 | 1.9% | 3.7 / 22.8 | 10.4 |

- **The raycast helps a little, for the same reason the shortcut post-pass does.** The excess is
  mostly a corridor round the wrong side of an obstacle, and a chord to the next-but-one corner
  is blocked by that obstacle.
- **Re-planning with the same midpoint search does not help at all.** It also makes some walks
  longer (the >1.01x share goes up), since each re-plan can pick a different wrong corridor.
- **Its time is spread over the walk**, so per frame it is one raycast. But it fixes the walk,
  not the `FindPath` result, and this library's `Follower` would need it built in.
- **No walk went through a wall:** none came in more than 1e-4 under the oracle; smaller gaps
  are f32 stepping.

## 4. Options

| option | length (r = 0, equal costs) | time | area costs | radius | cost to us |
|---|---|---|---|---|---|
| 1. Heron nodes, gated to uniform costs (`path-length.md` option 3) | p95 1.0036, max 1.23 | 0.3-1.0x | unchanged | unchanged rules; heron only changes the choice | about 25 lines in Search; 2 specs rewritten |
| 2. Polyanya for r = 0 with uniform costs, plus 1 for the rest | exact at r = 0 | 1.1-2.1x at r = 0 (1.4x at 35k triangles) | unchanged | r > 0 gets heron | a second search module (about 300 lines) and its own specs; links and seams unsupported |
| 3. Follower repair (DetourCrowd style) | p95 1.068 (today) / 1.0006 (on heron) | about 1 raycast per frame, plus a re-plan every 0.5 s | the ray ignores costs (as in Detour) | needs a radius-aware ray | Follower changes; FindPath's result unchanged |
| 4. Steiner points (N = 5-9) | p95 1.0071-1.0009 | 7-28x | 1.4-4.3% cheaper on average, single paths up to 2.5x costlier | per-transition widths possible, not built | a fixed-graph search plus a pinned funnel |

- **Recommendation: option 1 now; option 2 only if "shortest at r = 0" should be a guarantee.**
  - Heron is the same idea the literature and Godot converge on: the node goes towards the goal,
    not to a fixed point. With Heron's reflection it beats both published variants on our meshes:
    - Godot's nearest point: p95 1.039;
    - Kallmann's metric: p95 1.17.
  - It is the only fix that makes FindPath faster.
  - Polyanya is the one exact answer, and here it costs little more than today's search. But it
    covers only r = 0 with uniform costs and no links, so heron is needed beside it anyway. Its
    gain over heron is the last 0.36% at p95 (max 1.23 → 1).
- **Not recommended:**
  - Steiner points: too slow for a modest gain on weighted paths, with the funnel needing
    rework.
  - Kallmann's metric as published.
  - Re-planning while walking.
  - The follower raycast is cheap and standard, but small: worth it only as a Follower feature
    on top of heron, if at all.

## 5. What I could not measure or verify
- **No oracle for r > 0, area costs other than 1, links, seams or multi-floor.**
  - Polyanya and Steiner fall back to today's search there, so they are unmeasured there by
    construction.
  - Steiner's weighted numbers are against today's paths, not against an optimum.
- **Polyanya with radius.**
  - The standard route is an eroded mesh per radius (Recast and Godot bake it; vleue offsets the
    polygons).
  - Adding Search's corner-width checks to Polyanya's transitions would make its root-level
    pruning unsound. Not tried.
- **The Steiner pinned-funnel gap** (walked cost above graph cost) is unexplained; the
  boundary-riding explanation is a guess.
- **Unity, Unreal and Roblox internals are not public.** Their rows are from docs only.
  Unreal's `bUseBetterOffsetsFromCorners` page returned 403.
- **The follower is a simulation in Lune.** It is not this library's `Follower`, and its range
  and re-search are upper bounds on Detour's.
- **Timings are Lune on this machine, with prototypes in bench files.** Ratios come from
  interleaved passes.

## Reproduce (from the worktree root)
```
lune run tools/navmesh/bench/path_length_oracle.luau measure polyanya 2000
lune run tools/navmesh/bench/path_length_oracle.luau measure steiner9 2000      # steiner3 / steiner5; +pin
lune run tools/navmesh/bench/path_length_oracle.luau measure kallmann 2000
lune run tools/navmesh/bench/path_length_oracle.luau weighted base steiner9 400   # and steiner9+pin
lune run tools/navmesh/bench/path_length_oracle.luau follow base vis+topo 300     # none / vis / topo; over heronuniform too
lune run tools/navmesh/bench/path_length_oracle.luau specs polyanya              # 269; steiner9 270; kallmann 267
lune run tools/navmesh/bench/findpath_modes_ab.luau base,heronuniform,polyanya,steiner3,steiner5,steiner9 0
lune run tools/navmesh/bench/findpath_modes_ab.luau base,heronuniform,polyanya 0 big
```
