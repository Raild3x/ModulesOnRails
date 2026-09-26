# 02: Coverage tool fixes

**What to build:** Coverage and mutation results for the new packages are trustworthy: fixture data and test helpers can be ignored per package, `elseif` conditions get mutated, and sibling freshness has a permanent guard.

**Blocked by:** None (can start immediately)

**Status:** ready-for-agent

- [ ] A whole-file rule form in `.coverage-ignore`, with an `Ignore` spec case plus a negative control; `Merge` drops ignored files from the denominators; mutation respects the rule
- [ ] `.gitignore` re-includes `lib/*/.coverage-ignore`; `lib/component/.coverage-ignore` stays untracked
- [ ] Mutants on `elseif` condition lines are run, not reported as `no_coverage`; proven on the CDT package
- [ ] An adapter spec (via `M.materialize`) proves the sibling `src` in the build copy equals `lib/<sibling>/src` after an edit, with a negative control
- [ ] The coverage tool's own suite is green

Spec: [../spec.md](../spec.md). Gates: the spec's "Gates for every ticket".
