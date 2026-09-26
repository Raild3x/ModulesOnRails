# NavMesh + ConstrainedDelaunay: public API and Phase 0 plan

## Context
The user wants a generic navmesh module that pathfinding queries can run on. It sits on a
constrained Delaunay triangulation (CDT) module, is built for speed (memory layout, iteration
cost), supports 3D navmeshes with multiple floors, and ships with visual debug tools (a
renderer plus an interactive mouse editor).

This document has two parts:
1. **The agreed public API.** It came out of a four-round design grilling (the build-feature
   skill's phase 1: grill → spec → debate → tickets → build).
2. **Phase 0.** Before any spec is written, this proves the testing and verification framework
   works, then runs the benchmarks that settle the two decisions still open.

After Phase 0, the API goes into `docs/plans/navmesh/spec.md` (the `to-spec` skill), then through
a scored review (`plan-debate`), then into tickets.

**Standing rules from the user**, to save as feedback memories once plan mode ends:
> "All questions about performance and architectural considerations should be prototyped, tested,
> measured, and benchmarked before presenting options so we can provide concrete pros and cons to
> each tradeoff."

> Verify work visually, with "screenshots of your work's output and run commands on it … so that
> we aren't relying on pure numbers."

### Repo facts relied on (verified at `21e62b7`)
- **Existing reuse candidates, all benchmark-gated:**
  - `lib/graphutil/src/AStar.luau`: a generic A* keyed by hash (`g`/`parent`/`visited` are
    `{[V]: …}` maps), allocating per query. It depends on the published `raild3x/heap@2.1.3`, so
    "GraphUtil + Heap" is one option.
  - `lib/quadtree` and `lib/loosetightdoublegrid`: 2D spatial indexes.
- **Test pipeline classification** (`tools/coverage/lune/adapters/modules_on_rails.luau:33-41,
  125-148`):
  - A package moves to the Studio pipeline if any `.luau` file under `src/` contains one of 7
    marker **substrings**: `game:GetService`, `game.`, `workspace`, `Instance.new`, `script:`,
    `script.`, `:GetPropertyChangedSignal`. This includes matches inside comments and doc
    examples.
  - Any `const` also moves it.
  - `Vector3`, `CFrame` and `Random` are **not** markers.
  - Mutation testing is Lune-only (`tools/coverage/README.md`).
- **Snapshots:**
  - tiniest snapshots load on Lune only. `tiniest_for_roblox.luau` marks `snapshot_path` and
    `save_snapshots` "not yet implemented".
  - The Lune runner hardcodes `save_snapshots = false` (`LuneRunner.luau:58-59`,
    `mutant_run.luau:55-56`), so there is currently **no way to write a snapshot**.
  - On a mismatch, tiniest prints both full snapshots, not a line diff.
  - Snapshot keys come from the spec path plus test labels, without the package name, all under
    the root `test/__snapshots__`.
- **Package dependencies and test copies:**
  - Sibling packages depend on each other through **published** Wally versions (e.g. graphutil's
    `wally.toml`).
  - A package that declares dependencies but has no `_Index/` is skipped with a warning
    (`needsSetup`).
  - Tests run in a copy of **only** the package directory (`M.materialize` in the adapter). That
    copy includes `_Index/`.
  - **No precedent exists for unpublished siblings.** profiletrademanager (branch
    `feat/PlayerProfileManager` only) vendored *published external* dependencies, and only
    locally.
  - `scripts/setup_package_for_testing.py`:
    - it clears each package down to `WALLY_IGNORE_LIST` (`src`, `default.project.json`,
      `wally.toml`, `*.md`, `docs`; `scripts/_common.py`) before `wally install`, which wipes
      any vendored `_Index`;
    - its no-argument `main()` returns on the **first** failing package.
    - `npm run clear`, `npm run docs` and `npm run docs:build` also clear.
  - CI's `scripts/test_package.py` treats a setup failure as a warning, and the coverage runner
    then skips the package. The job stays green.
- **Ignored files:** `.gitignore` has `lib/*/*` with exceptions only for `src`, `README.md` and
  `docs`, so a new `lib/<pkg>/CONTEXT.md` is ignored. Only `lib/tablemanager/CONTEXT.md` is
  tracked (it was force-added). The dragdrop and remotecomponent CONTEXT.md files that
  `CONTEXT-MAP.md` links to are not tracked.
- **Scaffolding script** (`scripts/new_package.py`):
  - It is interactive (`input()` ×3).
  - It refuses a directory that already exists.
  - Its spec template renders `require(./"Name")`, which is a syntax error (line 78).
- **Lune details:** `Vector3`/`Vector2` are metatable shims under Lune (`.luaurc` aliases), and
  Lune's `vector.create` returns a native `vector`.
- **Dependencies to reuse:** Signal is the Wally dependency `howmanysmall/better-signal@2.1.0`
  (dragdrop `wally.toml`; memory `prefer-existing-packages`).
- **Bench recipe** (memory `component-performance`):
  - A scratchpad `place.project.json` mounts `lib/`, then `rojo build` → `run-in-roblox`.
  - Take medians of 3+ interleaved runs.
  - Put deadlines on every loop and print `[MARK]` breadcrumbs.
  - A headless alternative exists: `tools/ci/OpenCloud.luau`.

### API survey (primary docs: artem-ogre/CDT, Triangle, poly2tri, spade, CGAL, Fade2D, delaunator, Detour, Unity, Godot, Roblox PathfindingService)
- **Holes:**
  - Three styles exist: seed-point flood (Triangle, CGAL, Fade), explicit hole polylines
    (poly2tri), and even-odd depth (artem-ogre, spade).
  - Winding groups can express all three.
- **Near-duplicate points:**
  - No surveyed library merges by epsilon.
  - Some merge exact duplicates (artem-ogre, spade, Fade).
  - Others snap to a grid (Recast voxels, Godot `cell_size`).
- **Refinement ("tessellation"):**
  - Every CDT library has it.
  - No navmesh library uses it.
  - Ruppert-style refinement is only guaranteed to terminate for bounds up to about 20.7°, and
    only when no input angle is below 60°. Triangle sidesteps small input angles by skipping
    the triangles that cause them.
- **Common in navmesh libraries:**
  - nearest point;
  - A* followed by a funnel pass (the "string-pulling" step that turns a triangle corridor into
    straight waypoints);
  - raycast;
  - area costs;
  - links;
  - tile-cache obstacles (Detour `addObstacle` → `update`);
  - random point;
  - distance to wall;
  - move along surface;
  - path validity or corridor repair;
  - sliced search;
  - convex-polygon merging.

## Decisions (user's words)
| # | Decision | User answer |
|---|---|---|
| Q1 | Input is authored polygons, with a generic core. A part adapter comes later. | "Authored polygons (Recommended)" |
| Q2 | Layered 2.5D floors. Each floor is a height field, the author splits any self-overlap, and Build errors if a floor overlaps itself. | "Layered 2.5D (Recommended)" |
| Q3 | Two core packages: `raild3x/constraineddelaunay` and `raild3x/navmesh`. | no objection |
| Q4 | Agent clearance is computed at query time (TRA*-style widths). | "Query-time clearance (Recommended)" |
| Q5 | Static v1, tiled now. The CDT inserts incrementally internally, and constraint edges keep their input-edge ids. | "Static, plan tiles now" |
| Q6 | Serialize/Deserialize to a buffer. | no objection |
| Q7 | Areas with `AreaCosts`, and `SetLinkEnabled`. | no objection |
| Q8 | FindPath is synchronous with a `MaxExpansions` budget. | no objection |
| R1 | Floors connect through explicit Seams and Links. | "Explicit Seams + Links (Recommended)" |
| R2 | The dynamic-obstacle API is the last v1 ticket. | "Last v1 ticket (Recommended)" |
| R3 | The CDT classifies triangles by per-group winding. | "CDT winding groups (Recommended)" |
| R4 | CDT data layout: **PENDING Phase 0 benchmark**. | "prototype, test, measure, benchmark before presenting options" |
| R5–R7 | Waypoints only · snap nearest vertically, preferring below · Serialize keeps source polygons. | recommendations; R5 reopened by N3 |
| U1 | The Triangulation is **plain state**: no metatable, safe to send over the network, and operated on by module functions. | user comment on the plan |
| U2 | Visual debug tools: a DebugCDTRenderer, a DebugNavMeshRenderer, and a mouse editor that can drag points and create seams, links, holes and edges. | user rejection note |
| U3 | No `Holes` field in the CDT (winding covers it, see answer). `GroupCount` is dropped and derived from the edge groups. | proposed in answer to the user's comments |
| N1 | NavMesh is plain state too: `NavMesh.FindPath(mesh, …)`, with query scratch in a module-level weak table | "Both plain state (Recommended)" |
| N2 | The CDT merges exact duplicates only. NavMesh quantizes authored coordinates to a fixed fine grid before triangulating. | "Exact in CDT + NavMesh grid (Recommended)" |
| N3 | v1 includes IsPathValid, FindRandomPoint, MoveAlongSurface + FindDistanceToWall, and CDT.Refine | all four selected |
| N4 | Debug renderers ship as **separate packages for now** and will probably merge into the product later. Verification must be **visual**: screenshots of output that I can inspect and run commands on, from Roblox or a simple HTML render. | "Consider how you plan to test things… screenshots… separate packages for now" |
| V1 | Visual workflow: DrawList seam → SvgBackend (Lune) → headless-Edge PNG + SVG goldens on shared fixtures; RobloxBackend with a Studio capture attempt | "Adopt as drafted (Recommended)" |
| V2 | Two debug packages: `constraineddelaunaydebug` (depends on CDT) and `navmeshdebug` (navmesh + the CDT debug package; holds the editor) | "Two, mirroring cores (Recommended)" |
| V3 | MoveAlongSurface respects AgentRadius (walls offset by the radius) | "Radius-aware (Recommended)" |
| V4 | Constructors return new state (Build, Triangulate, Deserialize); modifiers mutate in place (AddObstacle, RemoveObstacle, Update, SetLinkEnabled, Refine) | "Mutate in place (Recommended)" |
| — | **API frontier empty** except R4 (layout) and `const` vs `local`, both waiting on Phase 0 | — |

Notes on the table:
- U3's answer is under "Holes" in the CDT section.
- R5 now means waypoints plus opaque tile stamps (for `IsPathValid`). No triangle corridor is
  exposed.
- Changes proposed by the plan debate are listed under **Review additions (pending)** and marked
  **[P#]** where they appear.

---

## Public API
Terms are defined in the Glossary. ⏳ marks storage details decided by the R4 benchmark.

### ConstrainedDelaunay (`lib/constraineddelaunay`): plain state plus module functions
```lua
local CDT = require(Packages.ConstrainedDelaunay)

export type TriangulateInput = {
    Coords: ⏳R4,            -- 2D point positions (format decided by R4)
    Edges: { number }?,      -- directed constraint edges as flat 1-based index pairs {a1,b1,a2,b2,...}
    EdgeGroups: { number }?, -- winding-group id per edge (parallel to Edges/2), default 1
}

-- Plain data: string keys, dense arrays with no nil holes, no functions, no metatable.
-- Storage ⏳R4. It must carry:
--   vertex positions (input vertices first, then Steiner vertices);
--   CCW vertex triples per triangle;
--   the neighbour triangle across each edge (0 = none);
--   for each constrained edge, every input edge that covers it [P5];
--   per-group winding per triangle.
export type Triangulation = { GroupCount: number --[[ = max(EdgeGroups) or 1; other fields ⏳R4 ]] }

export type RefineOptions = {
    MinAngle: number?,   -- degrees. Termination is guaranteed only for ≤ ~20.7° with no input angle < 60°;
                         -- triangles whose small angle comes from the input are skipped [P6]
    MaxArea: number?,
    MaxSteiner: number?, -- finite default (value set in the spec) so Refine always halts [P6]
}

CDT.Triangulate(input: TriangulateInput): Triangulation
CDT.VertexCount(triangulation: Triangulation): number
CDT.TriangleCount(triangulation: Triangulation): number
CDT.Locate(triangulation: Triangulation, x: number, y: number, hintTriangle: number?): number -- 0 = outside hull
CDT.InputVertexOf(triangulation: Triangulation, vertex: number): number?                     -- nil = Steiner vertex
CDT.Winding(triangulation: Triangulation, triangle: number, group: number): number
CDT.Refine(triangulation: Triangulation, options: RefineOptions): boolean -- mutates (V4); false = MaxSteiner reached
CDT.ToDrawList(triangulation: Triangulation, options: CDTDrawOptions?): DrawList       -- [P1]

-- Debug view types, defined here and reused by NavMesh [P1]:
export type DrawPrimitive = {
    Kind: "Line" | "Tri" | "Point" | "Circle" | "Arrow" | "Label", -- backends `error` on an unknown Kind
    Points: { number },  -- flat world x,y,z triples. CDT.ToDrawList emits its 2D (x, y) as world (x, 0, y), in the XZ plane
    Color: string,       -- "#rrggbb"
    Layer: string,       -- e.g. "Triangles", "Constraints", "Path", "Floor:Upper"; backends can toggle layers
    Radius: number?,     -- Circle only
    Text: string?,       -- Label only
}
export type DrawList = { DrawPrimitive }
export type CDTDrawOptions = { ShowConstraints: boolean?, ShowSteiner: boolean?,
    ColorByGroup: number?, ShowCircumcircles: boolean? }
```
- **Robustness:** intersecting constraints are always split, exact duplicates are merged (N2),
  and predicates are exact.
- **Holes (U3):** there is no `Holes` field. A hole is a clockwise ring in the same group, or a
  ring in its own group that the caller subtracts (`Winding(…, holeGroup) > 0` means inside the
  hole).
```lua
-- Example: a 10×10 square with a 2×2 hole, triangulated and then filtered to the inside.
local triangulation = CDT.Triangulate({
    Coords = --[[ outer 1-4 CCW: (0,0) (10,0) (10,10) (0,10); hole 5-8 CW: (4,4) (4,6) (6,6) (6,4) ]],
    Edges = { 1,2, 2,3, 3,4, 4,1,   5,6, 6,7, 7,8, 8,5 },
})
local inside = 0
for triangle = 1, CDT.TriangleCount(triangulation) do
    if CDT.Winding(triangulation, triangle, 1) > 0 then inside += 1 end
end
local hit = CDT.Locate(triangulation, 1, 1)  -- a triangle in the ring; Locate(5, 5) lands in a hole triangle
```

### NavMesh (`lib/navmesh`): plain state plus module functions
```lua
local NavMesh = require(Packages.NavMesh)

export type Polygon = { Vector3 }  -- a ring in XZ; Y = surface height at that vertex (ramps allowed).
                                   -- Orientation doesn't matter (NavMesh normalises it). Y is ignored
                                   -- for obstacle and area rings.
export type AreaDesc = { Polygon: Polygon, Area: number }  -- later entries win where areas overlap
export type FloorDesc = {
    Walkable: { Polygon },       -- unioned
    Obstacles: { Polygon }?,     -- subtracted
    Areas: { AreaDesc }?,        -- sub-regions painted with another area id
    Area: number?,               -- area id of walkable surface not covered by Areas (default 1)
}
export type SeamDesc = { FloorA: string, FloorB: string, From: Vector3, To: Vector3 } -- must lie on both floors
export type LinkDesc = {
    From: Vector3, To: Vector3,  -- each snapped onto a floor at build
    Bidirectional: boolean?,     -- default true
    Cost: number?,               -- default = 3D distance
    Area: number?,               -- filterable like a surface area
    Label: string?,              -- copied onto the waypoint where the link starts
}
export type NavMeshDesc = {
    Floors: { [string]: FloorDesc },
    Seams: { SeamDesc }?,
    Links: { LinkDesc }?,        -- a link's id = its 1-based index here
    TileSize: number?,           -- default set by benchmark (implementation plan)
}
export type QueryFilter = {
    AgentRadius: number?,               -- default 0
    AreaCosts: { [number]: number }?,   -- cost multiplier per area; math.huge = excluded
    MaxExpansions: number?,             -- search budget
    SnapExtents: Vector3?,              -- half-size of the snap box; default (0.5, 4, 0.5) (R6) [P7]
}
export type NavPoint = { Position: Vector3, Floor: string }
export type Waypoint = { Position: Vector3, Floor: string, Label: string? }
export type PathStatus =
      "Success"  -- reached the goal
    | "Partial"  -- goal unreachable; waypoints end at the reachable point closest to the goal
    | "Budget"   -- MaxExpansions hit; waypoints end at the best point found so far
    | "NoStart"  -- start could not be snapped onto the mesh (Waypoints empty)
    | "NoGoal"   -- goal could not be snapped onto the mesh (Waypoints empty)   [P7: "Unreachable" removed, Partial covers it]
export type PathResult = {
    Status: PathStatus,
    Waypoints: { Waypoint },  -- funnel-smoothed, offset from corners by AgentRadius
    Cost: number,
    TileStamps: { number },   -- opaque; read only by IsPathValid
}
export type NavMeshData = { --[[ plain, network-safe; storage benchmark-gated ]] }

NavMesh.Build(desc: NavMeshDesc): NavMeshData  -- errors (descriptive message) on a self-overlapping floor,
                                               -- a seam not on both floors, or a link endpoint off the mesh
NavMesh.Deserialize(data: buffer): NavMeshData -- errors on a format-version mismatch [P3]
NavMesh.Serialize(mesh: NavMeshData): buffer   -- starts with a format version [P3]; includes source polygons (R7)

NavMesh.FindPath(mesh: NavMeshData, from: Vector3, to: Vector3, filter: QueryFilter?): PathResult
NavMesh.FindNearestPoint(mesh: NavMeshData, position: Vector3, filter: QueryFilter?): NavPoint?   -- [P7] uses filter.SnapExtents
NavMesh.Raycast(mesh: NavMeshData, from: Vector3, to: Vector3, filter: QueryFilter?): (boolean, Vector3)
    -- (blocked, stopPoint): blocked = a wall or excluded area stops the straight walk before `to`
NavMesh.MoveAlongSurface(mesh: NavMeshData, from: Vector3, to: Vector3, filter: QueryFilter?): NavPoint -- [P7] returns floor too; slides along walls offset by AgentRadius (V3)
NavMesh.FindDistanceToWall(mesh: NavMeshData, position: Vector3, maxRadius: number, filter: QueryFilter?)
    : (number, Vector3?, Vector3?) -- (distance, hitPoint, wallNormal); (maxRadius, nil, nil) when no wall is within range
NavMesh.FindRandomPoint(mesh: NavMeshData, filter: QueryFilter?, center: Vector3?, radius: number?,
    rng: (() -> number)?): NavPoint? -- area-weighted; rng in [0,1) defaults to math.random
NavMesh.IsPathValid(mesh: NavMeshData, path: PathResult): boolean -- false once an Update changed any tile the path depends on

NavMesh.SetLinkEnabled(mesh: NavMeshData, linkId: number, enabled: boolean): ()
NavMesh.AddObstacle(mesh: NavMeshData, floor: string, polygon: Polygon): number -- returns an obstacle id; ids are never reused
NavMesh.RemoveObstacle(mesh: NavMeshData, obstacleId: number): ()
NavMesh.Update(mesh: NavMeshData): ()           -- synchronously rebuilds dirty tiles (R2)
NavMesh.ToDrawList(mesh: NavMeshData, options: NavMeshDrawOptions?, path: PathResult?): DrawList -- [P1]

export type NavMeshDrawOptions = { Triangles: boolean?, Tiles: boolean?, Areas: boolean?,
    Clearance: boolean?, Seams: boolean?, Links: boolean? }
```
```lua
-- Example
local mesh = NavMesh.Build({
    Floors = {
        Ground = { Walkable = { groundOutline }, Obstacles = { crateFootprint } },
        Stairs = { Walkable = { stairRamp } },               -- Y rises along the ramp
        Upper  = { Walkable = { mezzanine }, Area = 2 },
    },
    Seams = {
        { FloorA = "Ground", FloorB = "Stairs", From = stairBottomL, To = stairBottomR },
        { FloorA = "Stairs", FloorB = "Upper",  From = stairTopL,    To = stairTopR },
    },
    Links = { { From = ledge, To = below, Bidirectional = false, Label = "Jump" } },
})

local filter = { AgentRadius = 2, AreaCosts = { [2] = 1.5 } }
local path = NavMesh.FindPath(mesh, npcPosition, goal, filter)
if path.Status == "Success" then
    for _, waypoint in path.Waypoints do moveTo(waypoint.Position, waypoint.Label) end
end

local door = NavMesh.AddObstacle(mesh, "Ground", doorFootprint)
NavMesh.Update(mesh)                                -- rebuilds only the affected tiles
if not NavMesh.IsPathValid(mesh, path) then path = NavMesh.FindPath(mesh, npcPosition, goal, filter) end
NavMesh.RemoveObstacle(mesh, door)
NavMesh.Update(mesh)
```
- **Query scratch** (open list, generation stamps):
  - It is not part of the state.
  - Each search borrows it from a per-mesh pool, held in a module-level weak-keyed table keyed
    by the mesh. In v1 the pool holds one scratch, because searches are synchronous. A future
    sliced search borrows its own.
  - Scratch never references the mesh, since Luau weak tables are not ephemerons.
  - Each Actor has its own module instance.
- **One snap step:** every query goes through a single internal snap step, so accepting a
  `NavPoint` input later changes only that step.
- **State stays remote-safe:** sparse numeric maps such as `AreaCosts` appear only in query
  filters, never in state.

### How NavMesh uses the CDT
- **One triangulation per tile:** each (floor, tile) is one `CDT.Triangulate` call in XZ. Groups
  are referenced only through named constants: `GROUP_WALKABLE = 1`, `GROUP_OBSTACLE = 2`,
  `GROUP_TILE = 3` (the tile's rectangle), and area groups from `GROUP_FIRST_AREA = 4`.
- **Seams line up with edges:** seam segments are inserted as constraints in both floors, so the
  seam coincides with triangle edges.
- **Classification:** a triangle is kept iff `walkable > 0 and obstacle == 0 and tile > 0`. Its
  area is the last area group with winding > 0, otherwise the floor default.
- **Coincident constraints:** several constraints can lie on the same edge, e.g. a walkable edge
  on a tile line, or an obstacle flush with a wall. Each such edge records every covering input
  edge [P5], so the winding flood counts every group it crosses. Fixtures cover both cases.
- **Heights:** the Y of each Steiner vertex is interpolated from the walkable surface.
- **Copy out and discard:** kept triangles are copied into NavMeshData together with seam, link
  and tile adjacency and the clearance widths. The Triangulation is then discarded.
- **Clearance across tiles [P4]:**
  - Tile-boundary edges are not walls, so widths look across them.
  - After `Update` rebuilds a tile, the widths in neighbouring tiles that depend on it are
    recomputed, and their stamps are bumped so that `IsPathValid` sees the change.
  - How far that dependency reaches (for example a cap on stored width) is an
    implementation-plan fork, gated on a benchmark.

### Debug packages (V2 [P1])
- **`constraineddelaunaydebug`** (depends on CDT) holds the two DrawList backends:
  - `SvgBackend` (pure Luau, returns an SVG string);
  - `DrawListRenderer`, the Roblox backend. It draws any DrawList, so it serves as both the
    DebugCDTRenderer and the DebugNavMeshRenderer (U2).
- **`navmeshdebug`** (depends on navmesh and constraineddelaunaydebug) holds the editor.
- Both debug packages are on the Studio pipeline. The pure DrawList builders live in the cores
  [P1], so the goldens run on Lune.
- **Checked by eye only:** SvgBackend's SVG output is checked visually (F4), not by snapshot. It
  is thin string formatting over an already-snapshotted DrawList.
- **Limit on N4's future merge:** only SvgBackend can move into a core. DrawListRenderer uses
  `Instance.new`, which would flip that core to the Studio pipeline.
- **Rules for the cores:**
  - **Doc examples:** core doc comments must not contain a marker substring (e.g. `workspace`).
    The per-core pipeline guard spec (F1) catches any slip.
  - **Adapters stay out:** a future Part→polygon adapter (Q1: later) lives in its own package,
    never in a core, for the same reason.
```lua
local SvgBackend = require(Packages.ConstrainedDelaunayDebug.SvgBackend)
local DrawListRenderer = require(Packages.ConstrainedDelaunayDebug.DrawListRenderer)
local NavMeshEditor = require(Packages.NavMeshDebug.NavMeshEditor)

-- Top-down XZ projection (y is dropped). Overlapping floors are told apart by their "Floor:<name>" layer colour;
-- `Layers`, when given, draws only those layers (e.g. one floor at a time).
SvgBackend.Render(list: DrawList, options: { Width: number?, Height: number?, Layers: { string }? }?): string
export type DrawListRenderer = {
    Draw: (self: DrawListRenderer, list: DrawList) -> (),                 -- replaces previous drawing; world coordinates as given
    SetLayerVisible: (self: DrawListRenderer, layer: string, visible: boolean) -> (),
    Destroy: (self: DrawListRenderer) -> (),
}
DrawListRenderer.new(parent: Instance): DrawListRenderer

-- navmeshdebug (runs from a LocalScript in Play mode: mouse input via UserInputService + CurrentCamera)
export type EditorDescription = NavMeshDesc | TriangulateInput
export type Editor = {
    Changed: Signal<EditorDescription>,   -- howmanysmall/better-signal (Wally dependency)
    GetDescription: (self: Editor) -> EditorDescription,
    ExportSource: (self: Editor) -> string, -- a generic plain-data → Luau-literal printer, not per field
    Destroy: (self: Editor) -> (),
}
NavMeshEditor.new(parent: Instance, mode: "CDT" | "NavMesh", initial: EditorDescription?): Editor

-- Example: draw a mesh and a path in Studio
local renderer = DrawListRenderer.new(workspace)
renderer:Draw(NavMesh.ToDrawList(mesh, { Triangles = true, Seams = true, Links = true }, path))
```
Editor v1 interactions:
- From the user's list: drag points with the mouse; create seams, links, holes (obstacles) and
  constraint edges.
- Proposed additions: create and delete ring vertices; create walkable and area rings; place
  start and goal markers with a radius slider for a live FindPath; show a tile overlay;
  import and export the description.
- An export→import round-trip spec over every fixture keeps `ExportSource` complete.

---

## Visual verification workflow (V1)
- **The seam is `DrawList`** (type in CDT, builders `CDT.ToDrawList` / `NavMesh.ToDrawList`). It
  has two backends: SvgBackend (Lune) and DrawListRenderer (Studio).
- **Screenshot loop:** `lune run tools/navmesh/render.luau <fixture>` writes an `.svg`. Then
  `msedge --headless --screenshot=<png> --window-size=W,H file:///<svg>` produces a PNG that I
  view with Read. Edge is installed at `C:\Program Files (x86)\Microsoft\Edge\Application\`. The
  user can open the same SVG in a browser.
- **Fixtures:** each core has `src/Fixtures.luau`. It sits in `src/` and not in `src/Tests/` on
  purpose: the debug packages reach it through their dependency, so it ships to consumers. It is
  small plain data.
  - CDT: square with a hole; overlapping obstacles; coincident constraints on a tile line; two
    rings sharing an edge.
  - NavMesh: narrow corridor (radius); stairs over three floors; link and jump; door obstacle
    added and removed across a tile border.
  - Who uses them:
    - their own specs, through a relative require;
    - the render script and the Studio bench, through repo paths;
    - the debug packages, through their Wally dependency.
- **Goldens:** core specs snapshot `ToDrawList` output (coordinates rounded) with tiniest
  `snapshot` on Lune.
  - Spec files are prefixed per package (`CDT.*.spec.luau`, `NavMesh.*.spec.luau`) so their
    keys can't collide.
  - Saving happens only through an explicit opt-in that is off by default and never set in CI
    (F3). A changed golden gets a PNG look before it is accepted.
- **Studio check:** DrawListRenderer draws the same fixtures. Window capture is F7.

---

## Phase 0: prove the verification framework, then benchmark
The user's requirement: "Prototype and Test your planned testing framework as part of phase 0 so
we can ensure it will work for our goals at every step."

This runs in a spike worktree off `feat/navmesh`. Framework pieces that pass are kept as the
skeleton for ticket 1. Prototype algorithm code (a throwaway Bowyer-Watson for bench data) is
deleted.

Every check has a **pass criterion** and a **negative control**: a deliberately broken case the
check must catch. F5 and F7 are exempt, and the table says why.

| # | Check | How | Pass | Negative control |
|---|---|---|---|---|
| F1 | Core unit specs on Lune, plus a pipeline guard that keeps running | Scaffold both cores with `npm run newpackage`, answers piped on stdin. Fix the template's `require(./"X")` → `require("./X")` first. Each core gets a permanent guard spec, "core must stay on the Lune pipeline": `expect(game).never_exists()`. Run `lune run coverage.luau package=<name>` | Output reports pipeline `lune`, the specs pass, and a coverage report is written | Adding the word `workspace` in a comment flips the pipeline, and the guard spec then **fails** in Studio. A failing `expect` fails the run |
| F2 | Mutation testing on the cores | `--mutate --mutate-limit=20` on a stub with a real branch (an orientation-sign helper) | Mutants run and are reported | A branch that is executed but not asserted is reported as a surviving mutant |
| F3 | Golden snapshots | tiniest `snapshot` on Lune. Add a save opt-in (e.g. env `SAVE_SNAPSHOTS=1` read in `LuneRunner.luau`; default off) | Save → re-run matches → an intentional change is accepted through the opt-in; two packages' specs don't collide | Changing one fixture coordinate fails, with expected and actual both printed |
| F4 | Screenshot loop | DrawList → SvgBackend → Edge PNG → Read, one command per fixture | Triangles, holes, path, labels and floor colours are visible; the command is repeatable | A dropped triangle or offset waypoint is visibly wrong |
| F5 | Fixture reach | `Fixtures.luau` required from a spec, the render script and the Studio bench | Same data in all three | Exempt: a broken require is a hard error, no silent failure |
| F6 | Debug package on Studio | Stub `constraineddelaunaydebug` with a DrawListRenderer spec; the runner goes through run-in-roblox | Pipeline reports roblox, and the spec passes | A failing spec reports back through the runner's stdout sentinel |
| F7 | Studio screenshot | DrawListRenderer draws a fixture; try a PowerShell `CopyFromScreen` of the Studio window | A PNG I can Read, **or** a documented "unreliable, user checks manually" | Exempt: the result is itself the finding |
| F8 | Network safety | A pure-Luau validator **is the authority**: dense arrays, string keys, no nil holes, functions, metatables or NaN; buffers allowed. A Studio BindableEvent round-trip is informational only (its marshalling rules are not documented as identical to remotes, and size limits are untested) | Fixture states pass the validator | A sparse array and a mixed table are rejected |
| F9 | Bench harness | Studio only (the house recipe). Check that `--!native` actually compiled, by an on/off delta or `debug.dumpcodesize()`. run-in-roblox runs the script in a plugin/edit context, where native codegen may not apply (unverified). If it doesn't, use the `tools/ci/OpenCloud.luau` transport, which runs a server Script, the context native codegen documents | Medians of 3+ runs, spread reported | A deliberately 2x-slower variant separates clearly from noise |
| F10 | Unpublished sibling dependencies [P2] | Mechanism in the list below the table | All four edges plus the transitive one. A no-argument `npm run setup` still sets up every package. Both CI jobs (Lune `--lune-only` for navmesh; Open Cloud `--roblox-only` for the two debug packages) set up and run their dependents | (a) After `npm run clear` then `npm run setup navmesh`, the navmesh specs pass. (b) Editing CDT src **without** re-running setup is still seen by the next test run of any dependent. (c) navmeshdebug resolves better-signal and both siblings |

**F10 mechanism (P2):**
- **Declare.** In `wally.toml`, `[custom] siblings = "a,b"`: a comma-separated string that the
  existing `parse_wally_toml` can read. Siblings stay out of `[dependencies]` until publish.
- **Test time: the only copy the tests read, so it can't be stale.**
  - The adapter's `M.materialize` already copies the package into a fresh build folder on every
    run, for both pipelines.
  - It is extended so that, after copying the setup-produced `_Index` (already in Wally's layout,
    including siblings' registry dependencies), it **overwrites only each sibling's `src`** with
    the current `lib/<sibling>/src`. The layout is written once, by setup.
  - If a sibling isn't set up, `materialize` errors loudly.
  - The adapter gets its own small Luau reader for the `siblings` key; its existing line scanner
    only reads the dependency sections.
- **Setup time: only for editor types and luau-lsp.**
  - `setup_package_for_testing.py` first sets up the package's siblings (transitively).
  - It then creates `Packages/_Index` for them immediately after `wally install` and **before**
    `rojo sourcemap`, `wally-package-types` and the Lune shims. Those steps only run when
    `Packages/` exists, and a sibling-only package gets no `Packages/` from Wally.
  - "Wally's layout" includes the link modules at the package root next to `_Index`, which
    graphutil-style `require("../Heap")` relies on.
  - After editing a sibling, re-run `npm run setup <dependent>` to refresh its editor types.
    Tests never need this.
- **Gates.** `_has_wally_dependencies` in `test_package.py` and `hasWallyDependencies` in
  the adapter both count a non-empty `siblings` as needing setup. Otherwise CI's
  `_ensure_setup` never sets up a sibling-only package.
  - `materialize` also emits the package-root link module and the Lune `_Index` require shims
    (the ones setup's `generate_lune_index_shims` makes).
  - Sibling copies stay at the build root's `_Index`, **never under `src/`**: coverage
    instruments only `src/`, so they don't count toward the dependent's coverage.
- **DEFERRED by user ruling D2:** "we will worry about publishing format when the whole thing
  is done".
  - Deferred:
    - the `publish.py` sibling→`[dependencies]` rewrite, done on a temporary copy and with
      `--dry-run`;
    - the reverse-sibling closure and topological order in
      `publish_detect_changed_packages.py`.
  - Known gaps until then, both recorded for the publishing ticket:
    - a CDT-only PR doesn't rerun its dependents in CI;
    - the four packages must not be publish-labelled.

**Benchmarks on the proven harness (Studio):**
- **B1 (R4 layouts):**
  - Layouts:
    - an interleaved number table;
    - split X and Y tables;
    - buffers (f64 or f32 coordinates, i32 indices);
    - `{vector}` (Roblox `Vector3` is the native `vector`);
    - `{Vector2}` read through accessor functions.
  - Workloads:
    - locate walk;
    - winding flood;
    - A*-like expansion;
    - filling the layout from a triangulation;
    - incrementally inserting a point and a constraint into existing state (Refine and future
      live edits need growth).
  - Run on about 50k vertices and 100k triangles, with `--!native` on and off.
  - Record µs per op, memory, and build cost. Memory is `collectgarbage("count")` measured while
    the structure is held, minus a baseline, next to an analytic byte count.
  - Candidates must pass F8, and all layouts must agree on the located triangle and the flood
    count before timing.
- **B2:** `const` vs `local` in the hot loops.
  - Luau already folds locals that are never reassigned, so a difference is expected to be
    small.
  - It is presented with the pipeline trade-off. Adopting `const` moves the cores to Studio,
    which gives up F2 (mutation testing), F3 (snapshots) and the fast Lune loop.
  - The two cores must adopt `const` together. If only CDT does, navmesh's Lune run can't parse
    its copied CDT and is forced to Studio.

## Verification (this phase)
- F1–F10 each pass, and each non-exempt negative control is caught.
- `docs/plans/navmesh/verification.md` records each check's command and output. Later tickets
  cite it as their test seams.
- `docs/plans/navmesh/bench.md` holds the medians, the raw runs and the PNGs.

## Phase 0 touched files
- **New packages:**
  - `lib/constraineddelaunay/` (`wally.toml`, `default.project.json`, `src/ConstrainedDelaunay.luau`,
    `src/Fixtures.luau`, `src/Tests/CDT.*.spec.luau`, `CONTEXT.md`);
  - `lib/navmesh/`, the same shape plus `[custom] siblings` in `wally.toml` (F10);
  - `lib/constraineddelaunaydebug/` (`src/SvgBackend.luau`, `src/DrawListRenderer.luau`, a spec);
  - `lib/navmeshdebug/` stub (`wally.toml` with better-signal plus siblings, and one spec),
    needed for F10 control (c).
- **Tooling:**
  - `scripts/new_package.py` (template fix);
  - `scripts/setup_package_for_testing.py` (sibling sync step, F10);
  - `scripts/test_package.py` and `tools/coverage/lune/adapters/modules_on_rails.luau` (siblings
    count as needing setup; `materialize` copies siblings at test time; F10);
  - (publish.py and the detect script are deferred; ruling D2)
  - `tools/coverage/lune/core/LuneRunner.luau` (snapshot save opt-in);
  - `tools/navmesh/render.luau` (screenshot script).
- **Repo docs and data:**
  - `.gitignore`: add `!lib/*/CONTEXT.md` so the new glossaries (and the existing untracked
    ones) are tracked;
  - `test/__snapshots__/`;
  - `CONTEXT-MAP.md`;
  - `docs/plans/navmesh/{verification,bench,review}.md`.
- **Scratchpad only:** `place.project.json`, `bench.luau`, and the prototype Bowyer-Watson.

## First actions once out of plan mode
1. Save the two standing rules as feedback memories and index them in MEMORY.md.
2. Move the debate record below to `docs/plans/navmesh/review.md`.
3. Run F1 (scaffolding) **before** writing any file under `lib/navmesh` or
   `lib/constraineddelaunay`. The script refuses directories that already exist.
4. Write the glossaries:
   - `lib/constraineddelaunay/CONTEXT.md`: winding group, constraint edge, input edge, Steiner
     vertex.
   - `lib/navmesh/CONTEXT.md`: the navmesh terms.
   - `CONTEXT-MAP.md`: an entry for each.
5. Run F2–F10, then B1 and B2. If any F-check can't be made to pass, stop and report it. That's
   a framework decision for the user.
6. Present the F results, then R4 and `const` with the numbers → user rules → to-spec → plan-debate
   → tickets.

## After Phase 0
The implementation-plan grill benchmarks every performance fork first:
- bespoke A* vs GraphUtil + Heap;
- grid vs quadtree for locate;
- the default TileSize;
- the NavMeshData layout;
- the DrawListRenderer primitive;
- how far clearance dependencies reach across tiles [P4];
- convex-polygon merging vs raw triangles (merging conflicts with triangle-width clearance).

## Glossary
- **CDT** (constrained Delaunay triangulation): a triangulation of points that is forced to
  contain given edges.
- **Constraint edge**: an input edge the triangulation must contain.
- **Input edge**: the id of one entry in `TriangulateInput.Edges`.
- **Steiner vertex**: a vertex the CDT adds (at constraint crossings, or by Refine).
- **Winding group**: an independent inside/outside count. A triangle's winding in group g is the
  net number of CCW group-g loops around it.
- **Refine**: adding Steiner vertices until triangle quality (minimum angle, maximum area) holds.
- **Floor**: a named height-field region.
- **Walkable ring**: an outline of walkable surface on a floor.
- **Obstacle**: a footprint cut out of a floor.
- **Area**: an integer surface class used for cost and filtering.
- **Seam**: a walk-through segment shared by two floors.
- **Link**: a point-to-point action hop, such as a ladder or a jump.
- **Tile**: the rebuild unit. A square cell of a floor.
- **Clearance / TRA\* widths**: the widest agent that can pass through each triangle, precomputed
  once. With them, any `AgentRadius` works on one mesh (Demyen & Buro's "Triangulation Reduction
  A*").
- **Funnel pass**: turning the corridor of triangles A* found into straight waypoints.
- **Snap**: placing a query point onto a floor.
- **Description** (`NavMeshDesc`): the authored input.
- **NavMeshData**: the plain built state. In code, parameters of this type are named `mesh`.
- **DrawList**: a plain list of debug drawing primitives.

## Progress
- Grill rounds 1–4 done. The API frontier is empty except R4 and `const`, which Phase 0 settles.
- Plan debate closed after round 4. P1–P7 were ruled D1–D3 (see [review.md](review.md)).
- **Phase 0 done** (2026-09-25, branch `spike/navmesh-phase0`, not committed yet):
  - **F1–F10 all pass,** each negative control caught.
    - Evidence and commands: [verification.md](verification.md).
    - Finding: the mutation tool treats `elseif` conditions as uncovered.
    - Finding: tiniest snapshot mismatches print whole blobs, with no diff.
    - F10 also exposed and fixed a setup ordering bug (the sibling `_Index` nesting the
      registry one).
  - **B1/B2 benchmarked:** [bench.md](bench.md).
    - Under native codegen, buffers win: locate 1.5x, insert 2.6–3.4x, build 2.4x, and 3.5–4x
      less memory.
    - `const` has no measurable effect.
  - **Rulings (2026-09-25):**
    - **`const`:** no `const` in the core packages. User: "No const in cores (Recommended)".
      This is a justified policy exception; the debug packages follow the policy.
    - **`elseif` blind spot:** fix the coverage tool, as a tooling ticket. User: "Fix the
      coverage tool (Recommended)".
    - **R4 ruled after the independent audit** (see bench.md, "Independent audit"):
      - **R4a:** topology (TriVerts, TriNeighbors, constraint and winding arrays) is stored in
        **i32 buffers**. User: "i32 buffers (Recommended)".
      - **R4b:** the CDT stores coordinates in an **f64 buffer**. NavMesh state stores them as
        native **`vector`** values (`vector.create`; Roblox Vector3). Exact predicates always
        use scalar f64 math on the components. User: "CDT f64 buffer, NavMesh vector
        (Recommended)".
      - Follow-on done: `PlainData.Check` accepts `vector` values (20/20 specs).
    - **S1, storage seam (user, 2026-09-25):** "can we make our accesses and operations generic
      to test easy swapping down the line? Then once we have a better idea of how they perform
      in the actual implementation we can swap out the generic functions for the actual calls
      to cut out the function call overhead. Until then we will go off the current
      benchmarks".
      - **One owner of the layout:** each core has one `Storage.luau`, the only module that
        knows the R4 layout.
      - **Plain module functions:** all other code uses the functions `GetTriVertex`,
        `GetNeighbor`, `SetNeighbor`, `GetVertex`, `AddVertex`, `AddTriangle` and `Reserve`,
        with the state as the first argument, aliased to locals in hot loops.
      - **State stays plain:** no functions are stored in it (U1).
      - **Contract spec:** a layout contract spec runs against every `Storage` implementation,
        so a swap is verified.
      - **Inlining later:** replacing hot call sites with direct reads is a mechanical,
        profiling-driven step after the real implementation exists, guarded by the contract
        spec and the goldens.
      - **Public reads go through the same functions** (`CDT.GetVertex` etc.). Raw buffers
        are not part of the public contract, so the layout stays swappable.
      - **Known cost:** the accessor layout (E) measured about 2x on reads. Module-level
        functions cached in locals are expected to cost less, but that's unmeasured;
        re-measure with the F9 harness once real code exists.
    - **Phase 0 closed.** Next: to-spec.

## Review additions: decisions added by the plan debate (all ruled; see review.md D1–D3)
| # | Addition | Why |
|---|---|---|
| P1 | The pure DrawList builders (`CDT.ToDrawList`, `NavMesh.ToDrawList`, and the `DrawList` type) live in the **cores**. `constraineddelaunaydebug` holds `SvgBackend` and one `DrawListRenderer`, which replaces U2's separately named DebugCDTRenderer/DebugNavMeshRenderer. `navmeshdebug` holds the editor. This keeps V2's two packages but changes what they contain; the ruling should cover U2's wording too. | Debug packages are on the Studio pipeline, where tiniest snapshots and mutation testing don't exist, so goldens must run in the cores. Renderers also stop reading storage whose layout is still open. |
| P2 | Unpublished siblings: `[custom] siblings`, siblings copied into the build folder on every test run (so a copy can never be stale), a setup-time copy for editor types only, sibling-aware setup gates, and a publish-time rewrite into `[dependencies]` in topological order (F10 mechanism). **Cost:** changes to five shared scripts (setup, test_package, the adapter, publish, and the new-package template fix). **Alternative for the user:** publish 0.0.x stubs and republish on every cross-package change. That needs no tooling changes, but it is outward-facing and turns every CDT edit into a publish-and-bump cycle before its dependents' tests see it. | Wally resolves siblings from the registry. Declaring an unpublished sibling in `[dependencies]` breaks `wally install`, which in turn stops the no-argument setup at the first failure. Setup and clear wipe any hand-vendored `_Index`. CI skips an unset-up package silently. |
| P3 | Serialize writes a format-version header; Deserialize errors on a mismatch. | Old buffers would otherwise decode silently wrong. |
| P4 | Clearance widths look across tile borders. `Update` recomputes dependent widths in neighbouring tiles and bumps their stamps. How far the dependency reaches is benchmark-gated. | Otherwise stale widths remain and `IsPathValid` wrongly returns true. |
| P5 | Each constrained edge records every input edge covering it, not just one. | Coincident constraints (a walkable edge on a tile line, flush obstacles) would otherwise break winding. |
| P6 | Refine documents its termination precondition, has a finite default `MaxSteiner`, and skips triangles whose small angle comes from the input. | Tile clipping and constraint splitting create small input angles, so a bare 20.7° bound can hang. |
| P7 | API cleanups: `FindNearestPoint` takes `filter` (one snap setting, `SnapExtents`); `MoveAlongSurface` returns `NavPoint`; `PathStatus` drops `"Unreachable"` (covered by `"Partial"`); `ClosedList` is dropped from the render options (no public socket, YAGNI); the PIL fallback and the Lune bench variant are dropped. | Duplicate settings, a lost floor, overlapping statuses, and no-ops. |

Debate record: [review.md](review.md).
