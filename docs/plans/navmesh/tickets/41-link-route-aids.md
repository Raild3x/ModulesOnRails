# 41: Link toggles that tell the right paths, and a remaining-cost query

**What to build:** Two small library aids for games that switch links on and off (an elevator
going in and out of service), found by ticket 35's reroute study.

**Blocked by:** 35 (the study and its bench). It touches NavMesh, Storage and possibly Search,
so schedule it with a library track (E owns links).

**Status:** needs-triage. Ruled 2026-10-01 (review.md, Track M1): "Hysteresis + library aids".

## Why
Ticket 35's study runs `lune run tools/navmesh/bench/elevator_reroute.luau` on the
BuildingElevator map, 20 seeds x 40 NPCs.
- **`SetLinkEnabled` invalidates the wrong paths.** It bumps the stamps of the tiles at both
  of the link's ends, so `IsPathValid` turns false for every path through those tiles.
  - Out of service: 429 paths flagged, of which 308 (72%) never used the elevator.
  - Back in service: 405 flagged, of which 405 (100%) don't use it. And the NPCs who would
    benefit, on the stairs, are never told.
  - A library-only game re-plans hundreds of NPCs for nothing, and still strands the 6% already
    waiting at the doors.
- **Comparing "switch" against "stay" costs two FindPath calls** (about 2 ms each on this
  map), and their costs are only comparable in the same cost mode (known-gaps.md,
  "`PathResult.Cost` changes meaning with the filter").

## To do
- [ ] **Link toggles invalidate only the paths that use the link.** A path records the link
      ids it crosses (beside `TileStamps`, kept opaque), and `IsPathValid` checks them.
      Disabling a link invalidates exactly those paths. Enabling one invalidates none: an
      opening is not a block.
  - Specs with negative controls: a path through the link's end tile that doesn't use it stays
    valid; a path using it turns invalid.
  - Re-run the study: the `library` row's invalidations should drop to the elevator riders.
- [ ] **A remaining-cost query on a follower:** the cost of the rest of the current path from
      a position, under a filter, in the same cost mode FindPath uses. It replaces the second
      FindPath in the ruled hysteresis policy (`ElevatorSim.luau`, `reconsider`).
  - Its cost under the follower's filter, for the rest of its path, should match a fresh
    `FindPath` along the same corridor. Spec that.
- [ ] Optional, ask first: an "opened" region from `SetLinkEnabled(true)` (demo 2's pain point
      5). The study found the game already knows when it opens a link, so this may not be
      needed.
