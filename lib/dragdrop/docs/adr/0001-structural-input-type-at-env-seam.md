# ADR 0001 — Structural input type at the Env seam

- Status: Accepted
- Date: 2026-07-08
- Context: DragDrop (`lib/dragdrop`)

## Context

The pointer and selection backends were made testable by injecting an **input
environment** (the Env seam) so they no longer bind `UserInputService` /
`GuiService` / `ContextActionService` / `task.delay` directly (see the
`TransitionSurface` and `Env` types in `Types.luau`). That raised a question: what
type of value should cross the seam when the backends receive an input event?

Two designs were considered:

1. **Package-owned `InputEvent` record** — a `{ Kind, Position (canonical space),
   KeyCode?, Id }` record. The real adapter would translate `InputObject` → event at
   the seam (including the inset/coordinate math), so backends and the state machine
   would become entirely free of Roblox input types, and the historically fiddly
   coordinate code would live in exactly one place.
2. **Structural `InputObject` type** — a type (`Types.InputLike`) that mimics only
   the fields the backends read (`UserInputType`, `KeyCode`, `Position`). Real
   `InputObject`s satisfy it structurally; test fakes are plain tables of the same
   shape. Backends keep calling `InputUtil.InputPosition`/`PointerLocation`.

## Decision

Use the **structural `InputObject` type** (`InputLike`).

## Rationale

- **Minimal diff.** Backends keep their existing input-reading call sites; only the
  parameter types change. The seam was introduced for testability, not to rewrite
  the input-translation logic in the same pass.
- **`InputPosition` is pure over the fake.** `InputUtil.InputPosition` reads only
  `input.Position`, so a structural fake flows through it unchanged — no translation
  layer is needed to test the coordinate handling.
- **Identity tracking is unchanged.** Touch drags key on `input == state.InputObject`
  (table identity). A structural fake is a table, so identity comparison works as-is;
  an `Id` token would have been redundant.
- Only `PointerLocation` (which reads a live service) had to move onto the Env seam;
  the rest of the position handling stayed put.

## Consequences

- The seam's contract is the `InputObject` field shape, not a package-owned type. If
  the backends ever need a field Roblox stops exposing, or we want the state machine
  fully input-type-free, revisit design (1) — the `InputEvent` record.
- The narrowing of the transition surface's `GetState()` snapshot (typing the drag
  state that backends read off `state`) was deliberately **not** done here; it is its
  own change because `state`'s shape is woven through the whole controller.

_Future architecture reviews: do not re-suggest replacing `InputLike` with a
package-owned event record unless one of the consequences above actually bites._
