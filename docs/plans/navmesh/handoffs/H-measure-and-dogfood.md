# Track H: large-world measurements and a second dogfood game (round 2, order 1)

Read [README.md](README.md) first for the house rules and the order. **This track changes no
library code.** It writes only under `tools/navmesh/bench/`, `examples/` and docs, so it runs
beside any other track. If you find a library bug, write a repro and report it; don't fix it.

**Setup:** a worktree off `feat/navmesh`, branch `navmesh-measure-dogfood`.

## H1. Ticket 31: measure 1-4 km maps
- The full spec is in `docs/plans/navmesh/tickets/31-large-world-measure.md`, ruled in
  review.md, research D6: "Measure first".
- **Maps:** seeded city, open and terrain-like maps at 1, 2 and 4 km.
- **For each, at the default and two other TileSizes:** Build, bake bytes, Deserialize, heap
  after load, `FindPath` median and p95 (with and without `MaxExpansions`), and one `Update`.
- **On both runtimes:** Lune, and one Studio run on the largest map.
- **Method:** use bench.md's audited method. Another track runs at the same time, so interleave
  runs and report medians and ranges.
- **Report:** write the results to bench.md. Then present the D6 options with the numbers: out
  of scope, region bakes, or whatever the numbers suggest, such as a smaller bake format first.
- **Watch for** the known load-time spike: the first `Update` or radius `FindPath` after
  `Deserialize` builds the wall index in O(triangles) ([known-gaps.md](known-gaps.md)). Measure
  it on the big maps.

## H2. A second dogfood game on the new APIs
- **The goal:** find the next round's pain points, as the first dogfood game did.
  `examples/navmesh-demo/REPORT.md` found 15 pain points, and tickets 22-27 fixed them.
- **Build a new small game in `examples/navmesh-demo2/`** as a first-time user. Use, at minimum:
  - the Part adapter (`lib/navmeshadapter`), so the level is authored once, as Parts;
  - the path follower (ticket 23: `NewFollower` / `Advance`);
  - the reachable queries (ticket 24);
  - `Update` and its changed regions;
  - the bake-shipping recipe;
  - the debug drawing.
- **Make it different from demo 1:** for example a larger level, many agents of mixed radii,
  doors and crates that change often, and agents chasing a moving target.
- **Report** to `examples/navmesh-demo2/REPORT.md`, ranked:
  - pain points, with minimal repros in a `repros.luau`;
  - wished-for features;
  - timings;
  - setup cost, verbosity, and how much hand-rolled code is still needed (a line count).
- **Screenshots:** Studio with PrintWindow capture (`tools/navmesh/studio/capture.ps1`), checked
  with the Read tool.
- **Mark each item new or known:** check [known-gaps.md](known-gaps.md) and the open tickets
  (25, 28-30) first.

## Gates
- Every claim has a script that reproduces it.
- The new bench and maps are committed in the repo's bench style.
- Library code is unchanged (`git diff feat/navmesh -- lib` is empty).
- Merge into `feat/navmesh` when done.
