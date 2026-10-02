# Track F: geometry input (round 2, order 3: after Track E merges)

Read [README.md](README.md) first for the house rules and the order. Start only once Track E
has merged, because both tracks touch Tiles and Serialize.

**Setup:** a worktree off `feat/navmesh`, branch `navmesh-geometry`.

**Status (2026-10-02): built.** R1, R2, the F2 fixes and the two Track H costs F owned are on
`navmesh-geometry`. Rulings: default tolerance 1/4 stud; v3 lazy links plus a default
`MaxAgentRadius` of 8 (review.md, "Rulings during Track F"). Numbers: bench.md
"Simplification" and "Huge rings".

## F1. The simplification passes
- **Read first:** the plan is `docs/plans/navmesh/simplification-plan.md`. It is measured, and
  it has guarantees G1-G8.
- **The prototypes** are on branch `proto/simplify`, in worktree `simplify-proto`:
  - the `quantizeRing` P1 pass and the per-tile dissolve;
  - untracked probe scripts at that worktree's root;
  - scenes and results (`rocks`, `pieces`) in its gitignored `.bench/simplify/`.
- **Build both passes:**
  - **R1, one-sided ring simplification:** walkable rings only shrink and obstacles only grow,
    checked exactly with `Orient2D` on grid integers. It also collapses edges by extension, for
    convex rings such as cylinders.
  - **R2, exact dissolve of same-class constraint edges:** the same area *and* height plane on
    both sides. Two walkable rings at different heights must never merge.
- **Rulings (2026-09-28):**
  - one mesh-wide `NavMeshDesc.SimplifyTolerance`, which users can override (0 turns it off);
  - crack welding stays in the adapter.
  - The user suggested **1/10 stud as the default.** Measure 1/10 against 1/16 and 1/4 on
    `rocks`, `pieces`, the bench maps and an adapter-built level. Confirm the default with the
    user, showing those numbers.
- **Format:** v3 reserves a field for the tolerance (review.md, Track B B1). Store it, so that
  `AddObstacle` after `Deserialize` simplifies the same way.
- **`Update`:** it now re-snaps the authored rings (Track B, `Build.Internal.TileInputs`). The
  ring pass must run identically on both paths, so "Update equals a fresh Build" still holds.
- **The adapter:** now that the Part adapter exists, measure its real output; that's the
  content these passes target.
- **Added by the user, 2026-10-01** (from the demo 2 pillars; not in the plan):
  - **Cylinders are inscribed.** `NavMeshAdapter` puts a cylinder's vertices on the circle,
    so the obstacle is smaller than the Part: by 0.02 studs at 16 sides for a 2-stud pillar,
    and by 0.29 studs if it had 4 sides. R1 can only grow the ring it is handed, so this is
    upstream of its guarantee. Circumscribe them: vertices at r / cos(pi / n).
  - **Pick the side count from the size.** With tolerance eps, a circumscribed cylinder needs
    `ceil(pi / acos(r / (r + eps)))` sides. At eps 1/10 that is 8 for a 2-stud pillar and 4
    for a half-stud prop. A fixed eps in studs already simplifies small things most, which is
    what the user asked for. Keep eps absolute: a tolerance relative to size would move big
    rings by whole studs and break the clearance bound.
  - **Measure `Update`, not only Build and `FindPath`.** On demo 2 (pillar at (176, 96), a
    crate 10 studs east, default TileSize), the crate's `Update` takes 5.0 ms at 16 sides,
    3.1 at 8 and 2.5 at 4. The triangles touching the pillar drop from 21 to 13 and 9. The
    probe was a scratch script; rebuild it as a bench when doing this.

## F2. Update on huge rings ([known-gaps.md](known-gaps.md))
- A crate near a 2,048-point walkable outline takes 1.6 s to add at TileSize 8, and 5.0 s at
  32. At 512 points, about 270 of a 275 ms remove is spent in `Clearance.Refresh`.
- **Measure Refresh first:** its reach rule, and the wall-index churn on long rings.
- Ring re-snapping is the smaller cost: about 19 ms at 8,192 points, marked `ponytail:` in
  `Tiles.reSnap`. Its upgrade path is a per-ring edge index.
- **Measure F2 before and after F1:** simplified rings may shrink the problem by themselves.

## Gates
- Write the plan's G1-G8 as specs.
- Replace the two specs the plan says the ring pass legitimately changes with one-sided
  versions.
- "Update equals a fresh Build" stays green.
- Mutation at or above the baseline on Build, Quantize, Tiles, Clearance and Serialize.
- Put the bench numbers in bench.md.
- Merge into `feat/navmesh`. Wave 2 (ticket 29) then starts.
