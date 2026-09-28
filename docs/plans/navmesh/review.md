# NavMesh plan debate record
Code ref: `feat/navmesh` @ `21e62b7c137274f4023ea9bff2d0c5dfa59ff992`.

## Rulings
The user's settled decisions are the "Decisions (user's words)" table above (Q1–Q8, R1–R7,
U1–U3, N1–N4, V1–V4), plus the Phase 0 requirement: "Prototype and Test your planned testing
framework as part of phase 0 so we can ensure it will work for our goals at every step." R4 and
the const question are deliberately open, gated on benchmarks.

### Debate rulings (2026-09-25)
- **D1 (P1): accepted.** DrawList builders move into the cores, and a single DrawListRenderer
  replaces U2's two renderer names. User: "Accept P1 (Recommended)".
- **D2 (P2, the deadlock): in-repo siblings.** User: "In-repo siblings, do whatever is simplest
  and fastest for iteration, we will worry about publishing format when the whole thing is
  done". So the publish rewrite and the CI reverse-closure are deferred.
- **D3 (P3–P7): all accepted** after the reasons were given. The user selected "P3 Serialize
  version, P4 Cross-tile clearance, P5 All covering edges, P6 + P7".
- All pending review additions (P1–P7) are now ruled. Next step: Phase 0.

### Rulings after the plan debate (Phase 0 and spec phase, 2026-09-25)
- **const:** no `const` in the core packages. User: "No const in cores (Recommended)".
- **elseif:** fix the coverage tool's `elseif` mutation blind spot. User: "Fix the coverage tool
  (Recommended)".
- **R4a:** topology in i32 buffers. User: "i32 buffers (Recommended)".
- **R4b:** the CDT stores coordinates in an f64 buffer; NavMesh stores native `vector`. User:
  "CDT f64 buffer, NavMesh vector (Recommended)".
- **S1:** storage seam, with generic accessors now and profiling-driven inlining later. User:
  "can we make our accesses and operations generic to test easy swapping down the line? …
  Until then we will go off the current benchmarks".
- **Seams:** the five test seams in spec.md. User: "Yes, use these 5 (Recommended)".
- **Spec debate:** 3 rounds only. User: "next, run only 3 rounds".
- **U-a (clearance cap vs Q4):** decide after the P4 benchmark, with measured options brought
  back before the NavMesh API ticket. User: "Decide after benchmark (Recommended)".
- **U-b (R6 snapping):** queries take feet positions; nearest surface vertically, ties go
  below. User: "Feet positions (Recommended)".
- **U-c (publish guard vs D2):** a pre-merge check on a dedicated `publishable = "false"` key,
  in publish-checks or detect-changes and never in the publish loop. User: "Pre-merge check
  (Recommended)".
- **U-d (API limits):** accept both: open polylines need group 0, and NavMesh coordinates are
  limited to ±32,768 studs. User: "Accept both (Recommended)".

### Rulings during the build (2026-09-26)
- **Speed work:** prototype and A/B test every speed opportunity before choosing. User: "Start
  doing prototypes with AB testing to determine the best choices for each".
- **Landing:** land the adaptive snap-round grid and the CDT accessor copies, then re-run the
  TileSize benchmark across scenes. User: "yes".
- **Open list:** ship the 4-ary heap (bench.md, "A* open list"). User: "implement the 4 ary
  heap".
- **Default TileSize:** per floor from density, about 36 edges per tile, a power of two from 4 to
  256 studs; an explicit `TileSize` overrides it (bench.md, "TileSize re-run over scenes"). User:
  "1 - yes".
- **`Update` re-snap:** local to the dirty tiles, from each tile's static baseline (spec SR13,
  bench.md 3). User: "2- yes".

### Rulings during the build (2026-09-28)
- **Parallel mutation tooling:** merged as built. `--mutate-jobs` defaults to half the CPU
  cores, and `--mutate-files` filters the mutants. User: "Merge as built (Recommended)".
- **Committing tickets 15-19:** one mutation gate on the final state, then five commits in
  order, with the specs run at each. User: "One gate, 5 commits".
- **Editor deviations (ticket 21):** accept all three and amend the spec: the public
  `ImportSource`, the `constraineddelaunay` sibling, and an `Apply` that updates in place.
  User: "Accept all, amend spec (Recommended)".
- **Obstacle records and the bake format (dogfood bug 3):** 2026-09-28: removed obstacle
  records freed; Serialize v2 (sparse records + next id); v1 bakes rejected with a rebuild
  message. User chose v2 over the fits-v1 variant (which still grew 13 B per removal).
- **Local Update (ticket 22):** 2026-09-28: ticket 22 = Opt2i (fresh-state commit +
  incremental clearance); Opt1 in-place commit rejected on atomicity risk, kept as a drop-in for
  the commit step if the remaining O(T) copy matters; Opt2 alone rejected (still O(map)).
  Prototypes and numbers: branches `proto/local-update` and `proto/local-update-77`, and
  bench.md "Local Update".
- **Changed regions (ticket 22):** 2026-09-28: `Update` returns the changed regions, a list of
  `{ Floor, Min, Max }` boxes (`ChangedRegion`). `IsPathValid` stays as it is. User: "changed
  regions only", not an exact `IsPathValid`.
- **Part adapter home (ticket 26):** 2026-09-28: its own package, `lib/navmeshadapter`, as Q1
  and the spec already said ("adapters stay out of the cores"). Not asked again.
- **How the adapter picks floors (ticket 26):** 2026-09-28: caller-given lists,
  `FromParts(walkable, obstacles, options)`. Walkable faces on one plane form one floor, named
  after its first Part. Rejected: built-in CollectionService tags (Studio-only specs, fixed tag
  names), every upward face (demo: 5 floors and 60 triangles instead of 3 and 48; crate tops
  become snap targets), a `NavFloor` attribute (markup on every Part). User: "Caller-given lists
  (Recommended)".
- **Unknown `QueryFilter` keys (ticket 26):** 2026-09-28: error at the call (22 ns per query,
  about 0.01% of a `FindPath`). User: "Error (Recommended)".
- **`HasPendingChanges(mesh)` (ticket 26):** 2026-09-28: added (the recommendation was to skip
  it). User: "Add it".

### Rulings during the build (2026-09-27)
- **U-a (clearance reach), ruled after the P4 probe (ticket 15 notes):** no cap by default,
  with an optional cap. Any `AgentRadius` works, and each width's reach r* is stored.
  - `Update` recomputes a triangle only when it lies within its own r* of the rebuilt tiles.
  - An optional `NavMeshDesc.MaxAgentRadius` bounds the reach, for large open floors with small
    hand-set tiles.
  - User: "No cap + optional cap".

## Rounds (plan debate, rounds 1-4 above; spec debate below under "Spec debate")
### Round 1
| Lens | Category | Score |
|---|---|---|
| Reader | Simplicity / Readability / Clarity | 7.5 / 7.5 / 5 |
| Risk | Accuracy / Safety / Plan fit | 5 / 6.5 / 5 |
| Change | Change locality | 5 |

**Accepted and changed:**

*Clarity and readability*
- The full typedefs and examples were restored. The author had replaced them with "unchanged from
  the previous draft", which pointed at nothing.
- Terms defined; parameter names fixed (`triangulation`/`hintTriangle`, `mesh`/NavMeshData);
  return semantics stated (Raycast, FindDistanceToWall, linkId); Verification moved after the
  table; touched-files list added.

*Test tooling*
- Goldens moved to the cores (P1): Roblox tiniest has no snapshots, and mutation testing is
  Lune-only.
- New checks and fixes:
  - F10 (sibling dependencies, P2);
  - F3 save opt-in and key-collision check;
  - F2 control now executed-but-unasserted;
  - F8 validator made authoritative;
  - F9 native-codegen check;
  - F1 tripwire and scaffold order and template fix.

*Design*
- Coincident constraints (P5), Refine termination (P6), clearance across tiles (P4), Serialize
  version (P3).
- Scratch pool plus no mesh reference; single internal snap step; named group constants;
  generic ExportSource with a round-trip spec.
- Editor now takes `parent` and a typed description, and uses better-signal.

*Cleanups and factual corrections*
- The P7 cleanups.
- Factual fixes: Signal is a Wally dependency; the classifier is a substring match; the snapshot
  mechanism is not the coverage-golden one; Pillow can't rasterize SVG; tiniest has no line diff;
  `collectgarbage` measurement; `{vector}` instead of `{Vector3}` in bench wording.

**Rejected:**
- Change lens: "the CDT editor mode lives in navmeshdebug, so CDT-only users must depend on
  navmesh." Rejected because V2 (a user ruling) puts the editor in navmeshdebug, and no CDT-only
  consumer exists yet. It stays a known limitation. Revisit only if one appears.

**"Start looking" mismatches forwarded to Reader:**
- Part adapter: people will look in `lib/navmesh` at `NavMeshDesc`. `Polygon` is now fully
  typed. The adapter's home stays open (Q1 says "later"), and it must not live in a core,
  because of the marker tripwire (F1).
- Live CDT edits: people will look at `AddObstacle`/`Update`, but the real work is in the CDT's
  public surface and the layout. B1 now includes an incremental-insert workload.
- Sliced FindPath: people will look at `FindPath` and `AStar.luau`'s `shouldStop`. The scratch
  pool sentence now covers ownership.

**Owed in code:** none (not built yet).

### Round 2
| Lens | Category | Score |
|---|---|---|
| Reader | Simplicity / Readability / Clarity | 9 / 9 / 8 |
| Risk | Accuracy / Safety / Plan fit | 7.5 / 5.5 / 7 |
| Change | Change locality | 7 |

**Accepted and changed** (every claim checked at `21e62b7`: `.gitignore` `lib/*/*`;
`setup_package_for_testing.py` `main()` returns on the first failure; `_common.py`
`WALLY_IGNORE_LIST`; `test_package.py` `_ensure_setup` is best-effort):
- **F10 redesigned** (Risk, Change, and Reader's scope note):
  - `[custom] siblings` plus a transitive sync step inside setup, with a source-hash spec;
  - all four dependency edges covered;
  - three negative controls: clear and setup, a stale hash, and navmeshdebug's registry
    dependency.
  - P2 now names the publish-per-change alternative for the user.
- **Precedent corrected:** profiletrademanager vendored published external dependencies,
  locally, on another branch. It is not evidence for siblings.
- **Line numbers:** the `materialize` range was dropped for the symbol name.
- **`.gitignore` exception:** `!lib/*/CONTEXT.md` added to the touched files.
- **Guard spec (L2):** each core has a permanent pipeline guard spec, `expect(game).is_nil()`.
  Doc examples in the cores must not contain markers.
- **Backends (L3):** they `error` on an unknown `Kind`.
- **Merge limit (L4):** only SvgBackend can merge into a core.
- **Drawing primitives:** `DrawPrimitive.Radius` added. CDT DrawLists are emitted in world XZ,
  and the DrawListRenderer `plane` parameter is **removed**.
- **SvgBackend:** its projection and `Layers` filter are stated, and its SVG output is declared
  as checked by eye only.
- **F9:** now says why it falls back to Open Cloud.
- **Adapter home:** stated in the package section.
- **Editor:** its require line is shown.
- **Fixtures:** stated that they ship in `src/` on purpose.
- **P1:** now says it replaces U2's two renderer names.

**Rejected:** none. Change lens withdrew the CDT-editor-mode complaint (V2 ruling accepted).

**Owed in code:** none (not built yet).

### Round 3
| Lens | Category | Score |
|---|---|---|
| Reader | Simplicity / Readability / Clarity | 8.5 / 9 / 8 |
| Risk | Accuracy / Safety / Plan fit | 8.5 / 7 / 7.5 |
| Change | Change locality | 8 |

**Accepted and changed.** All checked at `21e62b7`:
- tiniest has `never_exists` and no `is_nil`;
- `test_package.py` `_DEP_SECTIONS` ignores `[custom]`;
- `publish.py:270` clears the package before publishing;
- `publish.yml` runs when a labelled PR merges;
- `parse_wally_toml` handles only string values.

Changes made:
- **Guard spec matcher:** the guard spec now uses `never_exists()`.
- **F10:**
  - `siblings` is now a comma-separated string, which the existing parser reads;
  - setup triggers are sibling-aware in both `test_package.py` and the adapter;
  - the staleness check moved to the host (the adapter's `buildSpec`) as a hard error, so it
    covers the Studio-pipeline dependents and needs no per-package spec (the Change lens's L5);
  - both CI jobs are named in the pass criterion.
- **Publish:** `publish.py` rewrites siblings into `[dependencies]` in topological order.
- **P2:** its cost is stated plainly, so the user can weigh it against the publish-stubs
  alternative.
- **Simplification (Reader):** siblings are now copied into the build folder by
  `M.materialize` on **every** test run (both pipelines; `Orchestrator` calls `materialize` on
  each run). Tests therefore can't see a stale sibling.
  - **Removed:** the host-side hash check, and negative control (b) became "an edit is seen
    without setup".
  - **Setup-time copy:** kept only for editor types and luau-lsp. It is ordered before
    `rojo sourcemap` and the shims (Reader clarity 3).
- **F10 layout:** the details moved out of the table cell into a bullet list; both CI jobs are
  named.

**Rejected:** none.

**Owed in code:** none (not built yet).

### Round 4 (final; the user asked to end after round 4)
| Lens | Category | Score |
|---|---|---|
| Reader | Simplicity / Readability / Clarity | 9 / 9 / 8.5 |
| Risk | Accuracy / Safety / Plan fit | 8 / 8 / 8 |
| Change | Change locality | 9 |

**Accepted, not re-reviewed** (one-line fixes from the final round; all verified at `21e62b7`,
including `action.yml`'s per-package loop and its `git add lib/*/wally.toml` commit to main):

*Reader*
- A `lib/navmeshdebug` stub is added.
- The adapter gets its own `siblings` reader.
- `materialize` overwrites only the siblings' `src` over the setup-produced layout, so the
  layout is written once.
- Wording on the stale `_Index` vendoring was fixed.

*Change*
- A note on refreshing editor types.
- A note that the root link module exists.
- Both cores must adopt `const` together.

*Risk*
- Topological order and the reverse-sibling closure now live in
  `publish_detect_changed_packages.py`, so CI reruns dependents.
- The publish rewrite happens on a temporary copy, so it is not committed back to main.
- `--dry-run` control (e).
- `materialize` emits the link modules and the Lune shims.
- Sibling copies are never placed under `src/`, which keeps coverage correct.

**Rejected:** none.

**Owed in code:** none (not built yet).

## Outcome
- **Stopped** after round 4 at the user's request ("end after round 4").
- **Auditor:** not run (see below).
- **Final scores:** Reader 9 / 9 / 8.5, Change 9, Risk 8 / 8 / 8.
- **Risk:** all three of its categories finished under the bar. Every complaint behind those
  scores has an accepted fix, but none was re-scored.
- **What the Risk lens found, in summary:** P2 (in-repo siblings) keeps pulling more shared
  tooling into scope: setup, test_package, the adapter, publish and the detect script. That is
  the deadlock handed to the user.
- **Auditor:** the fresh auditor was skipped because the user ended the debate. Before the spec
  is written, the auditor should be run on the spec itself.

---

# Spec debate (spec.md, capped at 3 rounds by the user)
Code ref: the worktree `.claude/worktrees/navmesh-phase0` (branch `spike/navmesh-phase0`, base
`21e62b7` plus uncommitted Phase 0 work). Reviewers read it in place.

## Spec round 1
| Lens | Category | Score |
|---|---|---|
| Reader | Simplicity / Readability / Clarity | 8 / 8 / 6.5 |
| Risk | Accuracy / Safety / Plan fit | 5 / 6.5 / 7 |
| Change | Change locality | 6 |

**Verified and fixed in code:**
- **Risk's mutation-vs-goldens finding was real.** `--mutate` printed "baseline suite is not
  green -- skipping mutation". Fixed the `mutant_run.luau` labels; now 38/40 killed with the
  goldens present.
- Recorded in the verification.md F2 addendum.

**Accepted into spec.md as review additions SR1-SR12 (pending the user):**
- **Winding and geometry:**
  - open-constraint winding (group 0, balanced groups);
  - snap rounding plus the post-quantization degeneracy check;
  - canonical tile and seam boundaries;
  - clearance counting wall features only.
- **Validity and heights:**
  - link toggles bump tile stamps;
  - tile-independent heights, plus the definition of "overlaps itself";
  - an admissible heuristic;
  - Refine with hull edges as segments.
- **Serialize:** independent of the layout, with a frozen bake.
- **Guards and reuse:**
  - an enforced publish guard (`unreleased` plus a `publish.py` refusal; the convention is
    verified at `scripts/generate_readme.py:169`);
  - GraphUtil.AStar functionally disqualified;
  - `vector` conversion at the API boundary.

**Other changes accepted (no ruling needed):**
- **Storage and naming:**
  - the tile slot model, and full accessor lists for both Storage modules;
  - `VertexOfInput`, because duplicate merge breaks "input vertices first";
  - `Triangulation` made opaque, with a `GroupCount()` function;
  - public names matched to Storage (`GetWinding`);
  - the inlining rules (exported stride constants, `-- inlined:` tags, never across packages);
  - the contract suite asserts coverage of every exported function.
- **Structure and docs:**
  - module file names and the query flow;
  - "seam" disambiguated (test layers, Storage boundary);
  - the decisions row replaced by pointers;
  - typedef comments restored;
  - debug typedefs and an example added, with Janitor for the editor;
  - `EditorState` as a pure state machine, and the Play-mode mouse check made manual;
  - the tooling glossary.
- **Tooling tickets:**
  - scene modules for golden PNG review;
  - the bench harness moved into the repo;
  - the `EXCLUDE` extension (73 spurious fixture-literal mutants verified);
  - the `elseif` workaround until the fix lands.
- **Ticket 1 cleanup:**
  - delete the probe specs;
  - make `DrawList` a single type owner;
  - `Fixtures.All` built automatically, plus `Fixtures.ToInput`;
  - expose `PlainData`, and add `--!native` to `NavMesh.luau`.
- **Tests and wording:**
  - the invariant checker rewritten (local Delaunay via exact non-strict incircle; constraints
    as covering-edge chains);
  - a local PRNG, since Lune has no `Random`;
  - the Storage-contract exception noted;
  - the stale `extents` note removed, and the `Title` option added.

**Put to the user (not decided by the author):**
- **U-a:** a clearance cap would reshape Q4.
- **U-b:** the snapping reading (R6).

**Rejected:** none.

**Change-lens "start looking" mismatches forwarded to Reader:**
- **Swap and inlining:** people start at `Storage.luau`. After inlining, the tags and constants
  cover it.
- **Sliced FindPath:** people start at `FindPath`. `Search.luau` is now named as the owner of
  search and the scratch pool.
- **Part adapter:** people start at `NavMeshDesc`. The package section redirects, and the
  `unreleased` flag is now a convention.

**Owed in code:** the Phase 0 tooling fix is done; everything else is listed as tickets in
spec.md.

## Spec round 2
| Lens | Category | Score |
|---|---|---|
| Reader | Simplicity / Readability / Clarity | 8.5 / 8.5 / 8 |
| Risk | Accuracy / Safety / Plan fit | 8 / 8 / 8.5 |
| Change | Change locality | 8 |

**Accepted and changed** (the full diff is in the scratchpad at `spec.r1-r2.diff`):
- **SR1:** balance check after duplicate merge; per-tile area group numbering (at most 29) with
  a Build error beyond; tile-clipped closed rings.
- **SR2:**
  - Hobby snap rounding (hot pixels, iterated) using exported exact CDT predicates
    (`CDT.Orient2D`/`CDT.InCircle`);
  - guards: "CDT added no vertex", and XZ within ±32,768 (with the rationale);
  - a new snap-rounding no-crossing invariant spec over random polygon soups.
- **SR4:** width defined with a free pivot vertex, plus the open-floor-across-tile-corner
  fixture.
- **SR5:** conservative both ways (documented).
- **SR6:** surface diagonals as group-0 constraints (creases kept); the self-intersection check
  runs before snap rounding.
- **SR7:** one 3D metric; link ratio uses Cost × area multiplier; zero-cost link degrades to
  Dijkstra (documented).
- **SR9:** the frozen bake gets its own frozen snapshot, stored as a base64 literal in a spec,
  and is expected to error after a version bump.
- **SR10:** `publish.py` refuses `unreleased` **or** siblings (covers the CDT);
  `generate_readme.py` treats siblings as unreleased (derived, so the flag can't drift).
- **New additions:**
  - SR13: atomic `Update` with eager `AddObstacle` validation, plus a spec;
  - SR14: tile vertex ranges freed with the tile; id reuse noted for future resumable
    searches.
- **Storage:**
  - NavMesh writers renamed (`Insert*`/`Delete*`/`SetLinkFlag`);
  - full setter, tile, floor, link and source accessors;
  - public writes live in `Tiles.luau`;
  - the only re-export exception is `Locate`;
  - covering-edge reads are the non-allocating Count/Get pair;
  - in-code pointers (Storage header grep note, `NavMeshDesc` adapter note).
- **Docs and tooling:**
  - NavMesh fixtures named, with the `{Name, Desc}` shape;
  - the Signal type fixed to better-signal's pack form;
  - requires added to the debug example;
  - U-a says where `MaxAgentRadius` would go;
  - stories and comments tagged pending U-a/U-b;
  - a render setup note;
  - the whole-file `.coverage-ignore` rule, scoped per package instead of the global
    `EXCLUDE`, which would shift other packages' coverage.

**Rejected:** none.

**Owed in code:** none new; all listed as tickets.

## Spec round 3 (final)
| Lens | Category | Score |
|---|---|---|
| Reader | Simplicity / Readability / Clarity | 8.5 / 9 / 8.5 |
| Risk | Accuracy / Safety / Plan fit | 8.5 / **7** / 9 |
| Change | Change locality | 9 |

**Accepted, not re-reviewed** (one-line fixes from the final round, all verified):
- **SR10 (Risk and Change):** a dedicated `publishable = "false"` key. `unreleased` keeps its
  README meaning.
  - Verified: `lib/adjustabletimer/wally.toml` has `unreleased = true` yet is published
    (`adjustabletimermanager` depends on `raild3x/adjustabletimer@^1.0.0`).
  - The round-2 wording would have blocked 5 live packages. This fix is what Risk's Safety 7
    was about.
- **Requires (Change and Reader):** examples use `require(Packages.X).Member`, and the public
  modules expose `Fixtures`/`NavMeshEditor`.
  - Verified: `lib/navmeshdebug/NavMesh.lua` is a one-line link module with no children.
- **SR13:** a failed `Update` rolls back its obstacle records; dirty tiles come from the snapped
  bbox expanded by one pixel. Both have specs.
- **SR14:** boundary vertices interned by grid coordinate and freed on commit when
  unreferenced; add+remove equals a fresh Build (spec).
- **SR2:** named as iterated snap rounding (Halperin & Packer), with exact hot-pixel crossing
  tests via `Orient2D` on the pixel corners.
- **SR1:** the `G <= 32` cap dropped, since the buffer is already T x (G+1). This removes the
  per-tile renumbering and the 29-area error (Reader simplification).
- **SR4:** Demyen citation.
- **Public predicates:** `CDT.Orient2D`/`CDT.InCircle` declared stable public API.
- **Coverage ignore:**
  - `.gitignore` `!lib/*/.coverage-ignore` (verified: `lib/*/*` ignores it);
  - `Ignore.spec` case plus a negative control, and `Merge` must drop ignored files from the
    denominators;
  - rules one per line;
  - a shared base64 test helper.

**Not applied:** Reader R3-a (move the normative SR text out of the decisions table and into
its sections). It's presentation only and larger than a one-line fix; left for the tickets
pass.

**Owed in code:** none new; all listed as tickets.

## Spec auditor (fresh; saw only the final spec and the rulings)
- **First pass: Safety 7.5 / Plan fit 8.** Collisions found and fixed:
  - **SR10:** a `publish.py` refusal inside CI's alphabetical, irreversible publish loop would
    strand earlier publishes without their version-bump commit; it was also D2 tooling creep.
    It became **U-c**, needing a user ruling, where option (1) is a pre-merge check that never
    runs in the loop, and option (2) is no tooling.
  - **SR1:** "no cap" vs a type comment saying "<= 32"; fixed.
  - **Renames:** unlisted until SR15 (`GetTriVertex` → `GetTriangle`, `Winding` → `GetWinding`).
  - **API narrowings:** open-polyline error and ±32,768 surfaced as **U-d**.
  - **F10(b):** freshness guarantee kept, as a permanent adapter spec.
  - **Coverage-ignore:** `lib/component/.coverage-ignore` stays untracked.
- **Re-run (once): Safety 9 / Plan fit 9.** No collisions remain.
  - Last one-line fix applied: the freshness spec goes in `adapters/Tests`, via
    `M.materialize`.
  - A ticket-ordering note was added for U-a to U-d.

## Outcome (spec debate)
- **Rounds:** 3, the user's cap.
- **Final panel scores:** Reader 8.5 / 9 / 8.5, Risk 8.5 / 7 / 9, Change 9.
  - Risk Safety 7 was driven by SR10's `unreleased` overload. That was fixed as "accepted, not
    re-reviewed" and then superseded by U-c.
- **Auditor:** 9 / 9 after one re-run. There is no split of 1.5 or more against the panel on
  Plan fit (9 vs 9). On Safety the gap (9 vs 7) is 2, but it concerns an item the auditor saw
  *fixed*: the panel's 7 was scored before the final fixes. So it is reported to the user
  rather than treated as a live deadlock.
- **Deadlocks for the user:** none of substance. There are **four open rulings, U-a to U-d**,
  plus 14 review additions (SR1-SR15; SR10 → U-c) and defaults A-C awaiting approval with the
  spec.
- **Not applied:** Reader R3-a (presentation).
