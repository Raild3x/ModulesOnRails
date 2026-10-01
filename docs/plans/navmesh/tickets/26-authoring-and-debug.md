# 26: Authoring and debug ergonomics

**What to build:** Levels authored once, as Parts, and debug drawing that works for a real
scene.

**Blocked by:** none

**Status:** done (2026-10-01). The `vector` typing item was ruled won't-fix: the public types
stay `Vector3`. The rulings are in review.md (2026-09-28 and 2026-10-01).

- [x] **A Part to `NavMeshDesc` adapter** for anchored blocks, wedges and cylinders.
  - It produces walkable floors, seams at ramp feet and tops, and the obstacle cut under a
    solid ramp.
  - Today the demo authors its level twice, and a ramp needs three hand-written pieces.
- [x] ~~**Types say `vector`,** or a `Vector3 | vector` alias.~~ Won't fix (ruled 2026-10-01):
      strict Roblox callers, the main audience, get no errors with `Vector3`. Strict Lune
      callers get 23 in the measured sample; the numbers for every option are in review.md.
- [x] **Silent mistakes get errors:**
  - `Walkable = ring` (a ring instead of a list of rings);
  - unknown `QueryFilter` keys (for example `AgentRaduis`);
  - optionally, a `HasPendingChanges(mesh)`.
- [x] **Debug drawing:**
  - several paths in one draw list;
  - a palette option, since the default area grey and wall black vanish on grey or dark
    baseplates;
  - disabled links drawn differently;
  - tile bounds drawn at the floor's height;
  - `DrawListRenderer` reachable from `navmeshdebug`.
- [x] **A documented recipe for shipping a bake** in a place (for example, base64 in a
      `StringValue`, with chunking), since a `\xNN` string literal is 4x the size.
- [x] **Editor:**
  - a public way to place markers and set the radius from code (`EditorShot.luau` calls the
    private `_apply`);
  - a "build and save bake" action.

## As-built (2026-10-01)

### Part adapter
A new package, `lib/navmeshadapter`, with `FromParts(walkable, obstacles, options?)`.
- **Floors:** chosen from caller-given lists (ruled).
  - A walkable Part's faces no steeper than `MaxSlope` (45 degrees) are walkable.
  - Faces on one plane form one floor, named after its first Part (`Step`, `Step 2`, ...).
  - A walkable Part with a number attribute `NavArea` gives an area.
- **Cuts:** a Part standing within `[0, AgentHeight)` (default 5) above a floor cuts its
  footprint out of that floor.
  - This covers crates, walls and the ground under a solid ramp.
  - A Part that only touches the floor does not cut it. That includes the floor's own Parts and
    any Part below it.
- **Seams:** an edge of one floor's face that lies on another floor's face becomes a seam,
  clipped to that face. Both faces find it, and it is kept once.
- **Welding (D3):** a corner within `WeldTolerance` (0.05) of an edge of another face on the
  same floor moves onto that edge, unless the corner is inside that face.
- **Shapes:**
  - Blocks, wedges (the slope rises towards +Z) and cylinders (the axis is X; `CylinderSides`
    is 16).
  - Any other shape errors, naming the Part.
  - Raycasts in Studio confirmed the wedge and cylinder conventions.
- **Specs:**
  - 25 specs, run under Lune with `@lune/roblox` Parts. The module reads only `Shape`, `Size`,
    `CFrame`, `Name` and attributes.
  - Coverage is 100% of lines, branches and decisions.
  - Mutation score 86.3%. The survivors are tolerance boundaries and equivalent mutants.
  - A scene turned 30 degrees found a real bug: f32 noise made one seam come out twice. It is
    fixed.
- **Demo:**
  - `LevelParts.luau` is the level as Parts, and the Studio place builds its mesh from them.
  - `adapter_check.luau` finds the same walkable region as `Level.luau`, and catches a crate
    moved one stud.
  - The Parts give 63 triangles against `Level.luau`'s 48. The ground is built in pieces around
    the mud, and the edges between pieces stay in the mesh until edge dissolve (C1) lands.

### Silent mistakes
- Unknown `QueryFilter` keys error at the call (ruled). Ticket 24's `GoalFallback` is one of the
  known keys.
- `HasPendingChanges(mesh)` is added (ruled).
- `Walkable = ring` already had a clear error, from the dogfood fixes.

### Debug drawing (merged from `navmesh-debugdraw`)
- `ToDrawList(mesh, options?, paths?)` takes one path or a list of them.
- New palette options: `PathColors`, `FloorColors` (in floor-name order), `AreaColors` and
  `WallColor`. Lists cycle, and the defaults are unchanged.
- Disabled links are drawn faded (`#ce93d8`).
- Tile bounds are drawn at the tile's lowest height (0 for an empty tile).
- `NavMeshDebug.DrawListRenderer` re-exports the renderer.
- `DrawList.luau` mutation score: 98.2%.
- Studio shot: `studio.py shot palette`.
- **Not done:**
  - Redrawing only the paths still needs a second renderer.
  - `AlwaysOnTop` wireframes still show through walls.

### Shipping a bake (merged from `navmesh-authoring`)
This is a recipe, not API.
- **Format:**
  - The bake is base64 text across StringValues named `1`, `2`, ... in a Folder.
  - Each value stays under 200,000 characters, because a script can't set a longer one.
  - The text is zstd-compressed first when the bake is made in Studio.
- **Where it is documented:**
  - One loader reads both forms. It is documented on `NavMeshEditor.SaveBake`.
  - The recipe is in the `NavMesh.Serialize` doc.
  - The numbers are in bench.md, under "Shipping a bake in a place".
- **Bench map (a 580 KB bake):**
  - 227 KB of text in 2 values, which loads in 1.4-1.7 ms.
  - A `\xNN` literal is 4.1x the bake's size, and Studio can't set one that long.

### Editor
- `SetMarkers(start, goal)` and `SetAgentRadius(radius)` replace the private `_apply` calls in
  `EditorShot.luau` and the demo's `studio.py`.
- `SaveBake(parent)` and the B key build and save a bake.

### Gates (after merging tickets 23 and 24)
- navmesh: 257 specs, 99.1% of lines.
- navmeshadapter: 25 specs.
- navmeshdebug (Studio pipeline): 45 specs.
- `NavMesh.luau` mutation score: 98.1%.
