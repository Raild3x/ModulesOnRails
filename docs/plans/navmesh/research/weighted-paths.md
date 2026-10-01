# Weighted paths: how far from the cheapest, and what fixes it (ticket 25, weighted queries)

Branch `proto/g-areabend` (2026-10-01). This follows `path-length.md` and
`path-length-standard-fixes.md`. Those covered unweighted queries, where the user ruled heron gated
to uniform costs (being built on `navmesh-path-output`). This note covers the queries heron leaves
alone:
- AreaCosts multipliers other than 1;
- links cheaper than walking.

Today's midpoint search runs on all of these. Nothing here is merged; every fix is a bench mode
that is off unless installed.

## Summary
- **A trustworthy reference now exists** for weighted queries at radius 0, with links
  (`tools/navmesh/bench/WeightedOracle.luau`).
  - It is exact on unweighted scenes.
  - It matches closed forms to 1e-15: Snell's law at a two-area boundary, the critical-angle path
    that runs along a cheap edge, and ticket 16's warp.
  - Three negative controls are each caught.
  - It is converged in its density (K = 15 vs 31: within 1e-7 on nearly all pairs).
- **Today, weighted paths are well off the cheapest.** Over 4,350 pairs (radius 0; areas at 0.5,
  2 and 5; two link scenes):
  - mean +4.3%, p95 +21%, p99 +54%, worst 3.09x;
  - 35% of paths cost over 1% more than they need to.
  - That is 3-4 times worse than unweighted queries were (mean +1.2%, p95 +7%).
- **About half of the excess is the funnel.** Straightening ignores costs: it cuts across a
  muddy area the search went round, and it never bends at an area edge to save cost. A cost-aware
  funnel on today's corridor (`refract`) brings the numbers to mean +2.2%, p95 +13%, worst 2.35x,
  with all 271 specs passing.
- **The other half is the corridor choice.** No cheap fix gets it all.
  - **Weighted heron ("snell") plus refract:** mean +1.1%, p95 +5%. It breaks 5 specs, for the
    same reason ungated heron did: goal-ward nodes overprice routes that head away from the goal.
  - **Steiner points on every edge plus refract:** mean +0.1%, p95 +0.08% (9 points per edge).
    It costs 25-38x today's FindPath time in this prototype.
  - **Steiner points only on area edges** do not help: mean +2.0%, about the same as refract
    alone. The corridor errors are not at area edges.
- **No engine does better.**
  - Detour and Godot straighten paths ignoring costs. Godot's maintainer calls it "a general
    limitation".
  - Unity tells users to treat costs "as hints".
  - Exact weighted shortest paths are provably not computable in closed form.
- **Recommendation:** ship the cost-aware funnel (`refract`), with Detour-style exact edge costs
  (free, and they remove the worst case). Leave corridor choice to a later, opt-in Steiner search
  if weighted quality ever needs to be near-exact. Details in [Options](#options).

## 1. What is known (primary sources)
The survey was done by a research subagent from papers, docs and pinned source. Recast is pinned
at `9f4ce64458dfae86e1239c525ddc219c4e9e06f1`, Godot at
`084a2caa05119b625a99b6b51d44b459a26362de`.

### The theory
- **Snell's law.** Cheapest paths are straight inside an area and bend at area edges, by Snell's
  law: `c1 sin a1 = c2 sin a2`, angles from the edge's normal (Mitchell & Papadimitriou 1991, as
  restated in de Berg et al., https://arxiv.org/pdf/2402.12028 §2).
- **Running along an edge.** Coming from the dear side, a path never meets an edge at more than
  the critical angle `sin a = c_cheap / c_dear`. A path may run along an edge between two areas
  ("critical reflection"), paying the cheaper one (same source; Inkulu's slides,
  https://www.iitg.ac.in/rinkulu/talks/spweireg.pdf).
- **No exact answer exists.** The problem "cannot be solved in the Algebraic Computation Model
  over the Rational Numbers". It already fails for two weights and a single weighted quadrant (de
  Carufel et al. 2014, https://arxiv.org/pdf/1305.5209; de Berg et al., as above).
- **What is used instead: Steiner points**, i.e. extra nodes on edges.
  - Lanthier, Maheshwari & Sack (https://carleton.ca/scs/wp-content/uploads/sites/260/TR-96-32.pdf)
    find "a constant number of Steiner points per edge suffice", about 6 per edge in their
    experiments.
  - Aleksandrov et al. place points in a geometric progression away from each vertex and get a
    (1 + ε) bound (as described in Jaklin's thesis §4.1,
    https://webspace.science.uu.nl/~gerae101/pdf/PhD_Thesis_Norman_Jaklin-On_Weighted_Regions_and_Social_Crowds.pdf).
  - Tran et al. (ICAPS 2020, https://ojs.aaai.org/index.php/ICAPS/article/view/6673) found 6
  uniform points per edge "too far away" from Snell-exact paths. Uniform graphs only got close at
  about 400 points per edge.
  - **Our result:** 5-9 points per edge are enough *when followed by a cost-aware funnel*, and not
    enough on their own (table below).
- **Snell refinement of a fixed corridor** is the reusable piece of Tran et al. It is
  O(k log(L/δ)) per corridor of k edges, by ray bisection. Our `Refract` does the same job with
  golden section, which is slower.

### What engines do
- **Detour.**
  - A segment pays the area cost of the polygon it crosses: `dtVdist(pa,pb) * m_areaCost[area]`
    (DetourNavMeshQuery.cpp L79-84), charged for the polygon the node is expanded from
    (L1096-1116). It does not average two polygons' costs, as our Search does.
  - The heuristic is not scaled ("H_SCALE = 0.999", L103), and costs below 1 are discouraged
    (L58-59).
  - `findStraightPath` never reads costs (L1793-2020). `DT_STRAIGHTPATH_AREA_CROSSINGS` only adds
    points where the straight path already crosses an area change.
  - Off-mesh links are polygons with their own area cost.
- **Unity.** Costs are "distance * cost" per polygon, must be ≥ 1, and should be treated "as
  hints" (https://docs.unity3d.com/Packages/com.unity.ai.navigation@2.0/manual/AreasAndCosts.html).
  Whether its funnel ignores costs: unverified (closed source).
- **Unreal.** Per-area DefaultCost and FixedAreaEnteringCost; source private; straightening
  unverified.
- **Godot.**
  - Per-region travel and enter costs.
  - Its heuristic is the neighbour region's cost times distance, which is inadmissible above the
    cheapest cost (nav_mesh_queries_3d.cpp L305-307).
  - The funnel ignores costs (L735-830).
  - Maintainer on issue #66128 (https://github.com/godotengine/godot/issues/66128): "a general
    limitation".
- **Roblox.** Material and modifier costs, plus link costs. Smoothing is undocumented.
- **Research systems for games.**
  - MIRAN (Jaklin, Cook, Geraerts 2013) smooths with a terrain-weighted attraction point.
  - Vertex-Based Pruning (Jaklin et al., MIG 2014) runs a grid A* and then a Steiner search near
    it; it matched the full Steiner path on 97.3% of queries.
  - None handles a disc agent; erosion at bake time is the standard answer.

Our `HeuristicScale` already scales by the cheapest multiplier *and* the cheapest link per unit of
length, which is the admissible choice the literature asks for.

## 2. The reference (`tools/navmesh/bench/WeightedOracle.luau`)
- **Cost model:**
  - plan length × the multiplier of the area walked through;
  - a stretch exactly along the edge between two areas pays the cheaper one (the closed-region
    convention of the literature);
  - a link pays Cost × its area's multiplier.
- **Graph.**
  - **Nodes:** wall corners, and on every edge between two multipliers 15 evenly spaced points
    plus one a hair inside each end, plus the link ends.
  - **Edges:** two nodes are joined when they see each other inside one area. That is
    `PathOracle`'s exact visibility, with the area edges as extra walls.
  - With one multiplier this is `PathOracle` itself.
- **Refinement** (each step kept only when an independent pricing says it is cheaper):
  1. Area-edge points slide along their edges to the cheapest spot (Snell's law).
  2. The triangles the path walks become a corridor, and the cost-aware funnel (`Refract`) finds
     the cheapest path through it. This repeats while it improves.
  3. A second opinion: a Steiner graph on every edge (17 points per edge, links included) through
     the same funnel. The cheaper answer wins.
- **The result is a real path**, so its cost is an upper bound on the true optimum. The
  measurement also lowers it to the cheapest path any measured mode found. That happened on 21 of
  4,350 pairs, by at most 0.50%.
- **Pricing (`PolylineCost`)** uses no graph. It cuts each segment at every triangle edge, and
  charges each piece the cheapest triangle holding its midpoint, within 1e-5 studs: FindPath's
  points are f32, so a point placed on an edge can sit 4e-6 off it. It prices FindPath's output,
  every refinement step, and the reference.
- **Validation** (`lune run tools/navmesh/bench/path_weighted.luau validate`, 19 checks, all `ok`):
  - every multiplier 1, 4 scenes × 150 pairs: identical to the exact unweighted oracle (0
    difference);
  - two areas split at z = 20, multipliers 0.5, 2 and 5: matches the 1D closed-form minimum to
    5e-15, and `|sin1 - c sin2| < 2e-7` at the crossing;
  - critical angle (both ends in the ×5 half): 61.393876913 = the closed form `5h/cos a + (D - h
    tan a)`;
  - ticket 16's warp: 17 and 18.6, as the spec;
  - on 600 random weighted pairs, the reference's own sum equals `PolylineCost`'s to 2e-12, and
    the path stays on the mesh (sampled every 0.01 stud).
  - **Negative controls, each caught:**
    - "nocost" (multipliers ignored): 68% off;
    - "coarse" (wall corners only, no refinement): 96% off;
    - "norefine" (the graph path itself): 0.3% off.
- **Convergence** (`converge 3 7 15 31`, 60 pairs × 9 scenes at ×5 plus a cheap link):
  - K = 15 is within 1e-7 of K = 31 on all but one scene, soup #5, where the worst pair differs
    by 0.7% and the mean by 1e-4;
  - K = 7 is already within 1e-7 on 8 of 9 scenes.
- **Shared code (be aware).**
  - Step 2 is the same `Refract` the `refract` mode uses. A bug in `Refract` that makes paths
    too *cheap* is ruled out: every result is priced independently.
  - One that makes them too *dear* would hide in both. The closed-form checks above go through
    `Refract` (steps 2 and 3 run there) and pass to 1e-15.
- **Getting here took four tries;** the pitfalls are worth knowing.
  - A Steiner graph with fixed vertex nodes cannot slide off a vertex, which left 4% errors on
    unweighted scenes.
  - A corridor built from graph nodes at vertices was too narrow.
  - f32 vectors moved points off the edge they ride.
  - Pricing tolerances must match the f32 output.

## 3. Today, and the prototypes
- **Scenes:** every oracle scene with areas (repro 4's patch, the Courtyard, bench-like 64 with
  mud, its TileSize 8 version, soups #1, #2 and #5), plus two link scenes:
  - "strip + warp": ticket 16's 40 × 4 strip with a 38-stud warp;
  - "wall + hop + mud": a wall across a room, a hop through it, a long zip link, mud.
- **Multipliers:** area 2 at 0.5, 2 and 5; on the link scenes also links at 0.2. That gives 29
  rows of 150 seeded pairs (4,350).
- **Ratio** = the walked weighted cost of FindPath's polyline (`PolylineCost`) over the cheapest
  known.
- **Modes** (PathProtos, all off by default):
  - `exact`: a segment from a node to the next lies inside one triangle, so it pays that
    triangle's multiplier, as Detour does. Today's Search pays the mean of the two triangles'.
    The last leg into the goal is split where it crosses the edge.
  - `refract`: the cost-aware funnel (`Refract.luau`).
    - It cuts the corridor into runs of one multiplier and funnels each run.
    - It moves each pin between runs to its cheapest point on its portal (golden section,
      sweeping until nothing improves).
    - Links split it into pieces. Radius offsets apply inside runs, and pins keep min(r, half the
      portal) off wall ends.
  - `snell`: weighted heron. The node is the point of the entry edge minimising
    `m_t |parent - x| + scale |x - goal|`, by golden section. With every multiplier 1 it is
    heron.
  - `heronlib`: ungated heron (unweighted placement), for comparison.
  - `steinerN`: a Steiner graph search with N points per edge (ends included), links supported.
    `steinerbN` puts N points only on edges between two multipliers and keeps midpoints
    elsewhere.

### 3.1 Radius 0, all 4,350 pairs

| mode | mean | p50 | p95 | p99 | max | > 1.01x | FindPath time, bench map ×5 mud | specs (of 271) |
|---|---|---|---|---|---|---|---|---|
| today | 1.0432 | 1 | 1.2119 | 1.5393 | 3.0924 | 35.1% | 1x | 271 |
| exact | 1.0432 | 1 | 1.2146 | 1.5659 | 3.0924 | 35.2% | 1.00x (vs Search copy) | 270 |
| **refract** | **1.0225** | 1 | **1.1301** | 1.3276 | 2.3454 | 24.1% | **2.98x** (props/terrain/walls 1.05x) | **271** |
| **exact + refract** | 1.0218 | 1 | 1.1274 | 1.3084 | **1.9944** | 24.2% | 3.7x (3.1x vs copy) | 270 |
| snell + exact | 1.0276 | 1 | 1.1406 | 1.3938 | 3.4021 | 25.8% | 1.3x (1.1x vs copy) | 266 |
| snell + exact + refract | 1.0106 | 1 | 1.0503 | 1.1922 | 3.0391 | 13.7% | 6.7x (5.5x vs copy) | 266 |
| heronlib (ungated) | 1.0345 | 1 | 1.1768 | 1.4777 | 3.6896 | 28.9% | 0.7x | 266 |
| heronlib + refract | 1.0157 | 1 | 1.0908 | 1.2687 | 2.6076 | 18.1% | not timed | 266 |
| Steiner 9, area edges only | 1.0684 | 1 | 1.3016 | 2.1204 | 9.1921 | 37.1% | – | – |
| Steiner 9, area edges only + refract | 1.0204 | 1 | 1.1203 | 1.3055 | 2.4035 | 22.8% | 15.4x | 270 |
| Steiner 9, every edge | 1.0555 | 1 | 1.2766 | 2.2118 | 5.0263 | 23.7% | – | – |
| Steiner 5, every edge + refract | 1.0023 | 1 | 1.0051 | 1.0345 | 1.9944 | 3.3% | not timed (25x in the measure run) | – |
| **Steiner 9, every edge + refract** | **1.0012** | 1 | **1.0008** | 1.0080 | 1.9944 | 0.8% | **38x** | 270 |

**Timing notes:**
- Times are from `findpath_modes_ab.luau ... 0 all 2=5`: 400 pairs per bench scene, interleaved,
  median of 7.
- Only the bench map has areas. On the other three scenes, `refract` is the plain funnel plus a
  run check (1.04-1.06x).
- Modes that run through PathProtos' copy of Search carry that copy's 1.21-1.25x overhead.
  `exact` is exactly the copy's time, so its own cost is nil. The ratios above are against
  today's library search; "vs copy" removes the copy's overhead.
- `refract` is unoptimised: about 100 funnel calls per pin per sweep. Tran et al.'s ray bisection
  or a closed-form Snell step would cut that.

**What the table says:**
- **The funnel costs about half of today's excess.** On the same corridor, `refract` halves the
  mean excess (4.3% → 2.2%) and the >1% share falls by a third.
- **The search's own node chain is not the problem.** FindPath's funnelled path is 0.81x the
  weighted cost of its own midpoint chain on average (column in the raw output): the funnel helps
  against the chain. What hurts is that it does not help *enough*, and it sometimes cuts through
  mud.
- **Exact edge costs alone change nothing on average**, but with refract they remove the worst
  case: 2.35x → 1.99x, on repro 4 at ×5.
- **Graph searches are wasted without a cost-aware funnel.** Steiner 9 on every edge is *worse*
  than today with the plain funnel (mean 1.056), and near-exact with refract (1.0012). The plain
  funnel undoes what the graph found.
- **Steiner points only on area edges barely help** (1.0204 vs refract's 1.0225). The corridor
  errors left after refract are the same "wrong side of an obstacle" errors as unweighted queries,
  not refraction errors.
- **Weighted heron (`snell`)** helps the corridor choice about as much as heron did unweighted,
  but fails the same 5 specs as ungated heron:
  - a cheap link behind the start;
  - the cheap detour;
  - A* = Dijkstra, twice;
  - the node-chain cost.
  - Its worst case is worse (3.40x).

### 3.2 Notable rows (radius 0)

| scene, costs | today mean / max | refract | exact + refract | snell + exact + refract | Steiner 9 + refract |
|---|---|---|---|---|---|
| repro 4, ×5 | 1.1532 / 3.09 | 1.0498 / 2.35 | 1.0550 / 1.99 | 1.0601 / 3.04 | 1.0205 / 1.99 |
| soup #1, ×5 | 1.1235 / 2.43 | 1.0437 / 1.42 | – | – | 1.0007 / 1.02 |
| strip + warp, warp ×0.2 | 1.0026 / 1.16 | 1.0026 / 1.16 | 1.0026 / 1.16 | 1.0001 / 1.02 | 1.0000 / 1.00 |
| wall + hop + mud, links ×0.2 | 1.0469 / 1.46 | 1.0382 / 1.44 | 1.0398 / 1.49 | 1.0162 / 1.23 | 1.0004 / 1.05 |

- **Repro 4 at ×5** is the single worst case: a big room with one mud patch. Midpoint nodes on
  its few, long edges misprice routes by up to 3x.
- **A cheap link is mispriced up to 16% today** (strip + warp, 5 of 150 pairs). The midpoint
  node puts the walk to the warp far from where it really starts. Refract cannot fix that, since
  it is a corridor choice; snell and Steiner do.
- **Steiner's 1.99 on repro 4** is fixed spacing on 40-stud edges.

### 3.3 Radius 1 (4,215 pairs; no reference for a disc agent)
Each mode is ranked against the cheapest of the eight modes on the same pair, so these are
relative.

| mode | mean | p95 | p99 | max | > 1.01x | time, bench ×5 |
|---|---|---|---|---|---|---|
| today | 1.0440 | 1.2235 | 1.6602 | 3.0924 | 30.9% | 1x |
| exact | 1.0433 | 1.2235 | 1.6601 | 3.0924 | 30.6% | 1.15x, the copy's overhead included |
| refract | 1.0186 | 1.1195 | 1.3201 | 2.3899 | 16.3% | 3.83x |
| exact + refract | 1.0160 | 1.1037 | 1.2857 | 2.0209 | 15.4% | 4.1x |
| snell + exact + refract | 1.0085 | 1.0396 | 1.1619 | 3.0391 | 8.7% | 8.3x |
| heronlib + refract | 1.0144 | 1.0779 | 1.2740 | 2.8615 | 13.4% | – |

- **Radius:** refract keeps its gain at r = 1. Search's width rules are untouched, since refract
  only moves points inside the corridor Search chose. The pins are kept r off wall ends, like the
  funnel's offsets. Nothing here checks that a refracted path keeps the funnel's clearance
  behaviour exactly; no spec failed.
- **Steiner modes** fall back to today's search at r > 0. Per-transition width checks would be
  needed.

## Options

| option | weighted cost (r = 0, 4,350 pairs): mean / p95 / worst | FindPath time when the path crosses mud | specs | radius | links |
|---|---|---|---|---|---|
| 0. Keep today, document "costs are hints" (as Unity does) | 1.043 / 1.21 / 3.09 | 1x | 271 | – | – |
| 1. Cost-aware funnel (`refract`) | 1.023 / 1.13 / 2.35 | 3x (only when a path crosses an area edge; 1.05x otherwise), unoptimised | 271 | works; same corridors | pinned at link ends, as Detour does |
| 2. Option 1 + exact edge costs (`exact`, Detour's rule) | 1.022 / 1.13 / 1.99 | 3.1x net of the copy | 270; the node-chain spec rewritten | as 1 | as 1 |
| 3. Option 2 + weighted heron (`snell`) | 1.011 / 1.05 / 3.04 | 5.5x net of the copy | 266; fails the cheap-link and cheap-detour specs | works | mispriced: goal-ward nodes |
| 4. Steiner search, 5-9 points per edge, + refract | 1.001-1.002 / 1.001-1.005 / 1.99 | 25-38x (unoptimised Lune) | 270 | not yet: falls back | handled |

- **Recommendation: option 2.**
  - It is the only option that improves every weighted query without changing which corridor
    Search picks. All its gain comes from the funnel, so the search's guarantees stay as they
    are: SR4 widths, SR7 admissibility, links.
  - It halves the excess, and it cuts the worst case from 3.09x to 1.99x.
  - The exact edge cost costs nothing, matches Detour, and makes Search's cost the cost of a real
    polyline (its node chain). One spec pins today's mean rule and would be rewritten.
  - The funnel's time is the open item. Only paths that cross an area edge pay it. A Snell step
    in closed form or by ray bisection (Tran et al.) in place of golden section over whole
    funnels should make it a small multiple of the plain funnel. Not built.
- **Not now:**
  - Weighted heron: the same link and detour regressions as ungated heron, and a worse worst case.
  - Steiner search: near-exact, but a new search, 25-38x slower, and no radius yet. It is the
    right tool if weighted paths ever need to be near-optimal, ideally pruned near the first
    corridor as Jaklin's VBP does.

## What I could not measure or verify
- **No reference for a disc agent.** The r = 1 numbers rank modes against each other only.
- **Unity, Unreal and Roblox:** whether their straightening ignores costs is unverified (closed
  source). Detour and Godot are verified from source.
- **Shared code:** `Refract` is used by both the reference and the `refract` mode (see section 2).
- **Timings** are unoptimised Lune bench code. `refract`'s 3x in particular is golden section over
  whole funnel calls.
- **The bench map is the only timed scene with areas.** On the 1-4 km maps an area-crossing
  corridor has more runs.
- **Multi-floor, seams and sloped floors:** not covered. The reference is flat and one-floor.

## Reproduce (from the worktree root)
```
lune run tools/navmesh/bench/path_weighted.luau validate
lune run tools/navmesh/bench/path_weighted.luau converge 3 7 15 31
lune run tools/navmesh/bench/path_weighted.luau measure base,exact,refract,exact+refract,snell+exact,snell+exact+refract,heronlib,heronlib+refract,steinerb9,steinerb9+refract,steiner5+refract,steiner9,steiner9+refract 150 0
lune run tools/navmesh/bench/path_weighted.luau measure base,exact,refract,exact+refract,snell+exact,snell+exact+refract,heronlib,heronlib+refract 150 1
lune run tools/navmesh/bench/findpath_modes_ab.luau base,copy,exact,refract,exact+refract,snell+exact,snell+exact+refract,steinerb9+refract,steiner9+refract 0 all 2=5
lune run tools/navmesh/bench/path_length_oracle.luau specs refract      # 271; exact 270; snell+exact 266; steiner9+refract 270
```
