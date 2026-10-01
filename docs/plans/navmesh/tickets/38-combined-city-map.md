# 38: Combined city map (regression bench)

**What to build:** One map joining the building with stairs and elevator, the street, and the
forest and river. NPCs run daily routes across all of it, and the map becomes the regression
bench for realistic content.

**Blocked by:** 35 (elevator), 36 (street), 37 (uneven terrain)

**Status:** ready-for-agent

- [ ] **The map:** the pieces from 34-37 placed together. The street connects the building to
      the outdoor area, and the river separates part of the outdoors.
- [ ] **Daily routes:**
  - upstairs in the building, by stairs or elevator;
  - out the door, across at a crosswalk;
  - through the forest, over the river.
  - Run them for a seeded crowd of NPCs with mixed radii and costs, using the follower.
- [ ] **Dynamic events during the run:** the elevator going out of service and back, a door
      closing, and a crate dropped on a sidewalk. Record repaths and the decisions from
      ticket 35's reroute policy.
- [ ] **Bench numbers in bench.md,** so later tickets can be checked against them:
  - Build ms, bake bytes, Deserialize ms;
  - `FindPath` median and p95;
  - `Update` per event;
  - triangle, floor and seam counts.
- [ ] **Studio screenshots:** an overview, plus one per district.
- [ ] Runs in one command, so any future change can be checked against this map.
