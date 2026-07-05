# ModulesOnRails Copilot Instructions

## Goal
This repository contains multiple Roblox Wally modules. Favor consistency inside the package you are editing over consistency with the rest of the repository. We use Luau, not Lua. Do not look outside your current package and into another package unless given permission.

## Priority Order
1. Follow the local style of the current package first.
2. Follow these repository-wide standards second.
3. Keep existing behavior unless the change explicitly requires behavior changes.

## Repository Layout
- `/lib`: Source for ~26 Wally packages, one directory each. Flagships: `tablemanager` (pure-Luau data observation library, entry `src/TableManager.luau`) and `tablereplicator` (server→client replication of TableManager, datamodel package with `src/init.luau` exposing `.Server`/`.Client`).
- `/test`: Test harness — vendored `tiniest` framework (`test/tiniest/`), `RobloxClassShims/` (Vector2/Vector3 stubs for Lune runs), `Stories/` (Studio story runners), `__snapshots__/`.
- `/tools/coverage`: The test runner and coverage system (Rust `full_moon` engine + Lune orchestrator). Read `tools/coverage/README.md` before touching it.
- `/scripts`: Python dev/setup/publish scripts (`_common.py` has the shared helpers).
- `/types`: Hand-written ambient type defs (e.g. `tiniest_lib.d.luau` for spec globals declared in `.luaurc`).
- `coverage.luau` (repo root): the test/coverage CLI entry point.

## Commands Quick Reference
| Task | Command |
| --- | --- |
| First-time setup (after clone or `npm run clear`) | `npm run setup` |
| Run tests + coverage for one package | `lune run coverage.luau package=<name>` |
| Run tests for all packages / last-tested | `lune run coverage.luau package=all` / `package=last` |
| Lint / format | `selene .` / `stylua .` |
| Serve / build docs | `npm run docs` / `npm run docs:build` |
| Scaffold a new package | `npm run newpackage` |
| Publish a package | `npm run publish` |
| Regenerate root README | `npm run readme` |

Notes:
- `tests.luau` no longer exists; `coverage.luau` is the test runner. Useful flags: `--per-test --per-file --json --mutate --recommend --suggest-const --rebuild-engine --timeout=<sec>`.
- `npm run setup` runs `wally install`, `rojo sourcemap`, and `wally-package-types` per package. On a fresh checkout, requires and types look broken until you run it — that is expected, not a bug.
- `npm run docs` / `docs:build` run `npm run clear` first, which strips installed wally deps from every package — re-run `npm run setup` afterward to restore types.

## Generated vs Committed
Generated (gitignored, never hand-edit): `sourcemap.json`, `lib/*/Packages/`, `lib/*/_Index/`, `wally.lock`, `build/`, `.coverage/`. Only `src/`, `wally.toml`, `default.project.json`, and `README.md` are tracked inside a package.

The root `README.md` is auto-generated from every package's `wally.toml` — never hand-edit it; run `npm run readme` instead.

## Package Layout
- `/src`: Package source.
- `/wally.toml`: Package configuration.

If a package is pure Luau and has multiple modules, do not use `init.luau` as the entry point. This keeps the package friendly for `lune` testing.

Publishing will generate an `init.luau` re-export automatically. Non-pure-Luau packages may use `init.luau` directly.

## Testing Rules
- `tiniest` is the testing framework we use for running tests. If needed, analyze the examples under `/test/tiniest` for reference.
- Utilize `tiniest`'s `describe`, `test`, `expect`, and `context` functions for structuring tests and assertions. `Context` is useful for debugging test cases by providing custom additional info. Attach context to failing tests to surface that info in the test output.
- tiniest has no `.is_false()` or `.throws()` matchers — the real names are `.never_is_true()` for false and `.fails()` / `.fails_with(message)` for errors. The full matcher list is documented at the top of `test/tiniest/tiniest_expect.luau`.
- Create tests in `.spec.luau` files inside the package's `src/` tree (commonly `src/Tests/`). The runner discovers a package as testable by the presence of `*.spec.luau` under `src/`.
- Use `lune run coverage.luau package=<package_name>` to run tests and generate coverage reports for a specific package.
- Pipeline selection is automatic: pure-Luau packages run in Lune (fast); packages that touch the datamodel **or use `const`** (Lune 0.10.4 cannot parse `const`) run in Roblox Studio via `run-in-roblox` (slow — expect a Studio launch).
- TestEz artifacts (`test/testez/`, `testez.toml`, `testez.yml`, `TestEz Companion.rbxl`, `scripts/Archive/runTestEZ.py`) are legacy. Never add TestEz tests.

## Debugging Rules
- Never assume root cause without validating with test output.
- Add rich diagnostics when debugging: use prints, warnings, and errors.
- Include at least 3 distinct pieces of information in debug output.
- Prefer extra context over minimal logs so follow-up decisions can be made from one run.

## Luau Style Rules
- Use PascalCase for class names, table fields, and method names.
- Use camelCase for variable names.
- Use SCREAMING_SNAKE_CASE for constants.
- Prefix private fields and methods of class objects with `_`.
- Add explicit types for non-inferred parameters and function signatures.
- For Luau classes, define both a public type and an internal type.
- Internal type should extend public type with private fields and methods.
- Declare class methods with dot syntax and explicit `self: InternalType`.
- Call those methods with colon syntax.
- Keep existing comments and debug logic unless removal is explicitly requested or the content is now outdated.
- Methods/functions that yield or could potentially yield should be either suffixed with `Async` or return as a Promise to prevent unexpected behavior.
- Avoid magic numbers. That is, numbers or values with no obvious underlying meaning. You can attribute meaning to a number by assigning it to a constant with a descriptive name, or by writing a comment explaining what the number's purpose is.
- Packages should always have relative paths for their requires. Never require another module with an absolute path. Prefer string requires.
- Avoid forward declaration whenever possible.

## Documentation Style
- Public single-line docs: `---`
- Public multi-line docs: `--[=[]=]`
- Private single-line comments: `--`
- Private multi-line comments: `--[[]]`

Documentation is in moonwave format. Guide pages are doc-only `.luau` files under a package's `src/Docs/` and must be registered in `moonwave.toml`'s `classOrder`.

## Constant Policy
Use `const` whenever a variable binding is never reassigned.

Important notes:
- `const` protects the variable binding, not table contents.
- Base-scope constants should use SCREAMING_SNAKE_CASE unless they are mutable-content tables.
- If a variable is declared and immediately assigned later, treat it as non-const for policy purposes.
- Exceptions to the constant naming policy may be made when justified by readability, practicality, or consistency with existing code. Ex: Roblox services and required modules should be consts at the base scope, but they should be PascalCase even though they are never reassigned.
- Functions should almost always be const. `const function` is preferred over `local function` for functions that are never reassigned. This is because it makes it clear that the function is not intended to be reassigned, and it can help prevent accidental reassignment.
- Testing caveat: introducing the first `const` into a pure-Luau package moves its test runs from the fast Lune pipeline to the slow Roblox Studio pipeline (Lune 0.10.4 cannot parse `const`). This is acceptable, but be aware of the tradeoff.

Declaration matrix:

| Data Type | Scope | Usage Pattern | Declaration Policy |
| --- | --- | --- | --- |
| non-table | Base | Never reassigned | const with SCREAMING_SNAKE_CASE |
| non-table | Base | Assigned immediately | local with SCREAMING_SNAKE_CASE |
| non-table | Base | Assigned programmatically | local with PascalCase |
| table | Base | Never reassigned, contents never reassigned | const with SCREAMING_SNAKE_CASE |
| table | Base | Never reassigned, contents may be reassigned | const with PascalCase |
| table | Base | Assigned programmatically | local with PascalCase |
| any | Inner | Never reassigned | const with camelCase |
| any | Inner | Assigned immediately | local with camelCase |
| any | Inner | Assigned programmatically | local with camelCase |

## Planning
- Plans should be broken up into phases when there are logically distinct high level jobs that need to be performed. These phases should be broken up into ordered tasks that can be executed sequentially to achieve the phase goal. Phases should aim to have the file in a stable state at the end of each phase, minimizing incomplete changes and ensuring that the file can be used or reviewed without dependency on subsequent phases.
- Avoid breaking up jobs that are logically connected/dependent into separate phases, as this can lead to overcomplicating and performing much more work than actually needed.
- Phases should note touched files and the expected impact on those files. This helps with code review and ensures that changes are intentional and well-understood. Note any potential edge cases that may arise. Provide type defs for any new planned api and examples of usage for public facing ones.
- When making a plan document, leave a space after tasks for yourself to update it with progress, changes, and any new insights as you work through the phases. Keep updates concise. As you complete the tasks, update this section.

## Deeper Documentation
Consult these before working in the relevant area instead of re-deriving from source:
- `tools/coverage/README.md` — the coverage/test-runner system (architecture, flags, engine golden tests).
- `lib/tablemanager/src/Docs/CONTRACT.md` — TableManager's behavioral contract; `src/Docs/*.luau` are the moonwave guides (wildcards, batching, flushing, listeners, proxies, opaque values).
- `lib/tablereplicator/src/Docs/ARCHITECTURE.md` — TableReplicator internals.

## Reference Links
- If creating a type function, view the following: https://luau.org/types-library/
