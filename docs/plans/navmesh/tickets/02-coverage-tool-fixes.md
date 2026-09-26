# 02: Coverage tool fixes

**What to build:** Coverage and mutation results for the new packages are trustworthy: fixture data and test helpers can be ignored per package, `elseif` conditions get mutated, and sibling freshness has a permanent guard.

**Blocked by:** None (can start immediately)

**Status:** done

- [x] A whole-file rule form in `.coverage-ignore`, with an `Ignore` spec case plus a negative control; `Merge` drops ignored files from the denominators; mutation respects the rule
- [x] `.gitignore` re-includes `lib/*/.coverage-ignore`; `lib/component/.coverage-ignore` stays untracked
- [x] Mutants on `elseif` condition lines are run, not reported as `no_coverage`; proven on the CDT package
- [x] An adapter spec (via `M.materialize`) proves the sibling `src` in the build copy equals `lib/<sibling>/src` after an edit, with a negative control
- [x] The coverage tool's own suite is green

Spec: [../spec.md](../spec.md). Gates: the spec's "Gates for every ticket".

## Result
- **`Ignore.luau`:**
  - a `src/path.luau` rule excludes a whole file;
  - a new `Ignore.matchFile`.
- **`Merge.luau`:**
  - it skips ignored files, recording one suppressed entry with kind "file", and returns
    `ignoredFiles`;
  - a reached decision probe marks its line executed. That is the `elseif` root cause: these
    lines had no statement probe. The Lines metric is unchanged.
- **Mutation:** `Mutation.plan` drops mutants in `ignoredFiles`, and `Orchestrator` passes
  them in.
- **Tests:** the coverage self-suite is 116 -> 121; the new Merge/Mutation/Ignore cases each
  have a negative control.
- **Package ignore files:**
  - `lib/constraineddelaunay/.coverage-ignore` lists `src/Fixtures.luau` and
    `src/Tests/Helpers/Invariants.luau`;
  - `lib/navmesh/.coverage-ignore` lists `src/Fixtures.luau`;
  - `.gitignore` re-includes them.
- **Proven on the CDT:** "no coverage" mutants went 172 -> 76, and fixture lines are out of the
  metrics.
- **Remaining gap (documented in the README):** mutants on continuation lines of multi-line
  statements. The engine map only records a statement's start line; a fix needs statement
  spans from the Rust engine.
- **Adapter:** `refreshSiblings` resolves siblings next to the package (the parent of
  `spec.root`) instead of a hard-coded `lib`.
  - The new freshness spec builds a sandbox package tree in `.coverage/`.
  - The adapter specs were never run by any runner before; they now have
    `lune run tools/coverage/lune/adapters/Tests/run.luau` (6/6, including 4 older specs that
    had never run).
- **Regression:** navmesh 2/2, graphutil 181/181.
