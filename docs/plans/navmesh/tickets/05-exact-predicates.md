# 05: Exact predicates

**What to build:** Callers get robust orientation and incircle tests that give the right sign on near-degenerate input.

**Blocked by:** 01 (and 02 for mutation quality; until then use the `if ... return` workaround)

**Status:** ready-for-agent

- [ ] Public `CDT.Orient2D` and `CDT.InCircle`: adaptive, exact, scalar f64
- [ ] Property tests over near-collinear and near-cocircular inputs, checked against an exact rational reference
- [ ] Mutation score reported

Spec: [../spec.md](../spec.md). Gates: the spec's "Gates for every ticket".
