# 05: Exact predicates

**What to build:** Callers get robust orientation and incircle tests that give the right sign on near-degenerate input.

**Blocked by:** 01 (and 02 for mutation quality; until then use the `if ... return` workaround)

**Status:** done

- [x] Public `CDT.Orient2D` and `CDT.InCircle`: adaptive, exact, scalar f64
- [x] Property tests over near-collinear and near-cocircular inputs, checked against an exact rational reference
- [x] Mutation score reported

Spec: [../spec.md](../spec.md). Gates: the spec's "Gates for every ticket".

## Result
- **Implementation:** `Predicates.luau`, a Shewchuk first-stage filter plus an exact expansion
  fallback (twoSum/twoProduct/Veltkamp split, grow/scale/multiply with zero elimination).
  Public as `CDT.Orient2D`/`CDT.InCircle`.
- **Oracles**, each with a negative control where plain f64 fails:
  - the Kettner near-collinear grid (4096 cases, sign(j-i));
  - translation invariance at 2^40 (small-integer truth), including exactly collinear and
    cocircular cases;
  - large 3-4-5 circles (radius 5K, K ~ 2^21) with known on/in/out signs;
  - sub-ulp-next-to-1 inexact differences;
  - tiny representable nudges forcing multi-term expansions. The expected sign follows the
    nudge that survives rounding; 14 cases round to exactly collinear and must return 0.
- **Mutation:** 66/80 killed (85%). The 12 survivors are the filter constants (loosening a
  bound only changes speed) and low-order expansion arithmetic that sign-only outputs can't
  observe. They are accepted through the public-API test layer.
