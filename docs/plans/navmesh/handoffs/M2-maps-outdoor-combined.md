# Track M2: map scenarios, outdoor and combined (tickets 37 and 38)

Read [README.md](README.md) first for the house rules. This track builds the outdoor terrain map
and then the combined city map. Track M1 builds the harness (ticket 33) and the building
(34, 35), and Track M3 builds the street (36).

**Setup:** a worktree off `feat/navmesh`, branch `navmesh-maps-outdoor`.

## Before you start: wait for ticket 33
- Check `git log feat/navmesh` and ticket 33's status. Start ticket 37 only once the harness has
  merged, and use its conventions: where maps live, how scenarios are written, the run command,
  and the screenshot command.
- If it hasn't merged yet, don't build a harness of your own. Two harnesses would split the
  maps. You may sketch the terrain layout on paper (sizes, slopes, tree counts, the river
  path) in the ticket while you wait.

## Order
1. **Ticket 37, uneven terrain: forest and river**, built from Parts. The user ruled Parts
   first; voxel Terrain is ticket 39, later.
   - **Ground:** many slightly tilted slabs and wedges, about 1-10 degrees, with small steps.
   - **Forest:** trunks, rocks and a narrow trail.
   - **River:** a channel that can't be walked, sloped banks, a bridge, and a weighted shallow
     ford.
   - **The main deliverable is the measurement:** how slight height variation changes floor,
     seam and triangle counts, Build time, bake size, `FindPath` time and path smoothness.
     - Expect every tilted piece to become its own floor joined by seams.
     - Report which adapter behaviour would help (merging near-coplanar faces, or non-planar
       walkable rings, which the core supports through creases). Ask the user before building
       it, with plain-English options, pros, cons and numbers.
   - **Record the numbers so Track F's simplification passes can be re-measured** against
     them later.
2. **Ticket 38, the combined city map,** once M1's ticket 35 and M3's ticket 36 have merged.
   - Join the building, elevator, street and terrain into one map, and run daily routes for a
     seeded crowd using the follower.
   - Add live events (the elevator out of service, a door closing, a crate dropped on a
     sidewalk), using M1's reroute policy from ticket 35.
   - Put the bench numbers in bench.md. It becomes the regression map, run in one command.
   - If 35 and 36 aren't merged when you finish 37, report and stop.

## Boundaries
- **The core library is off limits.** Don't change `lib/navmesh`, because other tracks are
  changing it.
  - If a scenario exposes a core bug, write a minimal repro, add it to
    [known-gaps.md](known-gaps.md), and tell the user. Don't fix it here.
- **Adapter changes** (`lib/navmeshadapter`) only after the user rules on them. M1 is also
  adding a step-height rule there, and M3 an area-name table. Merge `feat/navmesh` into your branch before each merge,
  and keep your changes in self-contained functions.

## Gates (each ticket)
- Every ticket's checkboxes are met, with scenarios passing.
- Each new behaviour has a negative control.
- A Studio screenshot (PrintWindow capture), checked with the Read tool.
- Numbers in the ticket's as-built notes and in bench.md (bench.md's interleaved, audited
  method; the machine is shared with other tracks).
- stylua clean. Record rulings in review.md (dated, in the user's words).
- Merge into `feat/navmesh` when done. Never push.
