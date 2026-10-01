# 35: Elevator beside the staircase

**What to build:** An elevator in ticket 34's building, on the same map as the staircase, so the
two compete. NPCs ride it between floors, choose between it and the stairs by cost, and react
when its availability changes while they are on the way.

**Blocked by:** 34 (building with a staircase)

**Status:** ready-for-agent

- [ ] **The elevator:** a shaft with a cab that moves between the floors.
  - Navigation sees it as labelled links ("Elevator") between the floors' landing points.
    Their cost stands for the wait plus the ride.
  - Availability follows the cab: `SetLinkEnabled`, or runtime links if ticket 30 has landed.
- [ ] **Riding:** the NPC walks to the elevator, gets the follower's link event, and waits for
      the cab. It boards, rides and exits, then continues the path. The game does the waiting
      and riding; the library only routes.
- [ ] **Priority scenarios:**
  - stairs win when the elevator's cost is high;
  - the elevator wins when the stairs are far or the NPC's costs penalise them;
  - an elevator that is out of service sends everyone to the stairs.
- [ ] **The user's question: reroute when the elevator becomes available?** An NPC is partway
      up the stairs when the elevator becomes available. Should it reroute? Investigate and
      present options to the user with measurements:
  - **What the library reports today.** Enabling a link doesn't invalidate a path that avoids
    it. `IsPathValid` and `ChangedRegion` only report blocking changes, and demo 2's pain point
    5 noted that a region doesn't say whether it opened or blocked. So the NPC never hears of
    the better route.
  - **Candidate policies:**
    - compare the remaining cost of the current path against a fresh path from the NPC's
      position, and reroute only past a threshold (hysteresis);
    - a commit point (once on the stairs, keep going);
    - re-plan at waypoints only.
  - **What would help**, as candidate library features: a region or event that reports an
    *opened* route, or a cheap "remaining cost" query on a follower.
  - **The reverse case:** the elevator goes out of service while the NPC is walking to it,
    waiting, or riding.
- [ ] **Measure:** reroute decisions and the time saved or lost over a seeded crowd of NPCs on
      mixed routes. Present the policy options with those numbers before building any library
      feature.
- [ ] **A Studio screenshot** with NPCs on both the stairs and the elevator.
