# Context Map

This repo is **multi-context**: each package under `lib/` is its own domain context
with its own ubiquitous language. This file points at the per-package `CONTEXT.md`
glossaries. Read the one(s) relevant to what you're working on before exploring.

See `.github/agents/domain.md` for how the engineering skills consume these files.

## Per-package contexts

- [lib/dragdrop/CONTEXT.md](lib/dragdrop/CONTEXT.md) — pointer/selection drag-and-drop
  for Roblox GUI: payloads, sources, targets, ghosts, the controller state machine,
  and its two injection seams (transition surface + input environment).
- [lib/tablemanager/CONTEXT.md](lib/tablemanager/CONTEXT.md) — reactive table-state
  management: surfaces, fire modes, the fire scheduler, and coalesce windows.
- [lib/remotecomponent/CONTEXT.md](lib/remotecomponent/CONTEXT.md) — networked
  component remotes: the remote namespace, extension namespaces, internal vs
  exposed remotes, the registration window, and the SRC handshake.
- [lib/component/CONTEXT.md](lib/component/CONTEXT.md) — tag-bound component
  classes: the lifecycle phases and phase barrier, extensions and hooks,
  teardown and stop reasons, the core cleanup Janitor, and the world-level query
  engine (requirements, matches, observers).

Other packages under `lib/` do not have a `CONTEXT.md` yet; they are created lazily
(via `/domain-modeling`) when a term or decision actually needs pinning down.
