# Track M1: map scenarios, the building (tickets 33, 34 and 35)

Read [README.md](README.md) first for the house rules. This track builds the scenario harness,
then the building with stairs and an elevator. Tracks M2 (outdoor, then the combined map) and
M3 (the street) both wait for your ticket 33.

**Setup:** a worktree off `feat/navmesh`, branch `navmesh-maps-urban`.

## Order
1. **Ticket 33, the map scenario harness. Merge it into `feat/navmesh` as soon as it passes,
   before starting 34**, because M2 and M3 are blocked on it.
   - Keep it small: a map definition, a scenario definition with optional expectations, a
     runner table, a Studio screenshot command, the flat-lot tracer map, and a
     wrong-expectation negative control.
   - Your conventions (where maps live, how scenarios are written, the run command) become
     M2's and M3's, so document them in the ticket's as-built notes.
2. **Ticket 34, the building with a staircase.**
   - Expect the Part adapter not to join stair steps: each step top is its own surface, with
     no seam to the next. If the scenarios fail for that reason, add a step-height rule to the
     adapter as an option.
   - If the rule has a real design fork (for example, how step faces join: seams, a merged
     sloped floor, or links), stop and ask the user. Give plain-English options with pros,
     cons and measured numbers.
   - Compare against a wedge ramp with the same rise.
3. **Ticket 35, the elevator, in ticket 34's building**, on the same map, so it competes with
   the stairs.
   - **The user's central question:** an NPC partway up the stairs when the elevator frees up.
     Should it reroute?
   - Measure the candidate policies over a seeded crowd: remaining cost against a fresh path
     with hysteresis, a commit point, re-planning at waypoints, and the reverse case
     (the elevator goes out of service mid-route).
   - Present them to the user with the numbers **before** building any library feature, such
     as an "opened route" signal or a remaining-cost query.

Ticket 36 (the street) is Track M3's. Its curbs need your step-height rule from 34, so merge
that rule as soon as it passes, even before 35 is done.

## Boundaries
- **The core library is off limits.** These tickets are maps, scenarios and measurements. Don't
  change `lib/navmesh`, because other tracks (G, then E and F) are changing it.
  - If a scenario exposes a core bug, write a minimal repro, add it to
    [known-gaps.md](known-gaps.md), and tell the user. Don't fix it here.
- **Adapter changes are allowed** (`lib/navmeshadapter`): the step-height rule.
  - M2 (terrain) and M3 (the area-name table) may also change the adapter. Merge `feat/navmesh` into your branch before
    each merge of yours, and keep your adapter changes in self-contained functions, so the
    tracks merge cleanly.

## Gates (each ticket)
- Every ticket's checkboxes are met, with scenarios passing.
- Each new behaviour has a negative control: a scenario or spec that fails without it.
- Adapter changes are spec'd. Their mutation scores are at or above the baseline, or above
  80% for new code.
- A Studio screenshot (PrintWindow capture), checked with the Read tool.
- Numbers (Build, triangles, floors, seams, `FindPath`) in the ticket's as-built notes.
- stylua clean. Record rulings in review.md (dated, in the user's words).
- Merge each ticket into `feat/navmesh` when done. Never push.
