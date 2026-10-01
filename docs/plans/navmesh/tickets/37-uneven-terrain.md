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
