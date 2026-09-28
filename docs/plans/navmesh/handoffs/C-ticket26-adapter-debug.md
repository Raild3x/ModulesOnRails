# Track C: ticket 26, the Part adapter and debug ergonomics

Read [README.md](README.md) first for the house rules and the parallel map. The full ticket is
`docs/plans/navmesh/tickets/26-authoring-and-debug.md`, and it came from `REPORT.md` pain points
6 and 12-14 in `examples/navmesh-demo`.

**Setup:** a worktree off `feat/navmesh` (for example branch `navmesh-adapter`). This track
mostly adds new code, so it can run beside A and B. Leave step 4 until Track A has merged.

## 1. A Part to NavMeshDesc adapter (the main item)
- **Why:** today a level is authored twice, once as polygons and once as Parts. A ramp needs
  three hand-written pieces: its own floor, two seams, and an obstacle cut into the ground under
  it. See `examples/navmesh-demo/Level.luau` and `StudioDemo.buildLevel`.
- **Scope:**
  - anchored blocks, wedges and cylinders produce walkable floors (top faces), obstacles, seams
    at ramp feet and tops, and the cut under a solid ramp;
  - welding cracks between walkable Parts is ruled to live **in the adapter, not the core**
    (simplification plan, decision D3).
  - The adapter produces the dense, slightly rotated input the simplification passes are for.
    Keep its output plain `NavMeshDesc` data, so Track D can run on it.
- **Needs user rulings before building:**
  - **Where it lives:** a module inside `lib/navmesh`, or a new package such as
    `navmeshadapter`. The core has no Instance dependency today and runs headless under Lune.
  - **How floors are chosen from Parts:** by tag, by attribute, by height clustering, or by a
    caller-given list.
  - Prototype on the demo level, then present options with pros and cons.
- **Gate:**
  - Rebuild the demo level from Parts, and show it builds the same mesh as `Level.luau` (or
    explain each difference).
  - Take a Studio screenshot, and use the Read tool to check it.
  - Specs run in the package's pipeline. A Roblox-only module needs the Studio test path, as
    `navmeshdebug` has; see `tools/navmesh/studio/studio.py`.

## 2. Debug drawing (low conflict)
- several paths in one draw list;
- a palette option: the default area grey and wall black vanish on grey or dark baseplates;
- disabled links drawn differently;
- tile bounds drawn at the floor's height;
- `DrawListRenderer` reachable from `navmeshdebug`.

Files: `lib/navmesh/src/DrawList.luau`, `lib/navmeshdebug`, and `lib/constraineddelaunaydebug`
(where the renderer lives).

## 3. Smaller authoring items
- **A documented recipe for shipping a bake in a place:** for example base64 in a `StringValue`
  with chunking, since the demo's `\xNN` string literal is 4x the size. Measure the options.
- **Editor:** a public way to place markers and set the radius from code (`EditorShot.luau`
  calls the private `_apply`), and a "build and save bake" action.
- **Clearer errors:** unknown `QueryFilter` keys (for example `AgentRaduis`) and, optionally, a
  `HasPendingChanges(mesh)`. Erroring on unknown keys is an API ruling: ask.

## 4. `vector` typing (only after Track A has merged)
- **The problem:** the public types say `Vector3`, but the runtime uses `vector` throughout, so
  strict-mode callers under both Lune and Roblox get type errors.
- **Options:** type the API as `vector`, or a `Vector3 | vector` alias. That is a user ruling:
  run `luau-lsp analyze` on sample code both ways, and present the error counts.
- **Why it waits:** it touches every public signature in `Types.luau` and `NavMesh.luau`, which
  Track A is changing.

## When done
Update the ticket 26 as-built notes, `review.md` and `CONTEXT.md`. Merge into `feat/navmesh`.
Track D's simplification passes are unblocked once the adapter lands.
