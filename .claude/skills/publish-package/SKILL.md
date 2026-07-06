---
name: publish-package
description: Publish or version-bump a Wally package in this repo. Use when asked to publish, release, or bump a package version. Covers the publish script's non-interactive flags, the auto-generated init.luau, and CI workflow actions.
---

# Publishing a package

`npm run publish` runs `scripts/publish.py`. It is interactive by default but
has non-interactive flags — prefer them when driving it as an agent:

```sh
python scripts/publish.py --package-name <name> --version-change patch --publish
# --version-change: major | minor | patch | none
# --no-publish  = bump/prepare only;  --yes = auto-accept prompts
```

Publishing to wally is an **outward-facing, irreversible action** — confirm
with the user before running with `--publish`/`--yes`.

## What the script does

1. Bumps `version` in `lib/<name>/wally.toml` (unless `none`).
2. For pure-Luau multi-module packages (no committed `src/init.luau`), it
   generates a **temporary passthrough `init.luau`** that requires the entry
   module and re-exports every `export type`. This file is marked
   "AUTO-GENERATED ... do not commit" and is removed after — if one lingers in
   the working tree after a failed publish, delete it.
3. **Temporarily stashes all `*.spec.luau` / `*.spec.lua` and `CLAUDE.md`
   files** out of the package dir (and prunes dirs emptied by that, e.g.
   `Tests/`) so specs and agent context never ship in the published package;
   they are restored to the repo afterwards, even on failure.
4. Cleans installed wally deps from the package dir (keeps src, `wally.toml`,
   `default.project.json`, `README.md`), runs `wally publish`, then restores.

## After publishing

- Regenerate the root package table: `npm run readme` (root `README.md` is
  generated — never hand-edit).
- If the package graduated from "[Unreleased]", update its section label in
  `moonwave.toml`.

## CI path

`scripts/workflow_actions/` holds the GitHub Actions pieces:
`publish_detect_changed_packages.py` (which packages changed),
`publish_resolve_version_change.py` (bump type resolution),
`validate_publish_setup.py`. Check these before changing publish behavior —
local script and CI must stay in agreement.
