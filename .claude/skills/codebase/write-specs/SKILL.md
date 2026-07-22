---
name: write-specs
description: Write or modify tiniest test specs (.spec.luau) in this repo. Use when adding tests, fixing failing tests, or improving coverage for a package. Covers spec structure, the expect matcher API, snapshots, Roblox class shims, and the FakeIntermediary bridge for replicator tests.
---

# Writing tiniest specs

Specs are `*.spec.luau` files inside the package's `src/` tree (convention:
`src/Tests/`). A spec returns a function receiving the tiniest object:

```luau
return function(tiniest)
	local describe = tiniest.describe
	local test = tiniest.test
	local expect = tiniest.expect

	describe("MyModule", function()
		test("does the thing", function()
			expect(result).is(5)
		end)
	end)
end
```

Reference examples: `test/tiniest/Examples/`. Existing strong suites:
`lib/tablemanager/src/Tests/`, `lib/tablereplicator/src/Tests/`.
Run with `lune run coverage.luau package=<name>` (see the test-package skill).

## Matcher API — exact names matter

Full documented list at the top of `test/tiniest/tiniest_expect.luau`. Matchers
chain (`expect(x).exists().is_a("number")`). Commonly misremembered:

- There is **no `.is_false()`** → use `.never_is_true()` (value must be boolean).
- There is **no `.throws()`** → use `.fails()`, `.fails_with(message)`
  (case-insensitive substring), `.never_fails()`.
- Negation is a `never_` prefix: `.never_is(b)`, `.never_exists()`,
  `.never_has_key(k)`, `.never_has_value(v)`, `.never_is_a(t)`.
- Output assertions: `.prints(pattern?)`, `.warns(...)`, `.errors(...)`,
  `.outputs(spec)` and their `never_` forms — these take a function.

## Debugging failing tests

Use `tiniest.context` to attach labeled state to a test; it prints only on
failure. Prefer attaching 3+ distinct pieces of info over rerunning with prints.

## Environment gotchas

- Pure-Luau packages run under **Lune**: no `game`, no Roblox globals.
  `Vector2`/`Vector3` come from `test/RobloxClassShims/` (wired via `.luaurc`).
- Adding `const` or a datamodel global to a spec/source moves the whole package
  to the slow Roblox Studio pipeline — avoid in tests unless required.
- Snapshots: `test/tiniest/tiniest_snapshot.luau`, stored in `test/__snapshots__/`.
- TableReplicator multi-client specs: use the fake transport bridge
  `lib/tablereplicator/src/Tests/Helpers/FakeIntermediary.luau` (+ `FakeManager`,
  `SpecUtils`); pattern in `TR.EndToEnd.spec.luau`. No real networking needed.
- Never write TestEz tests — `test/testez/` and `testez.toml` are legacy.
