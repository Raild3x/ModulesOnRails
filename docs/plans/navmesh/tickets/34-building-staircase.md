# 34: Building with a staircase

**What to build:** A two-storey building made of Parts, whose upper floor is reached by a real
staircase of individual steps. NPCs of several sizes walk up and down it.

**Blocked by:** 33 (map scenario harness)

**Status:** ready-for-agent

- [ ] **The map:** a two-storey building with walls, a doorway, an upper floor slab, and a
      staircase built from separate step Parts.
  - Use a typical Roblox stair: about a 1-stud rise, with a landing and a U-turn.
  - Add a second, straight stair that is narrower.
- [ ] **Scenarios:**
  - ground to upper floor and back, at radius 0.5, 1 and 2;
  - the narrow stair rejects radius 2, which goes the long way or returns Partial;
  - a path that must use the landing.
- [ ] **Steps must be walkable as a stair.**
  - Today each step's top is likely its own floor, with no seam to the next step: a riser's
    top edge doesn't lie on the next step's surface.
  - If the scenarios fail for that reason, add a step-height rule to the adapter: faces whose
    edges meet within a maximum step height are joined. Keep that a Part-adapter option,
    since the core already supports seams. Ask the user if the rule's shape needs a ruling.
  - The specs must cover it, with a negative control.
- [ ] **Compare a wedge ramp with the same rise.** Report floor, seam and triangle counts,
      Build ms and path length for each. Include waypoint heights along the stair; ticket 25
      is the follow-up if interpolated Y cuts through the steps.
- [ ] **A Studio screenshot** of the building, the mesh and the scenario paths, checked with
      the Read tool.
