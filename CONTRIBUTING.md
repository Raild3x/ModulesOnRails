# Contributing to ModulesOnRails

Thanks for your interest in contributing! ModulesOnRails is a collection of
[Wally](https://wally.run/) packages for Roblox development, and contributions
of all kinds are welcome — bug reports, feature requests, docs improvements,
and pull requests.

- **Bugs & feature requests:** open an issue on
  [GitHub Issues](https://github.com/Raild3x/ModulesOnRails/issues).
- **Code changes:** open a pull request. For larger changes, consider opening
  an issue first to discuss the approach.

## Repository layout

This is a monorepo. Each package lives in its own directory under `lib/`:

```
lib/<package>/
├── src/                  -- Luau source (specs commonly under src/Tests/)
├── wally.toml            -- package manifest
└── default.project.json  -- Rojo project file
```

Shared tooling lives in `scripts/` (Python dev scripts), `tools/` (coverage
engine and CI helpers), and `test/` (test runtime, including the vendored
tiniest framework).

## Getting set up

Prerequisites:

- [Rokit](https://github.com/rojo-rbx/rokit) — toolchain manager; provisions
  Rojo, Wally, Lune, Selene, StyLua, and friends from `rokit.toml`.
- [Node.js](https://nodejs.org/) — npm script aliases and the docs site.
- [Python 3](https://www.python.org/) — the dev scripts in `scripts/`.

First-time setup:

```sh
rokit install    # install pinned tools
npm install      # docs-site dependencies
npm run setup    # wally install + sourcemap + package types for every package
```

> **Note:** On a fresh clone, requires and types will look broken in your
> editor until `npm run setup` has run.

> **Note:** `npm run docs` and `npm run docs:build` clear each package's Wally
> dependencies before building. Re-run `npm run setup` afterward to restore
> your working state.

## Testing

Tests use the **tiniest** framework (vendored in `test/tiniest/`) — do not
use TestEz. Spec files are named `*.spec.luau` and live inside the package's
`src/` tree, commonly under `src/Tests/`.

Run tests for a package (this also collects coverage):

```sh
npm run test <package>   # e.g. npm run test tablemanager
npm run test all         # every package
npm run test last        # re-run the last tested package
```

Extra flags are passed through to the underlying runner
(`lune run coverage.luau`), for example:

```sh
npm run test <package> --per-file --recommend
```

Pure-Luau packages run on Lune, which is fast. Packages that touch the Roblox
datamodel (or use `const`) run through the Roblox pipeline instead, which is
slower — prefer keeping packages Lune-testable when practical.

## Style & lint

CI runs Selene on every PR, so lint locally before pushing:

```sh
selene lib   # lint
stylua .     # format (120-column, tabs, double quotes)
```

Follow the style of the package you're editing. General conventions:

- **PascalCase** for classes, public fields, and methods; **camelCase** for
  locals and parameters; **SCREAMING_SNAKE_CASE** for constants.
- Prefix private members with `_`.
- Functions that yield return a Promise and carry an `Async` suffix
  (e.g. `FetchDataAsync`).
- Use relative string requires (`require("./Module")`).
- Avoid magic numbers — name them as constants.

## Documentation

API docs are generated with [Moonwave](https://eryn.io/moonwave/) from doc
comments (`--[=[ ... ]=]`) in the source. Narrative guide pages are
doc-comment-only `.luau` files under a package's `src/Docs/`, registered in
`moonwave.toml`.

The root `README.md` is auto-generated — never edit it by hand. Regenerate it
with `npm run readme` (it is rebuilt automatically after publishes anyway).

## Pull requests & releases

Every PR runs CI: Selene lint, tests for changed packages, a docs build
check, and a README generation check. Please make sure tests pass locally for
any package you touched.

Releases are handled by maintainers: a `semver:patch`, `semver:minor`, or
`semver:major` label on a merged PR automatically publishes the changed
packages to Wally and redeploys the docs site. You do not need to bump
versions or publish anything yourself.

## What not to commit

These are generated and should never appear in a PR:

- Root `README.md` edits (auto-generated)
- `sourcemap.json`, `wally.lock`, `build/`, `.coverage/`
- `lib/*/Packages/` and `lib/*/_Index/` (installed Wally dependencies)
- `src/init.luau` in pure-Luau multi-module packages — the publish process
  generates a passthrough entry point automatically

## License

By contributing, you agree that your contributions will be licensed under the
repository's [MIT License](LICENSE).
