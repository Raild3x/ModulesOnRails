# 37: Uneven terrain: forest and river

**What to build:** Outdoor ground with slight height variation, a dense forest and a river,
built from Parts. It shows how small slopes and many obstacles affect the mesh and the paths,
and NPCs cross the river by a bridge or a ford.

**Blocked by:** 33 (map scenario harness)

**Status:** ready-for-agent. Ruled 2026-10-01: Parts first; voxel Terrain is ticket 39.

- [ ] **Ground:** gently uneven, built from many slightly tilted slabs and wedges. Slopes run
      from about 1 to 10 degrees, with small steps between pieces.
- [ ] **Forest:** many tree trunks (cylinders) of varied sizes, rocks, and a narrow trail
      through it.
- [ ] **River:** a water channel that can't be walked, sloped banks, a bridge (raised walkable
      deck, joined by seams), and a shallow ford with a weighted area.
- [ ] **Measure how slight height variation affects the mesh:**
  - floor, seam and triangle counts;
  - Build ms and bake bytes;
  - `FindPath` time and path smoothness (turns per distance).
  - Expect each tilted piece to become its own floor joined by seams. Report it, and note
    which adapter behaviour would help, such as merging near-coplanar faces or non-planar
    walkable rings (the core already supports creases).
- [ ] **Scenarios:**
  - cross the forest at radius 0.5 and 2 (the large agent takes the trail or detours);
  - reach the far bank by bridge when the ford is costly, and by the ford when it's cheap;
  - no path enters the water.
- [ ] **Simplification:** this is the dense, slightly rotated input the simplification passes
      target (`simplification-plan.md`, handoff Track F). Record numbers before Track F, and
      re-run after it lands.
- [ ] **A Studio screenshot** of the forest and river with paths.

## Layout sketch (Track M2, 2026-10-01, on paper while ticket 33 is open)

Not built yet. The file layout, scenario format and commands come from ticket 33's harness.

**Map:** about 200 x 160 studs, X east, Z south, one seed for everything.

| District | Extent (studs) | Built from | Counts |
|---|---|---|---|
| West meadow | x 0-80, z 0-160 | a heightfield of 10-stud cells, each split into two triangles; each triangle is a pair of thin WedgeParts (the usual Roblox triangle trick) | 8 x 16 cells, 256 triangles, about 512 wedges |
| River | a 10-14 stud channel meandering south from (100, 0) to (110, 160), two bends | the channel floor is not walkable; a Water block (obstacle) fills it to 1.5 studs under the bank tops; banks are tilted slabs, 15-25 degrees, down to the waterline | about 16 bank slabs a side |
| Bridge | over the river at z about 40 | a raised 6-stud-wide deck 2.5 studs above the banks, with a wedge ramp at each end | 1 deck, 2 ramps |
| Ford | z about 120, 10 studs along the river | the bed raised to 0.5 studs under the water; no Water block over it; `NavArea` ford id; banks slope down to it | 1 bed slab, 2 bank wedges |
| East forest | x 120-200, z 0-160 | terraces: strips of slabs tilted 1-10 degrees, hinged edge to edge (their top edges computed to coincide); some strips end in a 0.2-0.8 stud step instead of a hinge | about 40 strips, 6 steps |
| Trees | in the forest | upright cylinders, diameter 1.2-4, Poisson-disk, at least 2.5 studs apart (edge to edge) | about 150 |
| Rocks | in the forest and on the banks | blocks and wedges, 2-6 studs, rotated at random | about 30 |
| Trail | through the forest, west to east, 3 bends | a 5-stud corridor kept clear of trees and rocks | 1 |

**Slopes come from a sweep, not one map.** The same layout is built at max tilt 0 (flat, every
piece coplanar), 1, 3, 5 and 10 degrees. Each tilt gets floor, seam and triangle counts, Build
ms, bake bytes, `FindPath` ms and turns per 100 studs. The 0-degree build is the baseline: what
the mesh would cost if the pieces were merged.

**Scenarios planned:**
- `forest-r0.5` and `forest-r2`: west meadow to the east edge. Radius 2 needs 4 studs, which
  only the trail gives (tree gaps are kept under 4 studs off the trail), so it takes the trail
  or detours round the forest.
- `bridge-when-ford-costly` (ford cost 20) and `ford-when-cheap` (ford cost 1): a goal on the
  east bank near the ford.
- `no-water`: every path above, plus a sample of random start-goal pairs, never has a waypoint
  inside the channel outside the ford.
- `steps`: the terrace steps. Until ticket 34's step-height rule lands, a step is a wall; the
  scenario records that and the forest stays crossable round the steps.

**Questions the build will answer (expected, not yet measured):**
- Do the hinged slabs join by seams? The adapter seams an edge that lies on another floor's
  face, so a computed hinge should; a slab's end face, tilted with it, may poke past the hinge
  and cut a sliver out of the neighbour floor, which would block the seam.
- At a valley, each slab stands above its neighbour's plane, within the agent's height, so it
  becomes an obstacle ring on every neighbouring floor. That multiplies obstacle rings; the
  known O(triangles x rings) cost (known-gaps.md) may show here.
- The seam search is faces x faces x edges in the adapter. At about 600 faces it should be
  fine; the sweep will show it.
