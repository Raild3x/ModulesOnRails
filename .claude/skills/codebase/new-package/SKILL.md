---
name: new-package
description: Create a new Wally package under lib/ in this repo. Use when asked to scaffold, add, or create a new package/module/library. Covers the scaffold script, the pure-Luau vs datamodel entry-point decision, and post-scaffold registration steps.
---

# Creating a new package

`npm run newpackage` runs `scripts/new_package.py`, which is **interactive**
(prompts for folder name, display name, description). When running
non-interactively, scaffold by hand instead, matching what the script creates:

```
lib/<name>/
  wally.toml        # name = "raild3x/<name>", version 0.1.0, [custom] formattedName + docsLink
  src/init.luau     # module table with a --[=[ @class <FormattedName> ]=] doc block
  src/init.spec.luau  # tiniest suite: return function(t: tiniest) ... end
```

Copy the exact templates from `scripts/new_package.py` (`create_wally_toml`,
`create_init_luau`, `create_init_spec_luau`). Then run
`npm run setup <name>` semantics via: `python scripts/setup_package_for_testing.py <name>`
(wally install + sourcemap + package types).

## The entry-point decision (load-bearing)

- **Pure-Luau package with multiple modules**: do NOT use `src/init.luau` as
  the entry point — delete it and name the entry module after the package
  (e.g. `TableManager.luau`). This keeps the package testable under the fast
  Lune pipeline. `npm run publish` auto-generates a passthrough `init.luau`
  (re-exporting all `export type`s) at publish time — never commit one.
- **Datamodel package** (uses `game`, `Instance`, RunService, etc.): a real
  `src/init.luau` is fine; tests will run via Roblox Studio.
- Single-module packages keep the scaffolded `init.luau` either way.

## Registration checklist

1. Requires inside the package: relative string requires only, never absolute,
   never into another package.
2. Docs: add a `[[classOrder]]` section (or items) in `moonwave.toml` if the
   package should appear in the docs sidebar.
3. Root `README.md` lists packages from every `wally.toml` — regenerate with
   `npm run readme`, don't hand-edit.
4. Verify: `lune run coverage.luau package=<name>` runs the scaffolded spec.
