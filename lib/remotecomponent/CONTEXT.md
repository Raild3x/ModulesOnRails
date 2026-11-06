# RemoteComponent

A component extension that gives a component networked remotes. This context
covers the vocabulary for how remotes are named, who may contribute them, and
when. (`src/init.luau`'s doc comment is the usage guide; this file is only the
language.)

## Language

**Remote namespace**:
The single Comm folder built per component instance (default name
`<Tag>_RemoteComponent`, or `component.RemoteNamespace`). Holds every remote for
the component — the author's and every extension's — under one `RF`/`RE`/`RP`
tree.
_Avoid_: remote folder (ambiguous with the `RF`/`RE`/`RP` sub-folders)

**Extension namespace**:
The string an extension passes to `addRemotes` (e.g. `"MyExtension"`). Scopes
that extension's contributed remotes so two extensions never collide.
_Avoid_: channel, prefix (the prefix is the mechanism, not the concept)

**Internal remote**:
An extension-contributed remote reached only through `getRemotes(component, ns)`.
Its underlying Comm name is prefixed with the extension namespace
(`"MyExtension/Fire"`); it never appears on the component's public surface.
_Avoid_: private remote

**Exposed remote**:
An extension-contributed remote registered with `{exposed = true}`, merged flat
onto the component's `Client`/`Server` surface alongside the author's own
remotes. Indistinguishable from an author remote once built; collisions are a
hard error.
_Avoid_: public remote, shared remote

**Registration window**:
The span during which `addRemotes` is valid: it opens in RemoteComponent's
`Constructing` hook and closes ("seals") when its `Starting` hook builds the
remotes. Registering after the window errors.
_Avoid_: registration phase

**SRC handshake**:
The `SRC` (server remote count) attribute the server writes on the remote
namespace folder. The client blocks until it sees that many replicated
`RF`+`RE`+`RP` children, then builds its object. A single scalar count covers
author, exposed, and internal remotes alike.
_Avoid_: ready flag, ready signal
