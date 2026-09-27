# 20: Studio rendering of NavMesh views

**What to build:** Developers see meshes and paths in Studio.

**Blocked by:** 16

**Status:** ready-for-agent

- [x] `DrawListRenderer` on real meshes; the renderer-primitive benchmark; an F7 screenshot

Spec: [../spec.md](../spec.md). Gates: the spec's "Gates for every ticket".

## Built (2026-09-27)
- **`DrawListRenderer` fills triangles.** Each (layer, colour) gets one `EditableMesh`-backed
  `MeshPart`, split every 20,000 triangles (the EditableMesh cap).
  - Fills are 60% transparent. Triangle outlines stay on the `WireframeHandleAdornment`, so the
    edges read like the SVG's stroked polygons.
  - Lines, points, circles, arrows and labels are unchanged, and so is the public API.
    `SetLayerVisible` covers fills too (Transparency 1). An unknown `Kind` still errors.
  - Each triangle is wound to face up (+Y) so floors are seen from above.
  - `CreateMeshPartAsync` yields for one frame. To stop `Draw` yielding, each part is created
    on a spawned thread. The meshes themselves are built synchronously inside `Draw`.
    - A generation counter makes a newer `Draw` (or `Destroy`) discard fills that are still
      being created.
    - So fills appear 1-3 frames after `Draw`. Edit mode throttles frames; a focused client
      would take one frame.
  - Neither fills nor adornment lines replicate. Draw where you look: in Studio, or on a client.
- **Tools** (`tools/navmesh/studio/`; run `npm run setup constraineddelaunaydebug` and
  `npm run setup navmesh` first):
  - `python tools/navmesh/studio/studio.py bench --runs 3 --rounds 5`: the benchmark
    (`RendererBench.luau`).
    - It exits 1 when a run doesn't finish, or when any variant's `Draw` yields (a coroutine
      check).
  - `python tools/navmesh/studio/studio.py shot <courtyard|props|bench|terrain|walls>`: the F7
    screenshot (`Shot.luau` + `capture.ps1`).
    - PNGs land in `.bench/navmesh/studio/` (gitignored).
    - It briefly maximizes and focuses Studio.

### Renderer-primitive benchmark
**Method.** This is F9's method on the Studio pipeline:
- 3 runs x 5 interleaved rounds, with the variant order rotated;
- the best of 3 per round, then medians.

**What each variant draws.** Every variant draws the whole `NavMesh.ToDrawList` list with the
same lines and outlines. Only the triangle fill differs.

**Columns:**
- **draw:** the time `Draw` blocks on a fresh renderer.
- **redraw:** the time `Draw` blocks on a warm renderer, given a changed list (every point
  raised 0.25 studs).
- **ready:** the frames until the fills exist.
- **instances:** the renderer's descendants.
- **engine MB:** the change in the Instances, BaseParts, GraphicsParts and GraphicsMeshParts
  counters.

**Scenes.** Courtyard (with a FindPath path) and the four bench scenes, at the default
TileSize.

`bench` (4,605 triangles, the largest):

| variant | draw ms | redraw ms | ready frames | instances | engine MB |
|---|---|---|---|---|---|
| outline only (Phase 0 baseline) | 5.48 | 5.29 | 0 | 3 | 0.00 |
| 2 WedgeParts per triangle | 251.42 | 304.17 | 0 | 9,213 | 25.58 |
| WedgeParts, pooled across Draws | 246.68 | 57.66 | 0 | 9,213 | 25.32 |
| **EditableMesh per (layer, colour)** | **10.61** | **10.90** | 3 | 4 | ~0 |
| shipped `DrawListRenderer` | 10.96 | 10.88 | 3 | 3 | ~0 |

Draw ms on every scene (wedges / pooled wedges / EditableMesh / shipped; outline baseline):

| scene | triangles | outline | wedges | pooled | EditableMesh | shipped |
|---|---|---|---|---|---|---|
| courtyard | 32 | 0.08 | 1.69 | 1.70 | 0.26 | 0.26 |
| props | 3,152 | 3.83 | 169.15 | 167.89 | 7.39 | 7.66 |
| bench | 4,605 | 5.48 | 251.42 | 246.68 | 10.61 | 10.96 |
| terrain | 1,297 | 1.60 | 72.15 | 71.22 | 3.17 | 3.39 |
| walls | 692 | 0.91 | 36.96 | 36.96 | 1.82 | 1.92 |

Run-to-run spread was within about 15% (for example, EditableMesh on bench:
10.61/12.14/10.53).

**Choice: EditableMesh.**
- It draws 24x faster than wedges on the largest scene. Its fill adds about 5 ms over outlines
  alone for 4,605 triangles.
- It keeps the instance count constant: 1 part per (layer, colour), against 2 per triangle.
- Pooled wedges only fix the redraw. Even then they're still 5x slower than EditableMesh, and
  they cost about 25 MB and 9,213 parts.
- Its costs:
  - Fills appear a frame late. Handled: `Draw` never yields.
  - EditableMesh caps each mesh at 20,000 triangles and 60,000 vertices. Handled: meshes are
    chunked.
  - If EditableMesh is unavailable, the renderer warns and falls back to outlines only.
- The shipped renderer matches its prototype within noise. It has one fewer instance because
  the prototype put its fills in a sub-Folder.

**What edit mode can't measure:**
- **Frame rate.**
  - In edit mode, run-in-roblox's Studio fired `RenderStepped` about twice a second and
    `PreRender` about 41 times.
  - `Stats.RenderGPUFrameTime` read 0.
  - `RenderCPUFrameTime` stayed at 3.5-7.9 ms for every variant, the empty scene included.
  - So render cost is not in the table. Draw-call count (1 per fill chunk against 1 per part)
    and transparent-part sorting both favour EditableMesh, but that is not measured here.
- **EditableMesh memory.** It does not show up in the `DeveloperMemoryTag` counters, which
  read about 0 or slightly negative, within noise. `GetEditableMemoryBudget` doesn't exist in
  this Studio build.
  - Analytic estimate: 3 unshared vertices per triangle, so 13,815 vertices for bench.
- **The `heap KB` (gcinfo) column** was dropped after the smoke run. It moved by tens of MB
  either way with GC timing.

### F7 screenshots (`python tools/navmesh/studio/studio.py shot courtyard` / `shot bench`)
The full-window PNGs are `.bench/navmesh/studio/courtyard.png` and `.bench/navmesh/studio/bench.png`.
Viewport crops were reviewed with Read.
- **Courtyard:**
  - The L-shaped yard is filled green with its triangle outlines.
  - The hole and the merged two-crate obstacle are open.
  - The crate notch through the east wall is open.
  - Walls are black.
  - The FindPath path runs from `start` (1, 10) through (10, 20) to `goal` (16, 28), and its
    waypoints match the printed `[MARK] waypoint` lines.
- **Bench** (256 studs):
  - About 650 obstacle holes with wall outlines, over a filled green mesh.
  - The orange 32-stud tile grid.
  - A 23-waypoint pink path from `start` to the far corner that threads between obstacles.
    Studio's Rojo update toast covers the goal label.

**Negative controls:**
- **Winding (visual).** Flipping the fill winding (`Y < 0` → `Y > 0`) made the fills vanish
  from above: the yard read as open sky, like the holes.
  - File: `.bench/navmesh/studio/courtyard-flipped.png`.
  - This proves the +Y rule is what makes fills visible.
- **Specs.** Removing the flip failed "fill triangles face up". Removing the generation check
  failed "replaces the previous drawing, discarding fills still being created" (3 fills where
  1 was expected).

**Observations** (not renderer bugs; the renderer draws exactly the waypoints FindPath returns):
- **Courtyard path.** It bends at (10, 20), a corner of the area-2 patch, not a wall corner. The
  midpoint-node A\* picked a corridor that goes around the patch, and the funnel is tight
  within that corridor.
- **Tile borders.** Where a tile border coincides with triangle edges, the green outline and
  the orange tile line are both always-on-top at the same depth. So some tile lines look
  faint.

### Gates
- **`constraineddelaunaydebug`** (`--roblox-runner=studio`):
  - 9/9 specs.
  - `DrawListRenderer.luau`: 96.2% lines, 100% functions, 84.4% branches.
  - The package total is 64.5% lines. That's because `SvgBackend` has no specs: it's exercised
    by the Lune render script.
  - The uncovered branches are the defensive EditableMesh-unavailable and
    `CreateMeshPartAsync`-failed paths.
- **`navmeshdebug`** (dependent): 4/4.
- **`selene` and `stylua --check`:** clean.
- **Mutation testing:** not run. `--mutate` is the cores' gate, and this ticket touches only the
  debug package and tools.
