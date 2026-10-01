# Track M3: map scenarios, the street (ticket 36)

Read [README.md](README.md) first for the house rules. This track builds the street with
sidewalks and crosswalks: the test bed for weighted areas. It runs beside M1 (the building) and
M2 (outdoors).

**Setup:** a worktree off `feat/navmesh`, branch `navmesh-maps-street`.

## Before you start: wait for ticket 33
- Start only once M1's map scenario harness (ticket 33) has merged into `feat/navmesh`, and use
  its conventions: where maps live, how scenarios are written, the run command, and the
  screenshot command.
- Don't build a harness of your own.

## Order
1. **Areas first.** Road, sidewalk and crosswalk each get an area id through the adapter.
   - The adapter's area-name table is ticket 26's open item (research D5): a plain
     `{ [string]: number }` returned beside the description, so scenarios write `areas.Road`.
   - Build it here if it stays small, as a self-contained adapter change with specs and a
     negative control. If it grows, use numeric ids and note the gap.
2. **The street with flush crosswalk ramps,** before any curbs.
   - Build the road, sidewalks, crosswalks and a few parked cars.
   - Use a stand-in entrance until M1's building (ticket 34) lands, then move the map in front
     of the real building.
   - **Scenarios:**
     - a pedestrian on the far side reaches the entrance via a crosswalk;
     - with a high road cost, no path crosses the road outside a crosswalk;
     - with a road cost of 1, paths cut straight across (the negative control for the
       weighting);
     - a large-radius NPC fits the crosswalk ramps.
3. **Stepped curbs, once M1 has merged the step-height rule from ticket 34.** Raise the
   sidewalks with real curb steps and re-run the scenarios. Report any change in floor and seam
   counts and in routes.
4. **Measure:**
   - the share of paths that jaywalk, at several road costs;
   - the detour overhead against a straight crossing;
   - bends at equal-cost area edges (tickets 25 and 32). Screenshot one if it shows.

## Boundaries
- **The core library is off limits.** Don't change `lib/navmesh`, because other tracks are
  changing it.
  - If a scenario exposes a core bug, write a minimal repro, add it to
    [known-gaps.md](known-gaps.md), and tell the user. Don't fix it here.
- **Adapter changes** (`lib/navmeshadapter`) are limited to the area-name table.
  - M1 adds a step-height rule there, and M2 may add terrain changes.
  - Merge `feat/navmesh` into your branch before each merge, and keep your change in
    self-contained functions.
- **Rulings:** if the area-name table needs a design call (for example, mapping by `Material`
  or by attribute), ask the user. Give plain-English options with pros and cons.

## Gates
- Ticket 36's checkboxes are met, with scenarios passing.
- Each new behaviour has a negative control.
- The adapter change is spec'd, with mutation above 80% on new code.
- A Studio screenshot (PrintWindow capture), checked with the Read tool.
- Numbers in the ticket's as-built notes.
- stylua clean. Record rulings in review.md (dated, in the user's words).
- Merge into `feat/navmesh` when done. Never push. M2's combined map (ticket 38) waits on this
  merge.
