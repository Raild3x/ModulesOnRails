# Spec: NavMesh + ConstrainedDelaunay

Status: in plan-debate (build-feature phase 3), revised after spec-debate round 1.

Related documents:
- design history and rationale: [plan.md](plan.md);
- rulings and debate record: [review.md](review.md);
- proven test commands: [verification.md](verification.md);
- performance evidence: [bench.md](bench.md).

Glossaries: [lib/constraineddelaunay/CONTEXT.md](../../../lib/constraineddelaunay/CONTEXT.md),
[lib/navmesh/CONTEXT.md](../../../lib/navmesh/CONTEXT.md). This spec uses their terms. Note:
**Seam** always means the floor joint from the NavMesh glossary. The storage abstraction is the
**Storage boundary (S1)**, and the agreed test seams are the **five test layers**.

**Tooling vocabulary:**
- **tiniest:** the repo's test framework (`test/tiniest/`).
- **Lune pipeline / Studio pipeline:** a package's specs run under Lune (fast, with mutation
  testing and snapshots) or in Roblox Studio via run-in-roblox. The coverage adapter picks one
  automatically.
- **golden:** a committed tiniest snapshot.
- **winding flood:** assigning each triangle its per-group winding by walking across constraint
  edges.
- **F1–F10:** the proven framework checks in verification.md.

## Problem Statement

A Roblox developer who wants NPCs to find their way around a level has two options:
- **Roblox's PathfindingService:** asynchronous, tuned for one fixed agent size per path
  request, derived from the physical world, and hard to control, inspect or ship precomputed.
- **Hand-rolled graph searches** over waypoints they have to place themselves.

Neither gives them:
- a fast, deterministic navigation mesh they author and control;
- that works across multiple overlapping floors;
- that serves agents of many radii from one mesh (range decided after the P4 benchmark, U-a);
- that can be updated when doors or crates appear;
- that can be sent to clients or baked and loaded as plain data.

When something goes wrong they also have no way to *see* the mesh or the path.

Separately, anyone doing procedural geometry in Luau has no robust constrained Delaunay
triangulation: one that survives crossing and overlapping constraint edges, classifies
holes and overlapping regions exactly, and doesn't break on near-degenerate input.

## Solution

Four in-repo packages:

1. **`raild3x/constraineddelaunay`**, a generic CDT.
   - Input: points plus directed constraint edges tagged with **winding groups** (group 0 =
     constraint only, with no winding).
   - Output: a **plain-state** triangulation where every triangle knows its per-group winding.
   - Includes point location and quality refinement.
2. **`raild3x/navmesh`**, a layered 2.5D navigation mesh on the CDT.
   - You describe **floors**, **seams** and **links**; `Build` produces plain mesh state.
   - Synchronous queries: paths with an agent radius, nearest point, raycast, move along the
     surface, distance to wall, random point, and path validity.
   - Obstacles can be added and removed; only the affected **tiles** rebuild.
   - The mesh serializes to a versioned `buffer`.
3. **`raild3x/constraineddelaunaydebug`**, which draws any **DrawList** as SVG (for
   screenshots) or in the Studio 3D world.
4. **`raild3x/navmeshdebug`**, an in-game mouse editor that edits a description, shows the
   mesh and a live path, and exports Luau source.

## User Stories

**Building a navigation mesh**
1. As a game developer, I want to describe walkable floors as polygons, so that I control exactly where NPCs may walk.
2. As a game developer, I want to cut obstacles out of a floor with footprint polygons, so that NPCs avoid crates, pillars and walls.
3. As a game developer, I want overlapping obstacles to just work, so that I don't have to merge footprints myself.
4. As a game developer, I want several walkable outlines on one floor to be unioned, so that I can author a floor in pieces.
5. As a game developer, I want ring orientation not to matter, so that I never debug clockwise vs counter-clockwise mistakes.
6. As a game developer, I want per-vertex heights on floor outlines, so that ramps and sloped floors work.
7. As a game developer, I want multiple floors that overlap in XZ, so that buildings with storeys, balconies and bridges work.
8. As a game developer, I want to connect floors with seams, so that NPCs can walk up stairs onto the next floor.
9. As a game developer, I want links with a label, so that NPCs know to climb, jump or teleport at that point.
10. As a game developer, I want one-way links, so that NPCs can drop off ledges they can't climb back up.
11. As a game developer, I want area ids on regions of a floor, so that I can make mud, water or restricted zones.
12. As a game developer, I want `Build` to fail with a clear message on authoring mistakes, so that they're caught immediately. Those mistakes are: a floor that overlaps itself, a seam that isn't on both floors, a link endpoint off the mesh, or a triangle that degenerates after quantization.
13. As a game developer, I want authored coordinates snapped to a fine grid, so that nearly-coincident points don't produce sliver triangles.

**Querying paths**
14. As a game developer, I want `FindPath` to return smoothed waypoints, so that NPCs walk natural straight lines.
15. As a game developer, I want to pass an agent radius at query time, so that one mesh serves small and large NPCs. (Whether a maximum radius applies is decided after the P4 benchmark, U-a.)
16. As a game developer, I want waypoints kept clear of wall corners by the agent radius, so that NPCs don't clip walls.
17. As a game developer, I want per-query area costs (including excluding an area), so that different NPC types prefer or avoid terrain.
18. As a game developer, I want a clear status (`Success`, `Partial`, `Budget`, `NoStart`, `NoGoal`), so that I know why a path is short or empty.
19. As a game developer, I want a `Partial` path to the closest reachable point when the goal is unreachable, so that NPCs still get as close as they can.
20. As a game developer, I want a search budget (`MaxExpansions`), so that one query can never stall a frame.
21. As a game developer, I want waypoints to carry the floor and any link label, so that my movement code knows when to climb or jump.
22. As a game developer, I want `FindNearestPoint` to snap a position onto the mesh, preferring the floor below, so that points slightly above a floor resolve correctly. (Queries take feet positions, U-b.)
23. As a game developer, I want `Raycast` along the surface, so that I can check straight-line walkability and shortcut paths.
24. As a game developer, I want `MoveAlongSurface` to slide an agent along walls (respecting its radius), so that per-frame movement stays on the mesh.
25. As a game developer, I want `FindDistanceToWall`, so that I can steer away from walls or find cover.
26. As a game developer, I want `FindRandomPoint`, optionally within a circle and seeded by my RNG, so that I can make NPCs wander or pick spawn points reproducibly.

**Changing the mesh**
27. As a game developer, I want to add and remove obstacles at runtime, so that doors, barricades and placed objects affect navigation.
28. As a game developer, I want only the affected tiles to rebuild, so that updates are cheap.
29. As a game developer, I want `IsPathValid` to tell me whether an update or a link toggle invalidated a path I'm following, so that I replan only when needed.
30. As a game developer, I want to toggle links on and off, so that doors and bridges can open and close without a rebuild.

**Data, networking and baking**
31. As a network programmer, I want the triangulation and the mesh to be plain data, so that I can send them to clients or across Actors unchanged.
32. As a game developer, I want `Serialize`/`Deserialize` to a buffer, so that I can bake meshes and ship them precomputed.
33. As a game developer, I want a deserialized mesh to accept obstacle updates, so that baked meshes still support doors.
34. As a game developer, I want loading a buffer from an incompatible version to fail loudly, so that stale bakes never silently misbehave.
35. As a network programmer, I want a way to check that a value is network-safe, so that my own state follows the same rules.

**Using the CDT on its own**
36. As a procedural-generation developer, I want to triangulate points with constraint edges, so that I can mesh terrain, rooms or Voronoi-style layouts.
37. As a procedural-generation developer, I want crossing and overlapping constraint edges to be split automatically, so that messy input still works.
38. As a procedural-generation developer, I want exact duplicate points merged, so that duplicates never break the triangulation.
39. As a procedural-generation developer, I want robust (exact) orientation and incircle tests, so that near-collinear and cocircular inputs are handled correctly.
40. As a procedural-generation developer, I want winding groups on closed constraint loops (and group 0 for plain constraints), so that I can compute unions, differences and holes.
41. As a procedural-generation developer, I want to know which input edges produced each constrained edge, so that I can map results back to my source data.
42. As a procedural-generation developer, I want to map between input points and triangulation vertices, so that I can attach data to my original points.
43. As a procedural-generation developer, I want point location with a hint triangle, so that repeated nearby lookups are fast.
44. As a procedural-generation developer, I want quality refinement (minimum angle, maximum area, Steiner budget) that always terminates, so that I can produce well-shaped meshes safely.
45. As a procedural-generation developer, I want to read vertices, triangles, neighbours and winding through stable functions, so that my code keeps working if the internal layout changes.

**Visual debugging**
46. As a developer, I want to render any mesh, triangulation or path as an SVG image, so that I can inspect geometry outside Studio and in automated checks.
47. As a developer, I want to draw the same view in the 3D world in Studio, with layers I can toggle, so that I can debug in context.
48. As a developer, I want overlapping floors distinguishable (by colour, or one floor at a time), so that multi-floor bugs are visible.
49. As a level designer, I want to drag vertices with the mouse and see the mesh and a live path update, so that I can author navigation interactively.
50. As a level designer, I want to create walkable rings, holes (obstacles), area rings, seams, links and constraint edges in the editor, so that I can author everything the API supports.
51. As a level designer, I want start and goal markers with a radius slider, so that I can test paths for different agent sizes.
52. As a level designer, I want to export the edited description as Luau source (and import it back), so that my edits become code.

**Maintainers**
53. As a maintainer, I want every storage access to go through one Storage module per core, so that we can swap layouts and later inline hot calls safely.
54. As a maintainer, I want the core packages to stay on the fast Lune pipeline with mutation testing and goldens both working, so that regressions are caught.
55. As a maintainer, I want the four packages to depend on each other in-repo before they're published, so that a CDT change is seen by dependents immediately.
56. As a maintainer, I want an unpublished-sibling package to be impossible to publish by accident, so that consumers never receive a package with a missing dependency.

## Implementation Decisions

### Decisions (do not re-litigate)
- The full table of the user's decisions, in their words, is
  [plan.md → "Decisions (user's words)"](plan.md) (Q1–Q8, R1–R7, U1–U3, N1–N4, V1–V4).
- Later rulings (D1–D3, const, elseif, R4a/R4b, S1, the test layers, 3-round spec debate) are
  in [review.md → Rulings](review.md), also in the user's words.
- The house rules are to prototype and benchmark every perf/arch fork before presenting
  options, and to verify visually (memories `benchmark-before-options`, `verify-visually`).

### Spec defaults and review additions (the user has not ruled on these)
| # | Decision | Why |
|---|---|---|
| A | `TriangulateInput.Coords` is a flat `{ number }` of x,y pairs, copied into the internal f64 buffer | the simplest caller input |
| B | Refine's default `MaxSteiner` = `max(1024, 4 × input vertex count)` | a finite budget, so Refine always halts |
| C | `SnapExtents` defaults to half-size `(0.5, 4, 0.5)` studs; the N2 grid is 1/256 stud | R6/N2 defaults |
| SR1 | **Open constraints:** `EdgeGroups` value 0 = a constraint that contributes no winding. Every group ≥ 1 must be *balanced* (in-degree = out-degree at every vertex, i.e. closed loops), checked **after** duplicate merge, or `Triangulate` errors naming the group. Group ids are dense integers 0..G, with no cap: the winding buffer is sized T × (G+1). Each tile receives its rings **clipped to the tile rectangle**, which keeps them closed | winding across an open segment is path-dependent (seams, crossing-constraint tests, standalone users) |
| SR2 | **Snap rounding:** NavMesh computes every intersection among constraints, tile lines and seams itself using the CDT's exact predicates (`CDT.Orient2D`/`CDT.InCircle`), then applies **iterated snap rounding** (Halperin & Packer; built on Hobby / Guibas–Marimont hot pixels): every segment is rerouted through each 1/256-grid hot pixel it crosses, iterated until stable. Whether a segment crosses a hot pixel is decided **exactly**, never by rounding an f64 intersection point. *(Built in ticket 11 — changed from "`CDT.Orient2D` against the pixel's corners":)* pixels are **half-open** so they partition the plane, and the test is Liang–Barsky clipping on doubled grid integers (all products < 2^50 under guard 2), which also yields the exact entry order along the segment, including the corner tie where a closed entry comes before an open one. `CDT.Orient2D` detects the crossings. A crossing's f64 position only chooses its hot pixel, and every pixel within 1e-6 of it is marked hot, since a superset of hot pixels is always safe. The CDT is fed only grid points and non-crossing edges. **Guards:** (1) Build errors if the CDT added any vertex (`InputVertexOf == nil` for a kept vertex); (2) Build errors on any XZ coordinate outside **±32,768 studs**, the range where f32 `vector` *differences* stay exact (values alone are exact to ±65,536); (3) every kept triangle must be CCW with positive area *in stored coordinates* | N2 alone doesn't cover Steiner vertices; f32 rounding could flip thin triangles |
| SR3 | **Canonical boundaries:** tile lines and seams are split once per floor at the same grid points, so neighbouring tiles and both floors of a seam share identical boundary vertices, with no T-junctions. *(Built in ticket 13:)* each floor is snap-rounded **once** with its tile grid lines as constraints. The grid is origin-aligned and spans every ring, including obstacles and areas that reach past the walkable surface. Every ring then crosses a tile line only at a snapped vertex, so each tile **clips** the snapped ring chains to its rectangle (Sutherland-Hodgman, no new rounding; keeps winding groups closed, SR1), and adds every snapped vertex on its border. Vertices are interned per floor by grid point, and neighbours are linked across borders by matching reversed open edges. Tiles with no kept triangle are not stored. Default `TileSize` from the ticket 13 benchmark (bench.md) | one neighbour per edge requires it |
| SR4 | **Clearance counts walls only:** widths are measured to *wall* features only: edges and vertices of the walkable and obstacle boundaries. The width for passing through triangle ABC between edges CA and CB is the distance from the path corridor to the nearest wall feature reachable across AB. If C is a wall vertex, Demyen's `min(|CA|, |CB|)` bounds it (Demyen & Buro, TRA\*; see the plan.md glossary); if C is free space (a tile, area or seam vertex), the search continues past C and C itself never bounds it. Radius offsets (funnel, MoveAlongSurface) apply only at wall corners. **Fixture:** an open floor crossing a tile corner admits any radius up to its true free half-width | Demyen's formula underestimates at free-space vertices |
| SR5 | **Link toggles:** `SetLinkEnabled` bumps the stamps of both endpoint tiles, so a path through a toggled link reads invalid. This is deliberately conservative both ways: enabling a link also invalidates paths through those tiles that never use it | TileStamps otherwise miss links |
| SR6 | **Heights:** each floor's walkable surface heights are interpolated from one tile-independent triangulation of that floor's walkable rings. That surface triangulation's diagonals go into the tile CDTs as group-0 constraints, so creases of non-planar rings are kept. Overlapping walkable rings on one floor must agree in height where they overlap. A floor "overlaps itself" if they don't, or if a ring self-intersects. The self-intersection check runs on the quantized input **before** snap rounding, so rounding can't pinch a thin neck into a false error. Both are Build errors. *(Built in ticket 12, changed from "one triangulation of the floor's walkable rings":)* each walkable ring gets **its own** surface triangulation, and only a *non-planar* ring's diagonals become group-0 crease constraints. Every kept triangle takes its heights from the first ring surface containing its centroid; every other ring containing it, and every triangle sharing a vertex, must agree within **0.05 studs** (snapped vertices sit up to half a pixel off a ring edge). That turns both overlap and a step between touching rings into Build errors. Per-ring surfaces avoid the union triangulation's crossing vertices, whose height would itself be ambiguous | prevents vertical cracks at tile lines |
| SR7 | **A\* heuristic:** edge costs and the heuristic use the **same 3D metric**. The heuristic is the 3D distance scaled by `min(1, smallest AreaCosts multiplier, smallest link (Cost × its area multiplier) / 3D length)`, so it stays admissible. A zero-cost link makes the heuristic 0 (Dijkstra) for the whole mesh; documented, not prevented | cheap areas and teleport links would otherwise break optimality |
| SR8 | **Refine scope:** hull edges act as segments, and Refine refines all triangles (the caller filters by winding) | circumcentres must stay inside the domain |
| SR9 | **Serialize independence:** Serialize/Deserialize go through Storage accessors only, so the byte format is owned by `Serialize.luau` and is independent of the in-memory layout. A **frozen bake**:<br>• a v1 buffer, stored as a base64 literal in a spec file, not under shipped `src/`;<br>• must Deserialize and match its **own frozen DrawList snapshot**, taken once when the bake is made (not the live fixture golden, which changes with Build);<br>• when the format moves to v2, the v1 bake is expected to **error** (P3), and a v2 bake is added | a layout swap must not silently change old bakes |
| **U-c** | **RULED: option (1), pre-merge check.** (User: "Pre-merge check (Recommended)".) Publish guard (SR10) vs D2. D2 deferred publish tooling ("simplest and fastest for iteration"). Two options:<br>(1) **Pre-merge check:** a dedicated `[custom] publishable = "false"` on the four packages, and the check runs in the **publish-checks / detect-changes step, before any `wally publish`**, so a labelled PR goes red before merge. It must **never** refuse inside the publish loop (`.github/actions/publish-packages/action.yml` publishes alphabetically and irreversibly, and a mid-loop refusal would strand earlier publishes without their version-bump commit). A mixed-package dry-run proves nothing publishes.<br>(2) **Lighter:** no tooling; rely on the recorded "do not publish-label these packages" note.<br>Either way, the README marks them beta with the existing `unreleased = true` only (`unreleased` keeps its current meaning; 5 published packages use it) | a mid-loop refusal would be unsafe; tooling scope is the user's call under D2 |
| SR11 | **No GraphUtil.AStar:** it is disqualified *functionally*, not on performance. It returns `nil` for both unreachable and `shouldStop`, discards g/parent, and can't produce `Partial`/`Budget` with best-so-far waypoints or resume. `lib/heap` stays a benchmark candidate for the open list | the rule is to benchmark perf forks, and this is not a perf fork |
| SR12 | **`vector` at the boundary:** public API inputs are converted to `vector.create` at the boundary. The cores use only the `vector.*` library, and specs compare components, never `==`/`typeof` on Vector3 | under Lune `Vector3` is a metatable shim holding f64 |
| SR13 | **`Update` is atomic:** `AddObstacle` validates the polygon eagerly (it quantizes it and checks for self-intersection), and errors at the call. `Update` builds every dirty tile into fresh ranges first and commits (relink, free old ranges, bump stamps) only if all succeed. A failing `Update` leaves the mesh, queries and `IsPathValid` unchanged, **rolls back the obstacle records** added or removed since the last commit, and clears their dirty flags, so later `Update`s aren't poisoned. There is a spec for that. **Dirty tiles** are those whose rectangle, expanded by one grid pixel, overlaps the obstacle's *snapped* bounding box | the slab model would otherwise leave a half-rebuilt mesh |
| SR14 | **Tile vertices:** a tile's range covers its triangles **and** its interior vertices, and both are freed together. Canonical boundary vertices (SR3) are per floor and **interned by grid coordinate**. Unreferenced ones are freed on commit, so the mesh after an add+remove matches a fresh `Build` of the same description. A freed range is reused, so triangle and vertex ids are only stable until the next `Update`; a future resumable search must re-check `TileStamps` on resume | toggling a door must not grow the buffers without bound |
| SR15 | **Naming vs earlier wording:** S1's `GetTriVertex` becomes `GetTriangle -> (a, b, c)`, and plan.md's `CDT.Winding` becomes `CDT.GetWinding`, so the public names match Storage. Only the names change | public reads re-export the Storage function of the same name |
| **U-d** | **RULED: accept both.** (User: "Accept both (Recommended)".) Two API narrowings from SR1/SR2: (1) A caller passing open polylines in `Edges` with the default group 1 now gets an error; open constraints need group 0. (2) NavMesh coordinates must lie within ±32,768 studs (a Build error otherwise). Neither reverses a ruling, but both narrow what callers can do | the owner should accept new limits |
| **U-a** | **RULED: decide after benchmark.** (User: "Decide after benchmark (Recommended)".) Clearance reach (P4 vs Q4): Keeping `Update` local may need a cap on stored clearance width. A cap means "any agent radius up to `MaxAgentRadius`", which reshapes Q4 ("any radius"). If ruled a cap, it would be a `NavMeshDesc.MaxAgentRadius` field, because widths are built there. The P4 reach benchmark must run before the NavMesh API ticket, and the result goes to you | this is a user decision |
| **U-b** | **RULED: feet positions.** (User: "Feet positions (Recommended)".) Snapping reading (R6): queries take **feet** positions (on the ground), and R6 stays "nearest vertically, ties go below". The alternative reads "preferring below" as "search below first, then above" | with a 4-stud extent, a root-part position under a low ceiling can snap to the ceiling |

### Packages, modules and flow
- **`lib/constraineddelaunay`** (pure Luau, `--!native`, Lune pipeline). Modules under `src/`:
  - `ConstrainedDelaunay.luau`: the public module, re-exporting `Storage` readers and
    `PlainData`.
  - `Storage.luau`: the only owner of the layout (S1).
  - `Predicates.luau`: exact adaptive orientation and incircle, in scalar f64.
  - `Triangulator.luau`: incremental insertion plus constraint recovery, crossing splits and
    duplicate merge (Q5).
  - `Classify.luau`: the winding flood.
  - `Refine.luau`: quality refinement.
  - `Locate.luau`: the point-location walk.
  - `DrawList.luau`: the `DrawList` type and `ToDrawList`.
  - `PlainData.luau`: the network-safety validator (exists).
  - `Fixtures.luau`: shared test scenes (exists).
  - `Tests/`: the specs plus `Tests/Helpers/Invariants.luau`.
- **`lib/navmesh`** (pure Luau, `--!native`, Lune pipeline). Modules under `src/`:
  - `NavMesh.luau`: the public module.
  - `Storage.luau`: the layout owner.
  - `Quantize.luau`: the N2 grid plus snap rounding (SR2/SR3).
  - `Build.luau`: floors → tiles → `CDT.Triangulate` → copy-out, plus seams, links and heights
    (SR6).
  - `Clearance.luau`: widths (SR4, P4).
  - `Snap.luau`: the single snap step.
  - `Search.luau`: A\* over triangles plus the scratch pool (N1).
  - `Funnel.luau`: string-pull with radius.
  - `Queries.luau`: Raycast, MoveAlongSurface, DistanceToWall, RandomPoint.
  - `Tiles.luau`: dirty tiles, `Update`, stamps.
  - `Serialize.luau`: the versioned byte format (SR9).
  - `DrawList.luau`, `Fixtures.luau`, `Tests/`.
- **Query flow:** `NavMesh.FindPath` → `Snap` (both ends) → `Search` (borrowing scratch from
  its pool) → `Funnel` → `PathResult` with `TileStamps`. Every step reads through `Storage`.
- **`lib/constraineddelaunaydebug`** (Studio pipeline): `SvgBackend.luau` and
  `DrawListRenderer.luau` (both exist), which import the `DrawList` type from the CDT.
- **`lib/navmeshdebug`** (Studio pipeline):
  - `NavMeshEditor.luau` (the public editor), built on `EditorState.luau`, a pure state machine
    driven by input events;
  - uses `howmanysmall/better-signal@2.1.0` and `howmanysmall/janitor` (house rule
    `prefer-existing-packages`);
  - siblings: navmesh and constraineddelaunaydebug.
- **Sibling dependencies (D2, F10):**
  - navmesh and constraineddelaunaydebug declare `[custom] siblings = "constraineddelaunay"`.
  - Re-run `npm run setup <dependent>` when a sibling's *registry dependencies* change.
    `materialize` refreshes only the siblings' `src`.
- **Pipeline guard:** each core keeps its permanent guard spec. Core doc comments must not
  contain a marker substring (see `ROBLOX_MARKERS` in
  `tools/coverage/lune/adapters/modules_on_rails.luau`).
- **Adapters stay out of the cores:** a future Part→polygon adapter is its own package.
- **Search reuse:** only `lib/heap` stays a candidate (SR11). `lib/quadtree` and
  `lib/loosetightdoublegrid` are candidates for point location.

### Storage boundary (S1) and layout (R4)
- **CDT layout:**
  - coordinates: an f64 buffer (16 B/vertex);
  - topology: i32 buffers (triangle vertices, neighbours);
  - winding: i32 buffer, T × (G+1);
  - constraint coverage: an i32 linked-list node pool (a head per triangle edge, plus
    next/edge-id buffers). The build (ticket 06) changed this from CSR, because coverage must
    move between edges during construction; the public Count/Get readers are unchanged;
  - the input↔vertex maps: i32. Duplicate merge means vertex ids are **not** input ids.
- **NavMesh layout:**
  - vertices: native `vector` (16 B);
  - topology: i32 buffers;
  - per-triangle floor, area and tile, and clearance widths: buffers;
  - tile table, stamps, link table and enabled flags, obstacles by id, and per-tile source
    polygons (R7): plain arrays.
- **Tile slot model:**
  - Each tile owns a contiguous triangle range and an interior-vertex range in slabs (SR14).
  - `Update` builds rebuilt tiles into fresh ranges. On commit (SR13) it returns the old ranges
    to free lists, and re-links cross-tile neighbours by matching the shared canonical boundary
    vertices (SR3).
  - Boundary vertices are per floor, interned by grid coordinate, and freed on commit once
    unreferenced.
  - Ranges are compacted on `Serialize`.
- **CDT Storage accessors** (module functions, state first; hot loops alias them to locals):
  - lifecycle: `New`, `Reserve`;
  - counts: `VertexCount`, `TriangleCount`, `GroupCount`;
  - vertices: `GetVertex -> (x, y)`, `AddVertex`, `InputVertexOf`, `VertexOfInput`;
  - triangles: `GetTriangle -> (a, b, c)`, `SetTriangle`, `AddTriangle`;
  - neighbours: `GetNeighbor`, `SetNeighbor`;
  - winding: `GetWinding`, `SetWinding`;
  - coverage: `GetCoveringEdgeCount`, `GetCoveringEdge(s, t, e, k)`, `AddCoveringEdge`.
- **NavMesh Storage accessors** (record writers use `Insert`/`Delete`/`Flag` names, so they
  never collide with the public NavMesh functions that also dirty tiles or bump stamps):
  - lifecycle: `New`, `Reserve`;
  - *(ticket 12 built the subset Build and ToDrawList need, plus `FloorCount`. `InsertTile`
    takes the floor and bounds, and `AllocTileRange(tile, count)` appends a zeroed range
    tagged with its tile and floor. Freeing and reuse wait for `Update`. The rest arrive
    with their tickets.)*
  - counts: `VertexCount`, `TriangleCount`, `TileCount`, `LinkCount`, `ObstacleCount`;
  - vertices: `GetVertex -> vector`, `AddVertex`, `AllocVertexRange`, `FreeVertexRange`;
  - triangles and neighbours: `GetTriangle`, `SetTriangle`, `GetNeighbor`, `SetNeighbor`;
  - per-triangle data: `GetTriangleFloor`/`SetTriangleFloor`,
    `GetTriangleArea`/`SetTriangleArea`, `GetTriangleTile`/`SetTriangleTile`,
    `GetClearance`/`SetClearance`;
  - tiles: `InsertTile`, `GetTileBounds`, `GetTileFloor`, `AllocTileRange`, `FreeTileRange`,
    `GetTileRange`, `GetTileStamp`, `BumpTileStamp`, `GetTileSources`/`SetTileSources`
    (per-tile source polygons, R7);
  - floors: `InsertFloor`, `GetFloorName`;
  - links: `InsertLink`, `GetLink`, `SetLinkFlag`;
  - obstacles: `InsertObstacleRecord`, `GetObstacleRecord`, `DeleteObstacleRecord`.
- **Public reads re-export the Storage function of the same name.** The one exception is
  `CDT.Locate`, which lives in `Locate.luau`. Raw buffers are not part of the public contract.
- **Where the public writes live:** `NavMesh.AddObstacle`, `RemoveObstacle`, `SetLinkEnabled`
  and `Update` are in `Tiles.luau`. They call the Storage record writers, then dirty tiles or
  bump stamps.
- **In-code pointers:**
  - the `Storage.luau` header says "inlined copies may exist: grep `-- inlined: Storage.`";
  - the `NavMeshDesc` doc comment says "Part→polygon conversion belongs in a separate adapter
    package (Q1)".
- **A swap replaces `Storage.luau` in place.** Candidate layouts are prototyped in the bench
  harness first.
- **Inlining** is a later, profiling-driven step. Its rules:
  - inlined sites read strides and offsets from constants that `Storage` exports (never
    literals);
  - they carry an `-- inlined: Storage.<fn>` tag, so a future swap starts with a grep;
  - no inlining across a package boundary: NavMesh never reads CDT raw fields.
- **Capacity:** grows by doubling; `Reserve` pre-sizes when counts are known (the audit showed
  growth policy matters).
- **Exact predicates** always use scalar f64 on components, never f32 `vector.cross`.

### ConstrainedDelaunay public API
```lua
local CDT = require(Packages.ConstrainedDelaunay)

export type TriangulateInput = {
    Coords: { number },      -- flat x,y pairs (default A); exact duplicates are merged
    Edges: { number }?,      -- directed constraint edges as flat 1-based input-point index pairs {a1,b1,a2,b2,...}
    EdgeGroups: { number }?, -- group per edge (parallel to Edges/2); default 1. 0 = no winding (SR1).
                             -- Every group >= 1 must be closed loops (balanced), else Triangulate errors. Ids dense 0..G (no cap).
}
export type Triangulation = {} -- opaque plain state; read it only through the functions below (S1)

export type RefineOptions = {
    MinAngle: number?,   -- degrees; termination guaranteed only for <= ~20.7 and no input angle < 60;
                         -- triangles whose small angle comes from the input are skipped (P6)
    MaxArea: number?,
    MaxSteiner: number?, -- default max(1024, 4 * input vertex count) (default B)
}

CDT.Triangulate(input: TriangulateInput): Triangulation   -- covers the convex hull; the caller filters by winding
CDT.VertexCount(triangulation: Triangulation): number
CDT.TriangleCount(triangulation: Triangulation): number
CDT.GroupCount(triangulation: Triangulation): number      -- highest group id G
CDT.GetVertex(triangulation: Triangulation, vertex: number): (number, number)
CDT.InputVertexOf(triangulation: Triangulation, vertex: number): number? -- first input point merged into it; nil = Steiner
CDT.VertexOfInput(triangulation: Triangulation, inputPoint: number): number
CDT.GetTriangle(triangulation: Triangulation, triangle: number): (number, number, number) -- CCW
CDT.GetNeighbor(triangulation: Triangulation, triangle: number, edge: number): number   -- edge i is opposite vertex i; 0 = none
CDT.GetCoveringEdgeCount(triangulation: Triangulation, triangle: number, edge: number): number -- 0 = unconstrained
CDT.GetCoveringEdge(triangulation: Triangulation, triangle: number, edge: number, k: number): number -- k-th covering input-edge id
CDT.GetWinding(triangulation: Triangulation, triangle: number, group: number): number
CDT.Locate(triangulation: Triangulation, x: number, y: number, hintTriangle: number?): number -- 0 = outside the hull
CDT.Refine(triangulation: Triangulation, options: RefineOptions): boolean -- mutates; false = MaxSteiner reached; hull edges act as segments (SR8)
CDT.ToDrawList(triangulation: Triangulation, options: CDTDrawOptions?): DrawList
CDT.PlainData.Check(value: unknown): (boolean, string?) -- accepts buffers and `vector`; rejects functions, metatables, sparse/mixed tables, NaN, cycles
-- Exact (adaptive, scalar f64) predicates, exported so NavMesh's snap rounding (SR2) uses the same implementation:
CDT.Orient2D(ax: number, ay: number, bx: number, by: number, cx: number, cy: number): number  -- sign: 1 CCW, -1 CW, 0 collinear
CDT.InCircle(ax: number, ay: number, bx: number, by: number, cx: number, cy: number, dx: number, dy: number): number -- sign: 1 inside, -1 outside, 0 cocircular

export type DrawPrimitive = {
    Kind: "Line" | "Tri" | "Point" | "Circle" | "Arrow" | "Label", -- backends error on an unknown Kind
    Points: { number }, -- flat world x,y,z triples; CDT emits (x, 0, y)
    Color: string,      -- "#rrggbb"
    Layer: string,      -- "Triangles", "Constraints", "Path", "Floor:<name>", ...
    Radius: number?,    -- Circle only
    Text: string?,      -- Label only
}
export type DrawList = { DrawPrimitive }
export type CDTDrawOptions = { ShowConstraints: boolean?, ShowSteiner: boolean?, ColorByGroup: number?, ShowCircumcircles: boolean? }
```
```lua
-- Example: a square with a square hole, then point location
local triangulation = CDT.Triangulate({
    Coords = { 0,0, 10,0, 10,10, 0,10,   4,4, 4,6, 6,6, 6,4 }, -- outer CCW, hole CW (same group)
    Edges = { 1,2, 2,3, 3,4, 4,1,   5,6, 6,7, 7,8, 8,5 },
})
local inside = 0
for triangle = 1, CDT.TriangleCount(triangulation) do
    if CDT.GetWinding(triangulation, triangle, 1) > 0 then inside += 1 end
end
local t = CDT.Locate(triangulation, 1, 1)
local a = CDT.GetTriangle(triangulation, t)
local ax, ay = CDT.GetVertex(triangulation, a)
```

### NavMesh public API
```lua
local NavMesh = require(Packages.NavMesh)

export type Polygon = { Vector3 }  -- ring in XZ; Y = surface height at the vertex (ignored for obstacle/area rings);
                                   -- any orientation (NavMesh normalises it)
export type AreaDesc = { Polygon: Polygon, Area: number }  -- later entries win where areas overlap
export type FloorDesc = {
    Walkable: { Polygon },   -- unioned; overlapping rings must agree in height (SR6)
    Obstacles: { Polygon }?, -- subtracted
    Areas: { AreaDesc }?,
    Area: number?,           -- area id of walkable surface not covered by Areas (default 1)
}
export type SeamDesc = { FloorA: string, FloorB: string, From: Vector3, To: Vector3 } -- must lie on both floors
export type LinkDesc = {
    From: Vector3, To: Vector3, -- each snapped onto a floor at build
    Bidirectional: boolean?,    -- default true
    Cost: number?,              -- default = 3D distance (affects the heuristic, SR7)
    Area: number?,              -- filterable like a surface area
    Label: string?,             -- copied onto the waypoint where the link starts
}
export type NavMeshDesc = {
    Floors: { [string]: FloorDesc },
    Seams: { SeamDesc }?,
    Links: { LinkDesc }?,  -- link id = its 1-based index
    TileSize: number?,     -- default decided by benchmark in the implementation plan
}
export type QueryFilter = {
    AgentRadius: number?,             -- default 0 (see U-a for a possible maximum)
    AreaCosts: { [number]: number }?, -- multiplier per area; math.huge = excluded
    MaxExpansions: number?,
    SnapExtents: Vector3?,            -- half-size; default (0.5, 4, 0.5) (default C)
}
export type NavPoint = { Position: Vector3, Floor: string }
export type Waypoint = { Position: Vector3, Floor: string, Label: string? }
export type PathStatus =
      "Success" -- reached the goal
    | "Partial" -- goal unreachable; waypoints end at the reachable point closest to the goal
    | "Budget"  -- MaxExpansions hit; waypoints end at the best point found so far
    | "NoStart" -- start could not be snapped (Waypoints empty)
    | "NoGoal"  -- goal could not be snapped (Waypoints empty)
export type PathResult = { Status: PathStatus, Waypoints: { Waypoint }, Cost: number, TileStamps: { number } } -- TileStamps opaque
export type NavMeshData = {} -- opaque plain state (S1)
export type NavMeshDrawOptions = { Triangles: boolean?, Tiles: boolean?, Areas: boolean?, Clearance: boolean?, Seams: boolean?, Links: boolean? }

NavMesh.Build(desc: NavMeshDesc): NavMeshData  -- errors descriptively (story 12)
NavMesh.Serialize(mesh: NavMeshData): buffer   -- version header (P3); includes per-tile source polygons (R7); layout-independent (SR9)
NavMesh.Deserialize(data: buffer): NavMeshData -- errors on a version mismatch
NavMesh.FindPath(mesh: NavMeshData, from: Vector3, to: Vector3, filter: QueryFilter?): PathResult -- feet positions (U-b)
NavMesh.FindNearestPoint(mesh: NavMeshData, position: Vector3, filter: QueryFilter?): NavPoint?
NavMesh.Raycast(mesh: NavMeshData, from: Vector3, to: Vector3, filter: QueryFilter?): (boolean, Vector3)
    -- (blocked, stopPoint): blocked = a wall or an excluded area stops the straight walk before `to`
NavMesh.MoveAlongSurface(mesh: NavMeshData, from: Vector3, to: Vector3, filter: QueryFilter?): NavPoint -- slides along walls offset by AgentRadius (V3, SR4)
NavMesh.FindDistanceToWall(mesh: NavMeshData, position: Vector3, maxRadius: number, filter: QueryFilter?): (number, Vector3?, Vector3?)
    -- (distance, hitPoint, wallNormal); (maxRadius, nil, nil) when no wall is within range
NavMesh.FindRandomPoint(mesh: NavMeshData, filter: QueryFilter?, center: Vector3?, radius: number?, rng: (() -> number)?): NavPoint?
    -- area-weighted; rng returns [0,1), defaults to math.random
NavMesh.IsPathValid(mesh: NavMeshData, path: PathResult): boolean -- false once an Update or a link toggle touched a tile the path depends on (SR5)
NavMesh.SetLinkEnabled(mesh: NavMeshData, linkId: number, enabled: boolean): ()
NavMesh.AddObstacle(mesh: NavMeshData, floor: string, polygon: Polygon): number -- obstacle id, never reused
NavMesh.RemoveObstacle(mesh: NavMeshData, obstacleId: number): ()
NavMesh.Update(mesh: NavMeshData): ()          -- synchronously rebuilds dirty tiles (and dependent clearance, P4)
NavMesh.ToDrawList(mesh: NavMeshData, options: NavMeshDrawOptions?, path: PathResult?): DrawList
```
```lua
-- Example
local mesh = NavMesh.Build({
    Floors = {
        Ground = { Walkable = { groundOutline }, Obstacles = { crateFootprint } },
        Stairs = { Walkable = { stairRamp } },        -- Y rises along the ramp
        Upper  = { Walkable = { mezzanine }, Area = 2 },
    },
    Seams = {
        { FloorA = "Ground", FloorB = "Stairs", From = stairBottomL, To = stairBottomR },
        { FloorA = "Stairs", FloorB = "Upper",  From = stairTopL,    To = stairTopR },
    },
    Links = { { From = ledge, To = below, Bidirectional = false, Label = "Jump" } },
})
local filter = { AgentRadius = 2, AreaCosts = { [2] = 1.5 } }
local path = NavMesh.FindPath(mesh, npcFeet, goal, filter)
if path.Status == "Success" then
    for _, waypoint in path.Waypoints do moveTo(waypoint.Position, waypoint.Label) end
end
local door = NavMesh.AddObstacle(mesh, "Ground", doorFootprint)
NavMesh.Update(mesh)
if not NavMesh.IsPathValid(mesh, path) then path = NavMesh.FindPath(mesh, npcFeet, goal, filter) end
```

**Semantics:**
- **Snapping (R6, U-b):** within `SnapExtents`, take the nearest surface by vertical distance;
  ties go below. One internal snap step serves every query.
- **Clearance (Q4, P4, SR4):** widths are computed at build and `AgentRadius` is applied at
  query time. Tile, area and seam edges never limit clearance. `Update` recomputes dependent
  widths and bumps those tiles' stamps.
- **Funnel:** the corridor is string-pulled, with offsets only at wall corners. Links become
  waypoints carrying `Label`.
- **Budget:** `MaxExpansions` returns `Budget` with waypoints to the best point found. The
  search is synchronous (Q8).
- **Scratch:** a per-mesh pool in a module-level weak table (`Search.luau`). It never
  references the mesh.
- **Build:**
  1. Quantize, then snap-round (SR2/SR3).
  2. Per (floor, tile), one `CDT.Triangulate`. Named groups: walkable 1, obstacle 2, tile 3,
     areas from 4. Seams and other open constraints use group 0.
  3. Keep a triangle iff `walkable > 0 and obstacle == 0 and tile > 0`. Its area is the last
     area group with winding > 0.
  4. Heights come from the per-floor surface triangulation (SR6).
  5. Copy out through Storage, and run the degeneracy check (SR2).

The CDT fixtures are generic. NavMesh owns the meaning of the group numbers.

### Debug packages
```lua
local CDT = require(Packages.ConstrainedDelaunay)
local NavMesh = require(Packages.NavMesh)
-- Wally link modules have no children: reach submodules as fields of the public module.
local NavMeshFixtures = NavMesh.Fixtures
local SvgBackend = require(Packages.ConstrainedDelaunayDebug).SvgBackend
local DrawListRenderer = require(Packages.ConstrainedDelaunayDebug).DrawListRenderer
local NavMeshEditor = require(Packages.NavMeshDebug).NavMeshEditor

export type SvgOptions = { Width: number?, Height: number?, Layers: { string }?, Title: string? }
SvgBackend.Render(list: CDT.DrawList, options: SvgOptions?): string -- top-down XZ; y dropped

export type DrawListRenderer = {
    Draw: (self: DrawListRenderer, list: CDT.DrawList) -> (), -- replaces the previous drawing
    SetLayerVisible: (self: DrawListRenderer, layer: string, visible: boolean) -> (),
    Destroy: (self: DrawListRenderer) -> (),
}
DrawListRenderer.new(parent: Instance): DrawListRenderer

export type EditorMode = "CDT" | "NavMesh"
export type EditorDescription = NavMesh.NavMeshDesc | CDT.TriangulateInput
export type Editor = {
    Changed: Signal.Signal<(EditorDescription) -> (), EditorDescription>, -- better-signal (house form: lib/dragdrop/src/Reactive.luau)
    GetDescription: (self: Editor) -> EditorDescription,
    ExportSource: (self: Editor) -> string, -- generic plain-data -> Luau-literal printer
    Destroy: (self: Editor) -> (),          -- Janitor-backed
}
NavMeshEditor.new(parent: Instance, mode: EditorMode, initial: EditorDescription?): Editor -- LocalScript, Play mode

-- Example
local renderer = DrawListRenderer.new(workspace)
renderer:Draw(NavMesh.ToDrawList(mesh, { Triangles = true, Seams = true, Links = true }, path))
local editor = NavMeshEditor.new(workspace, "NavMesh", NavMeshFixtures.ThreeFloorStairs.Desc)
editor.Changed:Connect(function(desc) print(editor:ExportSource()) end)
```
- **Editor structure:** `EditorState.luau` holds the description and the selection, plus a
  pure `Apply(state, event)` for events such as `PointerDown`, `Drag`, `CreateRing`,
  `CreateSeam`, `CreateLink` and `Delete`. `NavMeshEditor` maps `UserInputService` events onto
  it.
- **Interactions:**
  - drag vertices;
  - create and delete ring vertices;
  - create walkable, obstacle and area rings, seams, links and constraint edges;
  - start and goal markers with a radius slider;
  - a tile overlay;
  - export and import.

### Tooling
**Done in Phase 0:**
- `scripts/new_package.py` template fix.
- `LuneRunner.luau`: the `SAVE_SNAPSHOTS=1` opt-in.
- **`mutant_run.luau`:** specs are labelled relative to `buildDir`, as `LuneRunner` does.
  - This fixed a bug found in review: snapshot specs made the mutation baseline red, and
    mutation was silently skipped.
  - Verified: baseline green, 38/40 killed with the goldens present.
- The in-repo sibling mechanism (`setup_package_for_testing.py`, `test_package.py`, the adapter).
- `.gitignore` `!lib/*/CONTEXT.md`.
- `tools/navmesh/render.luau`.

**To do (tickets):**
- **The coverage-tool `elseif` fix.** Until it lands, write predicates as `if … then return end`
  sequences, not `elseif`.
- **Whole-file coverage ignore:** add a whole-file rule form to `.coverage-ignore`
  (`tools/coverage/lune/core/Ignore.luau`, which today only has `Name`, `path:LINE` and
  `site:` forms).
  - Each new package's own `.coverage-ignore` then lists `src/Fixtures.luau` and
    `src/Tests/Helpers/Invariants.luau`. Fixture data literals were 73 spurious
    `no_coverage` mutants in Phase 0.
  - Mutation must respect the rule, and `Merge` must drop an ignored file from the
    denominators (verify both in the ticket).
  - Add an `Ignore.spec.luau` case for the file form, with a negative control.
  - Rules go on their own lines; there are no inline comments.
  - Add `!lib/*/.coverage-ignore` to `.gitignore`. Today `lib/*/*` ignores the file (as
    already happened to `lib/component/.coverage-ignore`), so the rule would silently vanish
    on CI.
  - This is scoped per package, deliberately **not** the global adapter `EXCLUDE`, which would
    shift the coverage of dragdrop, tablemanager and tablereplicator, which have
    `Tests/Helpers` files.
- **Frozen-bake base64:** Lune has no base64 decoder. Add one shared test helper (listed in the
  package's `.coverage-ignore`) rather than copying the encoder from the adapter's runner
  template.
- **Publish guard (U-c, ruled option 1):**
  - add `[custom] publishable = "false"` to the four packages;
  - the check runs in publish-checks / detect-changes (`publish-checks.yml` already runs
    `publish_detect_changed_packages.py` on every PR), **never** in the `publish.py` loop;
  - a mixed-package dry-run proves nothing publishes.
- **`lib/component/.coverage-ignore`:** stays untracked (component's own decision). The new
  `.gitignore` exception will show it as untracked, and it is not committed in the navmesh
  tickets, so component's CI coverage doesn't shift.
- **Bench harness into the repo:** move the harness (and the audit's harness) from the
  scratchpad to `tools/navmesh/bench/`, and document it in verification.md.
- **One scene module per core,** `tools/navmesh/scenes/cdt.luau` and `navmesh.luau`, each
  returning `{ {Name, List} }` built from that core's fixtures via `ToDrawList`. A changed
  golden is reviewed with
  `lune run tools/navmesh/render.luau tools/navmesh/scenes/<core> <out>`.
  - After the DrawList type moves into the CDT (ticket 1), `SvgBackend` requires the CDT link
    module. Run `npm run setup constraineddelaunaydebug` once before using `render.luau`.

### Ticket 1 cleanup of Phase 0 stubs
- **Delete stubs:**
  - `NavMesh._ProbeSibling`, the `NavMeshDebug` input-service stub, and the float
    `OrientSign` stub;
  - the specs that use them: the "sibling dependency" test, `NavMeshDebug.Deps` test 1, and
    the `CDT.Core` OrientSign block.
  - The F10(b) freshness guarantee gets a **permanent** check in the adapter's existing suite
    (`tools/coverage/lune/adapters/Tests/modules_on_rails.spec.luau`). It goes through
    `M.materialize`, since `refreshSiblings` is a local function, asserting
    that the materialized sibling `src` equals `lib/<sibling>/src` after an edit, with a
    negative control. A navmesh spec that merely builds through the CDT proves only that the
    sibling resolves.
- **Goldens:** replace the `outlineDrawList` stand-in in `CDT.Fixtures.spec.luau` with
  `CDT.ToDrawList`, regenerating its four goldens with a PNG review.
- **One DrawList type:** move `DrawPrimitive`/`DrawList` from `SvgBackend.luau` into the CDT's
  `DrawList.luau`, with the debug modules importing it.
- **Public module:** expose `PlainData` from the CDT public module, and add `--!native` to
  `NavMesh.luau`.
- **Fixtures:**
  - build `Fixtures.All` from the table, sorted by `Name`, so no fixture is forgotten;
  - add `Fixtures.ToInput(scenario): TriangulateInput` in the CDT fixtures (rings → `Coords`,
    `Edges` and `EdgeGroups`);
  - create the NavMesh fixtures as `{ Name: string, Desc: NavMeshDesc }` entries:
    `NarrowCorridor`, `ThreeFloorStairs`, `LinkJump`, `OneWayLink`, `AreaCosts`,
    `DoorAcrossTile`, `ShallowObstacles` (SR2), `OpenFloorAcrossTileCorner` (SR4);
  - add `Fixtures.All`, built automatically.
- **README status:** add `unreleased = true` to all four `wally.toml` files. The publish guard
  depends on the U-c ruling.
- **Public modules expose submodules as fields:** each core's public module exposes
  `Fixtures`, and `NavMeshDebug.luau` returns `{ NavMeshEditor = … }`.
  `ConstrainedDelaunayDebug.luau` already returns `{ SvgBackend, DrawListRenderer }`.
- **Stable public predicates:** `CDT.Orient2D`/`CDT.InCircle` are stable public API. Changing
  them, e.g. with an f32 fast path, is a public-contract change.

## Testing Decisions

**What a good test looks like here:**
- It exercises **external behaviour through public module functions**. The single exception is
  test layer 2, the Storage contract, which the S1 ruling requires.
- It asserts properties that hold regardless of layout: invariants, statuses, geometry within
  tolerance.
- It uses the shared fixtures, and seeded randomness from a local PRNG (Lune has no `Random`).
- It compares numbers with **exact** checksums that state their precision class (f64, f32
  storage, f32 vector math).
- Geometry gets a picture: a golden plus a PNG look.

Each new check gets a negative control when introduced (verification.md).

**The five test layers (the agreed "seams"):**
1. **CDT public API plus the invariant checker** (`Tests/Helpers/Invariants.luau`, listed in the
   package's `.coverage-ignore` as a whole file). For every triangulation:
   - (a) every triangle is CCW, and neighbours are symmetric;
   - (b) each input constraint a→b is a chain of edges whose covering edges
     (`GetCoveringEdgeCount`/`GetCoveringEdge`) all include its id (split points are rounded,
     so there is no exact-collinearity test);
   - (c) local constrained Delaunay: for every unconstrained interior edge shared by t1 and t2,
     exact `incircle(t1, opposite vertex of t2) <= 0` (non-strict, so cocircular input passes);
   - (d) for balanced groups, winding equals ring containment at sampled points;
   - (e) the result passes `PlainData.Check`.

   It runs over the fixtures plus seeded random inputs: collinear, cocircular, duplicate
   points, crossing and overlapping group-0 constraints, closed-loop groups, and constraints on
   the hull. Refine is checked for its angle and area bounds, halting on the budget, and the
   hull-as-segments rule.
2. **Storage contract (S1).** One suite per core requires only `../Storage` and:
   - round-trips every accessor;
   - grows past capacity;
   - checks `Reserve`, the variable-length coverage and the tile slab alloc/free;
   - checks that the state passes `PlainData.Check`;
   - **asserts a test case exists for every function `Storage` exports**, so a new accessor
     without a test fails loudly.
3. **NavMesh public API behaviours**, on the NavMesh fixtures:
   - corridor vs radius;
   - three floors joined by seams;
   - one-way links, and link toggles plus `IsPathValid` (SR5);
   - area costs, exclusion, and a cheap-area admissibility case (SR7);
   - all five statuses;
   - feet-position snapping (U-b);
   - Raycast, MoveAlongSurface, DistanceToWall and a seeded RandomPoint;
   - an obstacle across a tile border with `IsPathValid` flipping, and cross-tile neighbour
     symmetry (SR3);
   - a shallow-angle overlapping-obstacle fixture that passes the degeneracy check (SR2);
   - **snap-rounding invariant (SR2)**, over seeded random polygon soups:
     - after snap rounding, no two fed edges cross except at shared endpoints (exact
       `CDT.Orient2D`);
     - Build never trips the "CDT added a vertex" guard;
   - an open floor across a tile corner admits any radius up to its true free half-width (SR4);
   - a coordinate beyond ±32,768 studs is a Build error (SR2);
   - **atomic `Update` (SR13):** a failing `Update` leaves queries and `IsPathValid` unchanged,
     and an invalid obstacle polygon errors at `AddObstacle`;
   - toggling a door for many cycles doesn't grow the vertex or triangle counts (SR14);
   - a failing `Update` rolls back its obstacle records, so the next `Update` succeeds (SR13);
   - an obstacle vertex that snaps onto a tile line dirties both neighbouring tiles, with no
     T-junction (SR13, SR3);
   - add then remove an obstacle, and the mesh golden matches a fresh `Build` (SR14);
   - a Serialize round-trip, a version mismatch, and a **frozen v1 bake** with its own frozen
     snapshot (SR9);
   - every Build error message.
4. **DrawList goldens:** `CDT.ToDrawList` / `NavMesh.ToDrawList` over the fixtures, as tiniest
   `snapshot` on Lune. Save only with `SAVE_SNAPSHOTS=1`, and review each changed golden as a
   PNG via the core's scene module.
5. **Debug packages in Studio:**
   - `DrawListRenderer` specs (3/3 already);
   - `EditorState.Apply` driven by synthetic events;
   - an `ExportSource` → import round-trip over every fixture.

   The Play-mode mouse interaction is a **manual user check**, because F7 runs in edit mode and
   can't synthesize mouse input.

**Prior art:**
- `lib/graphutil/src/tests/*.spec.luau`;
- the Phase 0 specs in `lib/constraineddelaunay/src/Tests/` and
  `lib/constraineddelaunaydebug/src/Tests/`;
- `test/tiniest/tiniest_snapshot.luau`;
- the F1–F10 commands in verification.md.

**Gates for every ticket:**
- `lune run coverage.luau package=<pkg>` for each touched package (`--roblox-runner=studio` for
  the debug packages);
- `--mutate` on the cores (the mutation baseline now works with goldens present);
- a PNG review of changed goldens;
- `selene` / `stylua`.

**Performance:** every perf fork uses the in-repo bench harness and the audited method
(bench.md): one factor at a time, typed code, equal pre-sizing, a shuffled mesh, interleaved
rounds, exact checksums, and analytic memory.

## Out of Scope
- World-geometry extraction and a Part→polygon adapter; they come later, in their own package
  (Q1).
- True 3D surfaces (Q2).
- Live CDT edits beyond per-tile rebuilds, and public CDT insert/remove (Q5).
- Time-sliced or async pathfinding (Q8). Such a search must re-check `TileStamps` on resume,
  because freed tile ranges are reused (SR14).
- Exposing the path corridor (R5).
- Crowd simulation and local avoidance.
- A Studio-plugin editor.
- The sibling → `[dependencies]` publish conversion and CI re-running dependents (D2). U-c
  only decides whether publishing gets *blocked*.
- Convex-polygon merging (an implementation-plan fork, benchmark-gated).

## Further Notes
- **Ticket ordering against open rulings:**
  - U-a comes before the NavMesh API ticket (after the P4 reach benchmark);
  - U-b before the snapping specs;
  - U-c before the publish-guard tooling ticket;
  - U-d before the `Triangulate` validation and Build-guard specs.
- **Benchmark-gated forks for the implementation plan:**
  - the open-list design (`lib/heap` or bespoke);
  - grid vs quadtree for point location;
  - the default `TileSize`;
  - the P4 clearance reach (**before** the NavMesh API ticket; see U-a);
  - the renderer primitive;
  - convex-polygon merging;
  - the Storage accessor overhead vs inlining (S1).
- **Known tooling findings (verification.md):**
  - the `elseif` mutation blind spot (fix ruled);
  - snapshot mismatches print whole blobs without a diff;
  - better-signal can't load under Lune;
  - F7 capture briefly maximizes Studio;
  - fixture literals count as `no_coverage` mutants until the whole-file `.coverage-ignore`
    rule lands.
- **Snap rounding (SR2)** is the highest-risk algorithm in NavMesh. The implementation plan
  should prototype it early, using the screenshot loop and the shallow-angle fixtures.
