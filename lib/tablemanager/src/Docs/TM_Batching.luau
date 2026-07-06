--[=[
	@class TM Batching

	Batching groups several writes so their listeners fire **once**, against the net
	change, instead of once per write. Under the hood a batch is deferred flushing:
	it holds off the diff→fire→reconcile cycle until the window closes (see the
	Flushing guide for what a flush is).

	## Why batch

	Firing listeners after every individual write is both wasteful and can expose
	half-finished state to observers. `Batch` defers all firing until the whole
	group is done, then fires once for the combined diff.

	```lua
	manager:Batch(function()
		manager:Set("Player.Health", 100)
		manager:Set("Player.Mana", 50)
		manager:Set("Player.Stamina", 75)
	end)
	-- listeners fire here, once, for the combined diff
	```

	Net no-op changes within the window produce no events: if a value is changed and
	then changed back before the batch closes, nobody hears about it.

	## Suspend / Resume

	`Suspend()` and `Resume()` are the manual form of `Batch` — use them when the
	writes can't be wrapped in a single function (e.g. they span a loop or several
	call sites). Nested `Batch`/`Suspend` calls are no-ops; the outermost one wins.

	```lua
	manager:Suspend()
	for _, entry in pendingEdits do
		manager:Set(entry.path, entry.value)
	end
	manager:Resume() -- one flush: accumulated changes diffed against pre-suspend state
	```

	:::caution Do not yield inside a batch
	Yielding (`task.wait`, awaiting a Promise, etc.) between `Suspend` and `Resume`
	— or inside a `Batch` callback — is unsupported. Keep the window synchronous.
	:::

	## What Resume fires

	On resume the accumulated changes are diffed against the pre-batch state in a
	single array-aware pass, so array edits still surface as faithful
	`ArrayInserted`/`ArrayRemoved`/`ArraySet` events rather than a blanket "the array
	changed". A batched root-level write still reaches root (`{}`) listeners.

	## Batching vs. coalesced flushing

	Both collapse many writes into one flush, but they answer to different things:

	- **Batching** is explicit — *you* bracket the writes with `Batch`/`Suspend`, and
	  the flush happens the moment the window closes (synchronously).
	- **Coalesced flushing** (`FlushMode = "coalesced"`) is automatic and frame-based
	  — the manager merges the frame's flushes and fires them at frame end, with no
	  bracketing on your part. See the Flushing guide.

	---
	### See also

	- **[TM Flushing](/api/TM%20Flushing)** — the diff→fire→reconcile cycle a batch defers.
	- **[TM Listeners & Fire Modes](/api/TM%20Listeners%20&%20Fire%20Modes)** — what fires when the batch closes.
	- **[TM Getting Started](/api/TM%20Getting%20Started)** — the basics of reading and writing.
]=]
