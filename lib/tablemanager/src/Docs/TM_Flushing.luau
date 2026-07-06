--[=[
	@class TM Flushing

	Flushing is the heartbeat of a [TableManager](/api/TableManager). Every event
	it ever fires — every `OnChange`, every `ValueChanged` Signal, every `For*`
	reconcile — is the output of a **flush**. Understanding flushing explains *when*
	your listeners run, why the same change always produces the same events, and how
	to control the cost of change detection.

	## What a flush is

	A TableManager keeps a private **baseline snapshot**: its record of what the
	data looked like the last time it fired events. A flush is a three-step cycle
	against that baseline:

	1. **Diff** — compare the current live data against the baseline snapshot.
	2. **Fire** — emit listeners and Signals for whatever differs.
	3. **Reconcile** — advance the baseline forward to match the live data, so the
	   next flush starts fresh.

	This is the key idea: TableManager does **not** hook into each assignment and
	fire from there. It fires by *diffing two snapshots* at flush time. That single
	uniform operation is why a change produces identical, replay-faithful events no
	matter how it was made — a `Set`, a proxy write, a batch resume, or an external
	mutation surfaced with `Flush` all funnel through the same diff.

	## Immediate flushing (the default)

	With `FlushMode = "immediate"` (the default), every write flushes **synchronously**
	as part of the call. Listeners have already run by the time the write returns:

	```lua
	local manager = TableManager.new({ Player = { Health = 100 } })

	manager:OnValueChange("Player.Health", function(new)
		print("fired:", new)
	end)

	manager:Set("Player.Health", 80) -- prints "fired: 80" before this line returns
	print("after set")
	-- output order: "fired: 80" then "after set"
	```

	This is why writing through the API "just works": the flush is baked into the write.

	## Coalesced flushing

	`FlushMode = "coalesced"` defers each write's flush to the **end of the frame**
	and merges every flush requested during that frame into a single flush at their
	common ancestor path. A frame with N writes under one subtree then costs one
	diff/fire instead of N — the events still describe every net change, they just
	arrive together.

	```lua
	local manager = TableManager.new(data, { FlushMode = "coalesced" })

	manager:Set("Board.Cells.1", "X")
	manager:Set("Board.Cells.2", "O")
	-- nothing has fired yet; at frame end, ONE flush fires for Board.Cells
	```

	`FlushMode` defaults to `"immediate"`. Set it per-manager in the config, or
	change the process-wide default with
	[`TableManager.SetDefaults`](/api/TableManager#SetDefaults) (which only affects
	managers created afterwards).

	---
	## More info
	### Flushing external mutations

	Because change detection is a diff and not an assignment hook, code that mutates
	the underlying table **without going through the manager** is invisible until the
	next flush. `Flush(path?)` runs the diff→fire→reconcile cycle on demand to
	surface exactly those changes:

	```lua
	-- Some external system wrote straight into the raw table:
	manager.Raw.Player.Health = 25

	manager:Flush("Player") -- diffs Player against the baseline, fires the Health change
	```

	Omit the path to flush the whole tree. This is the supported recovery path for
	unavoidable bypasses — but prefer writing through `Set`/`ArrayInsert`/the proxy
	so the flush happens for you (see the Proxies & Direct Table Access guide).

	### Flushing is free when nothing is watching

	A flush is a **no-op when nothing observes `path`** — no listener covers it, no
	Signal is connected, no linked manager shares it, and no `OnApplied` subscriber
	exists. TableManager only pays the diff cost for data something is actually
	watching, so defensive `Flush` calls and writes to unobserved branches stay
	cheap.

	### Flushing and batching

	A batch is just **deferred flushing**: `Suspend` stops flushes from happening,
	and `Resume` performs a single flush over everything that changed in the window.
	See the Batching guide for grouping writes explicitly.

	---
	### See also

	- **[TM Batching](/api/TM%20Batching)** — deferring flushes to group many writes into one.
	- **[TM Listeners & Fire Modes](/api/TM%20Listeners%20&%20Fire%20Modes)** — what a flush fires, and how callbacks are scheduled.
	- **[TM Proxies & Direct Table Access](/api/TM%20Proxies%20&%20Direct%20Table%20Access)** — writing through the manager vs. bypassing it.
]=]
