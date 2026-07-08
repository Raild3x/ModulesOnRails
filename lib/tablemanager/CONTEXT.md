# TableManager

Reactive table-state management: callers mutate a table through a manager and
consumers observe those changes. This context covers how changes are detected,
batched, and delivered. (`src/Docs/CONTRACT.md` is the behavioral spec; this
file is only the language.)

## Language

**Surface**:
One of the two ways a change reaches consumers: the per-change Signals (global,
fire for any path) and the path listeners (registered at a path).
_Avoid_: channel, stream, event bus

**Fire mode**:
The timing policy for delivering one surface's notifications — `immediate`,
`deferred`, `bindable` (resolves to whatever the environment natively does), or
`coalesced`. Each surface has its own configured mode.
_Avoid_: dispatch mode; flush mode (FlushMode is a separate, unrelated config)

**Fire scheduler**:
The single owner of fire-mode resolution and delivery timing for both surfaces,
including the coalesce windows. The only thing that asks whether the
environment defers events.
_Avoid_: dispatcher (dispatch means routing a diff to listeners), scheduler
(unqualified)

**Coalesce window**:
The within-tick span during which repeated fires of the same signal (or to the
same listener) collapse into one delivery. A signal's window preserves the
first-in-window old value; a listener's window delivers the latest event.
_Avoid_: debounce, throttle
