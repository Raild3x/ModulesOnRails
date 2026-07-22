---
name: write-docs
description: Write or edit documentation in this repo — moonwave API docs, doc comments, or guide pages. Use when asked to document an API, add a guide, fix docs, or preview the docs site. Covers moonwave comment forms, guide-file conventions, classOrder registration, and previewing.
---

# Writing docs (moonwave)

The docs site is built by moonwave from doc comments in package source,
deployed to raild3x.github.io/ModulesOnRails. Config: `moonwave.toml`.

## Comment forms

- Public single-line doc: `---`
- Public multi-line doc: `--[=[ ... ]=]` with moonwave tags
  (`@class`, `@within`, `@param`, `@return`, `@prop`, `@yields`, `@private`, `@ignore`)
- Private (non-doc) comments: `--` / `--[[ ... ]]`
- Spec files carry `@ignore` in their class block so they stay out of the site.

Follow the existing doc style of the package you're in; `lib/tablemanager/src/`
is the richest example set.

## Guide pages

Long-form guides are **doc-comment-only `.luau` files** (no runtime code)
under the package's `src/Docs/`, named with the package prefix:
`lib/tablemanager/src/Docs/TM_Getting_Started.luau`,
`lib/tablereplicator/src/Docs/TR_Custom_Remotes.luau`, etc.

A new guide must be registered in `moonwave.toml` under the package's
`[[classOrder]]` — guides go in the nested `[[classOrder.items]]` block with
`section = "[Guides]"`. Unregistered classes still render but land unsorted.

Plain `.md` files in `src/Docs/` (e.g. `CONTRACT.md`, `ARCHITECTURE.md`) are
internal/contributor docs, not part of the moonwave site.

## Preview and build

```sh
npm run docs        # moonwave dev server (runs `npm run clear` first!)
npm run docs:build  # static build
```

**Warning:** both commands run `npm run clear` first, which strips installed
wally deps from every package — types/requires will look broken afterward
until `npm run setup` is re-run. Don't panic; it's expected.

The root `README.md` is generated from every `wally.toml` by `npm run readme`
— never hand-edit it. Package descriptions come from `wally.toml`
`description`; display name and docs link from `[custom] formattedName` /
`docsLink`.
