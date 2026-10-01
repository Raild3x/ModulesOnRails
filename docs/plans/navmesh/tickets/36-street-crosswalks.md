# 36: Street with sidewalks and crosswalks

**What to build:** A street in front of ticket 34's building. Weighted areas keep NPCs on the
sidewalks and send them across at crosswalks: the test bed for area costs on a realistic
layout.

**Blocked by:** 34 (the building, and its step-height rule for the curbs)

**Status:** ready-for-agent

- [ ] **The map:** a road, raised sidewalks with curbs (a small step up), crosswalks with curb
      cuts (flush ramps), a few parked cars as obstacles, and the building's entrance on one
      sidewalk.
- [ ] **Areas:** road, sidewalk and crosswalk get their own area ids through the adapter.
  - Ticket 26's open item, the adapter's area-name table (research D5), would let scenarios
    say `areas.Road`. Build it here if it's small, or note the gap.
- [ ] **Scenarios:**
  - a pedestrian on the far side reaches the entrance via a crosswalk;
  - with a high road cost, no path crosses the road outside a crosswalk;
  - with a road cost of 1, paths cut straight across (a negative control for the weighting);
  - a large-radius NPC still fits the curb cuts.
- [ ] **Measure:**
  - the share of paths that jaywalk, at several road costs;
  - the detour overhead against a straight crossing;
  - any bends at equal-cost area edges (tickets 25 and 32), noted with a screenshot.
- [ ] **A Studio screenshot** of the street with scenario paths.
