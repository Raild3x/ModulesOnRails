# Track E: links (round 2, order 2: after Track G merges)

Read [README.md](README.md) first for the house rules and the order. Start only once Track G
has merged into `feat/navmesh`, because both tracks touch Search, Types and NavMesh.

**Setup:** a worktree off `feat/navmesh`, branch `navmesh-links`.

## E1. Ticket 30: runtime and generated links
- The full spec is in `docs/plans/navmesh/tickets/30-generated-links.md`, ruled in review.md,
  research D3: "Generator + runtime AddLink".
- **Part 1, runtime links:** `AddLink` / `RemoveLink`.
  - They stay pending until `Update`, the same model as obstacles.
  - Ids are never reused, and records are freed (the obstacle pattern).
  - Stamps and `ChangedRegion` cover link ends.
- **Format:** v3 already reserves sparse link ids and a next id (review.md, Track B B1).
  - Storage link ids are still dense, and the v3 reader requires ids 1..n.
  - Make Storage sparse first, then relax that reader check. The format itself needs no change.
- **Measure first:** `Search.HeuristicScale` loops over every link on every `FindPath`.
  Benchmark 0, 100 and 1,000 links, then pick a caching fix with the numbers.
- **Part 2, the generator:** `GenerateLinks(mesh, options)`, a pure function returning
  `LinkDesc`s.
  - It makes drops and jumps.
  - It rejects walled edges (Roblox's current bug) and links that duplicate a walkable route.
  - It deduplicates runs, and the editor gets a "generate links" action.

## E2. Ticket 25's link items
- the link id on a link's waypoint;
- an optional `LinkDesc.Name`;
- `SetLinkEnabled` by name.

## E3. The link gaps Track B left ([known-gaps.md](known-gaps.md))
- **Ticket 27's end check:** a link that lands in the goal triangle, or starts in the start
  triangle, doesn't check that the agent can get between the link point and the end. Leaving a
  triangle entered by a link or a seam reads only the exit edge's portal width.
- Extend ticket 27's barrier check (`Clearance.CutOff` / `Separated`) to link and seam entry
  points. Ticket 30 makes links common, so this matters now.
- Keep the oracle discipline from ticket 27: an independent check confirms every flip, with 0
  refuted.

## Gates
- Specs first, each with a negative control; the generator specs are listed in ticket 30.
- `FindPath` cost with 0, 100 and 1,000 links goes in bench.md.
- Mutation at or above the baseline on Search, Tiles, Storage, Serialize and NavMesh.
- Rebake the demos if the format bytes change.
- Merge into `feat/navmesh`. Track F then starts.
