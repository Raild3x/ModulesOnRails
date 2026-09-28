# 21: Editor

**What to build:** Level designers edit navigation descriptions with the mouse and export them as code.

**Blocked by:** 18, 20

**Status:** ready-for-agent

- [x] The `EditorState` machine driven by synthetic events; `NavMeshEditor`; an `ExportSource` round-trip over every fixture
- [ ] A manual Play-mode check by the user (steps below)

Spec: [../spec.md](../spec.md). Gates: the spec's "Gates for every ticket".

## Built (2026-09-27)
The work is in `lib/navmeshdebug/src/`.

- **`EditorState.luau`:** the state machine. It holds the description, the selection, the
  start and goal markers, and the agent radius. `Apply(state, event)` returns whether the
  description changed.
  - It touches no Instances or services and never yields. Positions are `vector`s, the same
    convention as the NavMesh core.
  - **Modes:**
    - `"NavMesh"` edits a `NavMeshDesc`: walkable, obstacle and area rings, seams and links.
    - `"CDT"` edits a `TriangulateInput`: points, and directed constraint edges with groups. A
      point (x, y) sits at world (x, 0, y).
  - **Pointer events carry a world ray.**
    - `PointerDown` selects the handle nearest the ray, within 1 stud.
    - `Drag` moves the selection across the horizontal plane at its own height, so a ring
      keeps its Y.
    - New positions snap to a 0.25-stud grid, so exported numbers stay short.
  - **Events:**
    - `PointerDown`, `Drag`, `PointerUp`;
    - `CreateRing` (Walkable, Obstacle or Area; in CDT mode these are groups 1, 2 and 3);
    - `CreateEdge` (CDT: an open edge with group 0);
    - `CreateSeam` and `CreateLink` (NavMesh; a link can be one-way and labelled);
    - `InsertVertex` (the midpoint of the edge after the selection);
    - `Delete`:
      - it removes a vertex, and the whole ring once fewer than 3 vertices are left;
      - it removes a seam, a link or a marker;
      - it removes a CDT point, closing its ring through the point's neighbours;
    - `SetMarker`, `SetAgentRadius`, `SetDescription`.
  - It errors on an unknown event, an event for the other mode, or a description of the wrong
    shape. The editor shows these errors instead of throwing them.
- **`LuauLiteral.luau`:** the generic plain-data printer, plus a parser for exactly that
  grammar.
  - **Output:**
    - numbers use Luau's shortest exact text, so `math.huge`, `-0` and `0/0` round-trip;
    - strings are escaped;
    - vectors print as `vector.create(...)`;
    - dictionary keys are sorted, so equal data prints equal text;
    - short plain lists stay on one line, and long ones wrap at 100 columns.
  - The parser means importing doesn't need `loadstring`, so it works on a client. It accepts
    `Vector3.new(...)`, comments and a leading `return`.
  - **Finding:** Roblox's `string.format` flushes subnormals such as `5e-324` to `0`, so the
    printer uses `tostring` instead.
- **`NavMeshEditor.luau`:** `new(parent, mode, initial)`, with `Changed`, `GetDescription`,
  `ExportSource` and `Destroy` as the spec defines them.
  - `Changed` is a better-signal that fires a copy of the description after each edit.
  - `Destroy` goes through Janitor, added to `wally.toml`.
  - It maps `UserInputService` onto `EditorState` events. After an edit it rebuilds with
    `NavMesh.Build` or `CDT.Triangulate` and redraws with `DrawListRenderer`. The drawing
    has:
    - the triangles, walls, seams and links;
    - a tile grid you can toggle;
    - the path between the markers at the agent radius;
    - the handles, with a ring around the selected one;
    - the markers, each drawn as a circle at the agent radius.
  - **Errors don't crash it.** A build error, such as a self-intersecting ring, keeps the last
    good mesh and shows the message in red in a status bar. The same happens for a path error
    or a rejected event.
  - There is a status bar, and a radius slider (click or drag it, or press `[` / `]`).
- **Tooling** (`tools/navmesh/studio/studio.py`):
  - `shot editor[:<Fixture>]` is the F7 capture of the editor (`EditorShot.luau`).
  - `play [--fixture F] [--mode NavMesh|CDT] [--no-open]` builds
    `.bench/navmesh/studio/editor.rbxl`, with a baseplate and a LocalScript that opens the
    editor, then opens it in Studio.

**API deviations from the spec** (the coordinator decides whether the spec changes):
- `NavMeshEditor.ImportSource(source)` is a new static function: the "import" half of export
  and import.
- `_apply(event)` and `_Keys` are private hooks that the specs use.
- `navmeshdebug` now also declares `constraineddelaunay` as a sibling. CDT mode needs
  `CDT.Triangulate` and the CDT fixtures, and the spec's sibling list names only navmesh and
  constraineddelaunaydebug.
- `Apply` changes `state` in place. It is "pure" only in touching no Instances and never
  yielding.
- The radius slider is a clickable bar plus the `[` / `]` keys.

### Gates
- **`navmeshdebug`** (`--roblox-runner=studio`): **40/40** specs.

  | file | lines | branches | functions |
  |---|---|---|---|
  | package total | 91.9% | – | 88.6% |
  | `EditorState` | 96.7% | 88.7% | 100% |
  | `LuauLiteral` | 93.9% | 88.2% | 100% |
  | `NavMeshEditor` | 82.8% | 61.5% | 75% |

  `NavMeshEditor`'s uncovered code is the live mouse and slider callbacks, which the manual
  check covers.
- **Round-trips.** Every `NavMesh.Fixtures.All` scenario, and every CDT fixture with its
  `ToInput`, goes `Print` → `Parse` → deep-equal, and re-printing gives the same text. The
  specs also cross-check with Roblox `loadstring`, which is available in the Studio runner.
  - Before Studio, the same set was also checked under Lune against the real compiler
    (`luau.load`).
- **`selene` and `stylua --check`:** clean.
- **Negative controls:** each failed its own spec, 36/39 passing, and was then restored.
  - The printer limited to `%.15g`: "numbers parse back exactly" failed.
  - The CDT ring-closing on delete removed: "deleting a ring point closes the ring" failed.
  - `NavMeshEditor`'s build `pcall` removed: "a build error keeps the last good mesh" failed.
- **Overlay caveat.** The NavMesh features (seams, links, `AgentRadius`, the new fixtures)
  came from the main checkout's uncommitted `lib/navmesh/src` and are not committed here.
  `lune run coverage.luau package=navmesh` passed with that overlay (150/150).

### F7 screenshot
Command: `python tools/navmesh/studio/studio.py shot editor`. The output is
`.bench/navmesh/studio/editor.png`, with the viewport crop at `editor-viewport.png`.

The shot shows `ThreeFloorStairs` from an oblique camera:
- the Ground floor (green), the Stairs ramp (blue) rising to the Upper mezzanine (orange,
  y = 5), and the orange tile grid;
- a new obstacle that was dragged into a skewed quad, cut out of Ground;
- handle crosses on every vertex;
- the start marker (green circle) on Ground and the goal marker (red circle) on Upper;
- the path (pink) from start, around the obstacle's corner, to the foot of the ramp, up it,
  and across Upper to the goal;
- the status bar: `NavMesh | radius 0.75 | selected Goal marker | path Success`, with the
  slider filled to 0.75/4.

### Manual Play-mode check (for the user)
1. **Set up.** From the repo root, run:
   ```sh
   npm run setup navmeshdebug
   python tools/navmesh/studio/studio.py play
   ```
   Studio opens `.bench/navmesh/studio/editor.rbxl`. Press **Play (F5)**.
   - For CDT mode, run `play --mode CDT --fixture OverlappingObstacles` instead.
   - To use another fixture, pass `--fixture LinkJump` (or any NavMesh fixture name).
2. **Check the start state.** You spawn on a grey baseplate. `ThreeFloorStairs` is drawn:
   Ground (green), the ramp (blue) and Upper (orange, 5 studs up), with the orange tile grid.
   A status bar and a slider sit at the bottom left.
   - WASD, Space, I and O still move the character and camera; the editor doesn't use them.
3. **Drag a vertex.** Left-click a black cross on a floor corner. A yellow ring marks it, and
   the status bar names it (for example `Ground Walkable ring 1 vertex 3`). Hold and drag:
   the corner follows the mouse at its own height, and the mesh re-triangulates as you move.
4. **Add rings.** Point at empty Ground and press:
   - **1** for a walkable square;
   - **2** for an obstacle square (a hole appears);
   - **3** for an area square.

   Drag their corners. Press **V** to insert a vertex after the selected one, and **X** (or
   Delete) to delete it. Deleting down to 2 vertices removes the ring.
5. **Break it on purpose.** Drag one obstacle corner across the opposite edge so the ring
   crosses itself. The status bar turns red with `ERROR: NavMesh.Build: …`. The last good mesh
   stays drawn, and the editor keeps working. Drag the corner back and the error clears.
6. **Make a path.** Press **Z** with the pointer on Ground (the start marker, a green circle),
   then **C** with it on Upper (the goal, a red circle).
   - A pink path should run up the ramp, and the status bar should say `path Success`.
   - Drag either marker and the path follows.
   - Click or drag along the slider, or press `[` / `]`: the marker circles grow and the path
     keeps further from walls. Once the radius is too wide for the 4-stud ramp, expect the status
     to change (to `Partial`, if the goal can no longer be reached).
7. **Seams and links.**
   - Press **5** for a two-way link (4 studs along +X from the pointer), and **6** for a
     one-way link. Drag their ends; the arrows follow.
   - Press **4** for a seam between the selected floor and the next floor; drag its ends
     onto a shared edge. A seam that isn't on both floors' edges shows a Build error, as it
     should.
8. **Tiles.** Press **T** to hide and show the tile grid.
9. **Export.** Press **P**. The Output window prints the description as a Luau table
   literal. Copy it into a script:
   - `NavMesh.Build(<pasted>)` should build;
   - `NavMeshEditor.ImportSource("<pasted>")` should give the same description back.
10. **Stop Play.** Everything the editor drew disappears.

Please report anything that doesn't match these steps, especially drag feel, picking on the
upper floor, and whether the slider is usable.
